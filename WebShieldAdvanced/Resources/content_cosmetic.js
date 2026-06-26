/**
 * content_cosmetic.js — WebShield cosmetic & procedural filter content script.
 *
 * Modelled on Brave's content_cosmetic_ios.js (MPL-2.0) but adapted for
 * Safari Web Extension transport: native messaging routes through background.js
 * instead of WKScriptMessageHandlerWithReply.
 *
 * Responsibilities (per page, per frame):
 *   1. Ask background for per-URL cosmetic resources (cosmeticSetup).
 *   2. Apply engine-supplied hide selectors via an adopted CSSStyleSheet.
 *   3. Walk the DOM + observe mutations; batch new {ids, classes} and send to
 *      background (cosmeticSelectors) for class/id targeted hide rules.
 *   4. Run procedural actions (compiled by Brave's procedural_filters.js).
 *   5. Ask background to inject the engine's pre-composed scriptlet body into
 *      the page world.
 *
 * Skipped vs. Brave (v1): 1st-party unhide pump (we hide all matches),
 * aggressive/standard selector split (one bucket).
 */

(function () {
  const extension = globalThis.browser || globalThis.chrome;
  if (!extension) return;

  const procedural = globalThis.__webshieldProcedural;

  const LOG_PREFIX = "[WebShield Cosmetic]";
  const LOG_DEBUG = true;
  const log = {
    info:  (...a) => console.log(LOG_PREFIX, ...a),
    debug: (...a) => { if (LOG_DEBUG) console.debug(LOG_PREFIX, ...a); },
    warn:  (...a) => console.warn(LOG_PREFIX, ...a),
    error: (...a) => console.error(LOG_PREFIX, ...a),
  };

  function scriptletHead(code, n = 120) {
    if (typeof code !== "string") return "<non-string>";
    const oneLine = code.replace(/\s+/g, " ").trim();
    return oneLine.length > n ? oneLine.slice(0, n) + "…" : oneLine;
  }

  const MESSAGE_BATCH_THROTTLE_MS = 200;
  const STYLESHEET_REATTACH_INTERVAL_MS = 1000;
  const CLASS_ID_QUERY =
    "[id]:not(html):not(body),[class]:not(html):not(body)";

  const state = {
    url: location.href,
    isTopFrame: (() => {
      try { return globalThis.top === globalThis; } catch (_) { return false; }
    })(),
    setupReceived: false,
    genericHide: false,
    exceptions: [],
    proceduralActionFilters: null,
    hasProceduralActions: false,

    allSelectors: new Set(),
    pendingIds: new Set(),
    pendingClasses: new Set(),
    appliedSelectors: new Set(),
    pendingApply: new Set(),

    styleSheet: null,
    styleSheetRulesCache: [],
    rebuildScheduled: false,
  };

  // ---------- helpers ----------

  function throttle(func, delay) {
    let timerId = null;
    let pending = false;
    return (...args) => {
      if (timerId === null) {
        func(...args);
        timerId = setTimeout(() => {
          timerId = null;
          if (pending) {
            pending = false;
            func();
          }
        }, delay);
      } else {
        pending = true;
      }
    };
  }

  async function sendBackground(message) {
    try {
      return await extension.runtime.sendMessage(message);
    } catch (error) {
      log.error("background message failed:", message?.type, error);
      return null;
    }
  }

  // ---------- adopted stylesheet ----------

  function ensureStyleSheet() {
    if (state.styleSheet) return state.styleSheet;
    try {
      const sheet = new CSSStyleSheet();
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      state.styleSheet = sheet;
      log.debug("styleSheet created and adopted");

      // Re-add if the page strips it.
      setInterval(() => {
        if (!document.adoptedStyleSheets.includes(sheet)) {
          document.adoptedStyleSheets = [
            ...document.adoptedStyleSheets,
            sheet,
          ];
          log.debug("styleSheet was stripped by the page; re-adopted");
        }
      }, STYLESHEET_REATTACH_INTERVAL_MS);
    } catch (error) {
      log.error("CSSStyleSheet unavailable:", error);
    }
    return state.styleSheet;
  }

  function scheduleSheetRebuild() {
    if (state.rebuildScheduled) return;
    state.rebuildScheduled = true;
    queueMicrotask(rebuildSheet);
  }

  function rebuildSheet() {
    state.rebuildScheduled = false;
    const sheet = state.styleSheet;
    if (!sheet) return;
    if (state.styleSheetRulesCache.length === 0) {
      sheet.replaceSync("");
      return;
    }
    sheet.replaceSync(state.styleSheetRulesCache.join("\n"));
  }

  function addHideSelectors(selectors) {
    if (!selectors || selectors.length === 0) return 0;
    let added = 0;
    for (const sel of selectors) {
      if (!sel || typeof sel !== "string") continue;
      if (state.appliedSelectors.has(sel)) continue;
      state.appliedSelectors.add(sel);
      state.styleSheetRulesCache.push(`${sel}{display:none !important;}`);
      added += 1;
    }
    if (added > 0) {
      scheduleSheetRebuild();
    }
    const inlineHidden = forceHideSelectors(selectors);
    if (added > 0 || inlineHidden > 0) {
      log.debug(
        `addHideSelectors added=${added} inlineHidden=${inlineHidden} ` +
        `totalRules=${state.appliedSelectors.size}`,
      );
    }
    return added;
  }

  function forceHideElement(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE || !element.style) {
      return 0;
    }
    if (
      element.style.getPropertyValue("display") === "none" &&
      element.style.getPropertyPriority("display") === "important"
    ) {
      return 0;
    }
    element.style.setProperty("display", "none", "important");
    return 1;
  }

  function forceHideSelectorMatches(selector, root = document) {
    let hidden = 0;
    try {
      if (root.nodeType === Node.ELEMENT_NODE && root.matches(selector)) {
        hidden += forceHideElement(root);
      }
      if (root.querySelectorAll) {
        const matches = root.querySelectorAll(selector);
        for (const element of matches) hidden += forceHideElement(element);
      }
    } catch (error) {
      log.debug(`inline hide skipped selector=${selector}:`, error);
    }
    return hidden;
  }

  function forceHideSelectors(selectors, root = document) {
    if (!selectors || selectors.length === 0) return 0;
    let hidden = 0;
    for (const sel of selectors) {
      if (!sel || typeof sel !== "string") continue;
      hidden += forceHideSelectorMatches(sel, root);
    }
    return hidden;
  }

  function forceHideAppliedSelectors(root) {
    if (state.appliedSelectors.size === 0) return 0;
    return forceHideSelectors(Array.from(state.appliedSelectors), root);
  }

  // ---------- DOM walking + mutation observer ----------

  function extractIdsAndClasses(element) {
    if (!element || element.hasAttribute === undefined) return;
    const id = element.getAttribute && element.getAttribute("id");
    if (typeof id === "string" && id) {
      const sel = `#${id}`;
      if (!state.allSelectors.has(sel)) {
        state.allSelectors.add(sel);
        state.pendingIds.add(id);
      }
    }
    if (element.classList) {
      for (const className of element.classList) {
        if (!className) continue;
        const sel = `.${className}`;
        if (!state.allSelectors.has(sel)) {
          state.allSelectors.add(sel);
          state.pendingClasses.add(className);
        }
      }
    }
  }

  function walkAndQueue(root) {
    if (!root) return;
    if (root.nodeType === Node.ELEMENT_NODE) {
      extractIdsAndClasses(root);
    }
    if (root.querySelectorAll) {
      const matches = root.querySelectorAll(CLASS_ID_QUERY);
      for (const node of matches) extractIdsAndClasses(node);
    }
  }

  const flushPendingThrottled = throttle(flushPending, MESSAGE_BATCH_THROTTLE_MS);

  async function flushPending() {
    if (state.pendingIds.size === 0 && state.pendingClasses.size === 0) {
      return;
    }
    const ids = Array.from(state.pendingIds);
    const classes = Array.from(state.pendingClasses);
    state.pendingIds = new Set();
    state.pendingClasses = new Set();
    log.debug(`flushPending → ids=${ids.length} classes=${classes.length}`);

    const response = await sendBackground({
      type: "cosmeticSelectors",
      payload: {
        url: state.url,
        ids,
        classes,
        exceptionsJSON: JSON.stringify(state.exceptions || []),
      },
    });

    const selectors = response?.payload?.selectors;
    const matched = Array.isArray(selectors) ? selectors.length : 0;
    log.debug(`flushPending ← matched=${matched}`);
    if (matched > 0) {
      addHideSelectors(selectors);
    }
  }

  function observeMutations() {
    const observer = new MutationObserver((mutations) => {
      let dirty = false;
      let inlineHidden = 0;
      const procAdded = [];
      for (const mutation of mutations) {
        if (mutation.type === "attributes") {
          extractIdsAndClasses(mutation.target);
          inlineHidden += forceHideAppliedSelectors(mutation.target);
          dirty = true;
        } else if (mutation.type === "childList") {
          for (const node of mutation.addedNodes) {
            if (node.nodeType !== Node.ELEMENT_NODE) continue;
            walkAndQueue(node);
            inlineHidden += forceHideAppliedSelectors(node);
            dirty = true;
            if (state.hasProceduralActions) {
              procAdded.push(node);
              const sub = node.querySelectorAll && node.querySelectorAll("*");
              if (sub) {
                for (const s of sub) {
                  if (s.nodeType === Node.ELEMENT_NODE) procAdded.push(s);
                }
              }
            }
          }
        }
      }
      if (dirty || inlineHidden > 0 || procAdded.length > 0) {
        log.debug(
          `mutations=${mutations.length} dirty=${dirty} ` +
          `inlineHidden=${inlineHidden} procAdded=${procAdded.length}`,
        );
      }
      if (dirty) flushPendingThrottled();
      if (procAdded.length > 0) executeProceduralActions(procAdded);
    });

    observer.observe(document.documentElement || document, {
      subtree: true,
      childList: true,
      attributeFilter: ["id", "class"],
    });
    log.info("MutationObserver started");
  }

  // ---------- procedural actions ----------

  function executeProceduralActions(addedElements) {
    if (!procedural || !state.proceduralActionFilters) return;
    const filters = state.proceduralActionFilters;
    const scope = addedElements === undefined ? "full" : `subtree(${addedElements.length})`;
    let totalTargets = 0;

    for (const filter of filters) {
      const { selector, action } = filter;
      try {
        let matchingElements;
        let startOperator = 0;

        if (selector[0]?.type === "css-selector" && addedElements === undefined) {
          matchingElements = document.querySelectorAll(selector[0].arg);
          startOperator = 1;
        } else if (addedElements === undefined) {
          matchingElements = document.querySelectorAll("*");
        } else {
          matchingElements = addedElements;
        }

        let targets;
        if (startOperator === selector.length) {
          targets = Array.from(matchingElements);
        } else {
          const compiled = procedural.compileProceduralSelector(
            selector.slice(startOperator),
          );
          targets = procedural.applyCompiledSelector(
            compiled,
            Array.from(matchingElements),
          );
        }
        totalTargets += targets.length;
        for (const el of targets) performProceduralAction(el, action);
      } catch (error) {
        log.error("procedural filter failed:", JSON.stringify(filter), error);
      }
    }
    log.debug(`executeProceduralActions scope=${scope} filters=${filters.length} targets=${totalTargets}`);
  }

  function performProceduralAction(element, action) {
    if (!action) {
      addHideSelectors([uniqueElementSelector(element)]);
      element.style.setProperty("display", "none", "important");
      return;
    }
    switch (action.type) {
      case "style":
        if (action.arg) element.style.cssText += `;${action.arg}`;
        break;
      case "remove":
        element.remove();
        break;
      case "remove-attr":
        if (action.arg) element.removeAttribute(action.arg);
        break;
      case "remove-class":
        if (action.arg && element.classList.contains(action.arg)) {
          element.classList.remove(action.arg);
        }
        break;
      default:
        break;
    }
  }

  function uniqueElementSelector(element) {
    if (element.id) return `#${CSS.escape(element.id)}`;
    return null;
  }

  // ---------- setup ----------

  function parseProceduralActions(rawList) {
    if (!Array.isArray(rawList)) return null;
    const parsed = [];
    for (const raw of rawList) {
      try {
        const obj = JSON.parse(raw);
        if (!Array.isArray(obj.selector)) continue;
        obj.selector = normalizeSelectorOps(obj.selector);
        const broken = obj.selector.some(
          (op) => op?.type === "css-selector" && hasUnbalancedParens(op.arg),
        );
        if (broken) {
          log.warn(`procedural filter dropped (unsupported nested pseudo): ${raw}`);
          continue;
        }
        parsed.push(obj);
      } catch (error) {
        log.error("failed to parse procedural action:", error);
      }
    }
    return parsed.length > 0 ? parsed : null;
  }

  function hasUnbalancedParens(s) {
    if (typeof s !== "string") return false;
    let depth = 0;
    for (let i = 0; i < s.length; i += 1) {
      const ch = s[i];
      if (ch === "(") depth += 1;
      else if (ch === ")") depth -= 1;
      if (depth < 0) return true;
    }
    return depth !== 0;
  }

  // adblock-rust emits procedural pseudo-classes that wrap inner procedurals
  // (e.g. `:not(:has-text(x))`) as three fragments:
  //   [css ".prefix:not(", <inner ops…>, css ")"]
  // Recombine them into a single `{type: "not", arg: [inner ops]}` op so the
  // existing operatorNot path in procedural_filters.js applies. Iterates until
  // no more rewrites apply (handles nested `:not(:not(…))`).
  function normalizeSelectorOps(selector) {
    let current = selector;
    while (true) {
      const next = rewriteOnePass(current);
      if (next === current) return next;
      current = next;
    }
  }

  function rewriteOnePass(selector) {
    for (let i = 0; i < selector.length; i += 1) {
      const op = selector[i];
      if (op?.type !== "css-selector" || typeof op.arg !== "string") continue;
      const m = op.arg.match(/^(.*):not\(\s*$/);
      if (!m) continue;

      let depth = 1;
      let closeIdx = -1;
      let closePos = -1;
      for (let j = i + 1; j < selector.length; j += 1) {
        const part = selector[j];
        if (part?.type !== "css-selector" || typeof part.arg !== "string") continue;
        for (let k = 0; k < part.arg.length; k += 1) {
          const ch = part.arg[k];
          if (ch === "(") depth += 1;
          else if (ch === ")") depth -= 1;
          if (depth === 0) { closeIdx = j; closePos = k; break; }
        }
        if (closeIdx !== -1) break;
      }
      if (closeIdx === -1) continue;

      const result = selector.slice(0, i);
      const prefix = m[1];
      if (prefix) result.push({ type: "css-selector", arg: prefix });
      result.push({ type: "not", arg: selector.slice(i + 1, closeIdx) });
      const trailing = selector[closeIdx].arg.slice(closePos + 1);
      if (trailing) result.push({ type: "css-selector", arg: trailing });
      for (let j = closeIdx + 1; j < selector.length; j += 1) result.push(selector[j]);
      return result;
    }
    return selector;
  }

  async function runSetup() {
    log.info(`runSetup → url=${state.url}`);
    const response = await sendBackground({
      type: "cosmeticSetup",
      payload: {
        url: state.url,
        isTopFrame: state.isTopFrame,
      },
    });

    const payload = response?.payload;
    if (!payload) {
      log.warn(`runSetup: no payload from background (url=${state.url})`);
      return;
    }
    state.setupReceived = true;

    state.genericHide = Boolean(payload.genericHide);
    state.exceptions = Array.isArray(payload.exceptions) ? payload.exceptions : [];

    ensureStyleSheet();
    const hideCount = Array.isArray(payload.hideSelectors) ? payload.hideSelectors.length : 0;
    if (hideCount > 0) {
      addHideSelectors(payload.hideSelectors);
    }

    const filters = parseProceduralActions(payload.proceduralActions);
    const procCount = filters ? filters.length : 0;
    if (filters) {
      state.proceduralActionFilters = filters;
      state.hasProceduralActions = true;
      executeProceduralActions();
    }

    const hasInjected = typeof payload.injectedScript === "string"
      && payload.injectedScript.trim().length > 0;
    if (hasInjected) {
      const code = payload.injectedScript;
      log.info(
        `scriptlet inject requested url=${state.url} ` +
        `codeLen=${code.length} head=${scriptletHead(code)}`,
      );
      sendBackground({
        type: "injectScriptlet",
        payload: { code, url: state.url },
      }).then((resp) => {
        if (resp && resp.ok) {
          log.info(
            `scriptlet inject ✓ url=${state.url} applied=${resp.applied ?? "?"}`,
          );
        } else if (resp && resp.ok === false) {
          log.warn(
            `scriptlet inject ✗ url=${state.url}: ${resp.reason || resp.error || "unknown"}`,
          );
        } else {
          log.warn(`scriptlet inject ?? url=${state.url}: no response from background`);
        }
      });
    } else {
      log.debug(`runSetup no scriptlet to inject url=${state.url}`);
    }

    log.info(
      `runSetup complete hide=${hideCount} proc=${procCount} ` +
      `injected=${hasInjected} ` +
      `genericHide=${state.genericHide} ` +
      `exceptions=${state.exceptions.length}`,
    );

    if (!state.genericHide) {
      startSelectorDiscovery();
    } else {
      log.debug("genericHide=true → skipping selector discovery");
    }
  }

  function startSelectorDiscovery() {
    if (document.documentElement) {
      walkAndQueue(document.documentElement);
      flushPendingThrottled();
    }
    if (document.readyState === "loading") {
      log.debug("startSelectorDiscovery: deferring body walk to DOMContentLoaded");
      document.addEventListener(
        "DOMContentLoaded",
        () => {
          if (document.body) walkAndQueue(document.body);
          flushPendingThrottled();
          observeMutations();
          log.info(`selector discovery ready (DOMContentLoaded) tracked=${state.allSelectors.size}`);
        },
        { once: true },
      );
    } else {
      if (document.body) walkAndQueue(document.body);
      flushPendingThrottled();
      observeMutations();
      log.info(`selector discovery ready tracked=${state.allSelectors.size}`);
    }
  }

  runSetup();
})();
