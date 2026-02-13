/**
 * zapper.js - Element zapper for WebShield
 *
 * Enables click-to-hide element removal with persistent CSS selectors per hostname.
 */
(function () {
  const extension = globalThis.browser || globalThis.chrome;
  if (!extension) return;
  if (window.top !== window) return;

  const RULES_PREFIX = "webshield_zapper_rules_";
  const RULES_STYLE_ID = "webshield-zapper-rules";
  const UI_STYLE_ID = "webshield-zapper-ui-style";
  const TOOLBAR_ID = "webshield-zapper-toolbar";
  const HIGHLIGHT_CLASS = "webshield-zapper-highlight";
  const ACTIVE_CLASS = "webshield-zapper-active";

  const state = {
    active: false,
    rules: new Set(),
    sessionRules: [],
    toolbar: null,
    statusEl: null,
    highlighted: null,
  };

  function getHostname() {
    return location.hostname || "";
  }

  function getStorageKey() {
    return `${RULES_PREFIX}${getHostname()}`;
  }

  function isValidHost() {
    return Boolean(getHostname());
  }

  function cssEscape(value) {
    if (globalThis.CSS && typeof globalThis.CSS.escape === "function") {
      return globalThis.CSS.escape(value);
    }
    return value.replace(/[^a-zA-Z0-9_-]/g, "\\$&");
  }

  function isUniqueSelector(selector) {
    try {
      return document.querySelectorAll(selector).length === 1;
    } catch {
      return false;
    }
  }

  function getClassSelector(element) {
    const classList = Array.from(element.classList || []);
    const filtered = classList.filter(
      (name) => name && !name.startsWith("webshield-zapper"),
    );
    const safe = filtered
      .filter((name) => /^[a-zA-Z0-9_-]+$/.test(name))
      .slice(0, 3);
    if (safe.length === 0) return "";
    return `.${safe.map(cssEscape).join(".")}`;
  }

  function nthOfType(element) {
    let index = 1;
    let sibling = element;
    while ((sibling = sibling.previousElementSibling)) {
      if (sibling.tagName === element.tagName) {
        index += 1;
      }
    }
    return index;
  }

  function buildSelector(element) {
    if (!element || element.nodeType !== 1) return null;

    if (element.id) {
      const idSelector = `#${cssEscape(element.id)}`;
      if (isUniqueSelector(idSelector)) {
        return idSelector;
      }
    }

    const segments = [];
    let current = element;

    while (current && current.tagName) {
      const tag = current.tagName.toLowerCase();
      if (tag === "html") {
        segments.unshift("html");
        break;
      }

      const classSelector = getClassSelector(current);
      let segment = `${tag}${classSelector}`;
      let candidate = [segment, ...segments].join(" > ");

      if (isUniqueSelector(candidate)) {
        return candidate;
      }

      const nthSegment = `${tag}${classSelector}:nth-of-type(${nthOfType(current)})`;
      candidate = [nthSegment, ...segments].join(" > ");

      if (isUniqueSelector(candidate)) {
        return candidate;
      }

      segments.unshift(nthSegment);
      current = current.parentElement;
    }

    return segments.length > 0 ? segments.join(" > ") : null;
  }

  function ensureStyleElement(id) {
    let style = document.getElementById(id);
    if (!style) {
      style = document.createElement("style");
      style.id = id;
      style.setAttribute("data-webshield", "zapper");
      (document.head || document.documentElement).appendChild(style);
    }
    return style;
  }

  function applyRules(rules) {
    const style = ensureStyleElement(RULES_STYLE_ID);
    if (!rules || rules.length === 0) {
      style.remove();
      return;
    }

    style.textContent = rules
      .map((rule) => `${rule} { display: none !important; }`)
      .join("\n");
  }

  async function loadRules() {
    if (!isValidHost() || !extension.storage?.local) return [];
    try {
      const key = getStorageKey();
      const result = await extension.storage.local.get(key);
      const rules = Array.isArray(result[key]) ? result[key] : [];
      applyRules(rules);
      return rules;
    } catch (error) {
      console.error("[WebShield Zapper] Failed to load rules:", error);
      return [];
    }
  }

  async function saveRules(rules) {
    if (!isValidHost() || !extension.storage?.local) return;
    try {
      const key = getStorageKey();
      await extension.storage.local.set({ [key]: rules });
    } catch (error) {
      console.error("[WebShield Zapper] Failed to save rules:", error);
    }
  }

  function updateStatus(text) {
    if (state.statusEl) {
      state.statusEl.textContent = text;
    }
  }

  function ensureUiStyles() {
    if (document.getElementById(UI_STYLE_ID)) return;

    const style = document.createElement("style");
    style.id = UI_STYLE_ID;
    style.textContent = `
      html.${ACTIVE_CLASS},
      body.${ACTIVE_CLASS} {
        cursor: crosshair !important;
      }

      .${HIGHLIGHT_CLASS} {
        outline: 2px solid #ff6b6b !important;
        background: rgba(255, 107, 107, 0.08) !important;
      }

      #${TOOLBAR_ID} {
        position: fixed;
        bottom: 16px;
        left: 50%;
        transform: translateX(-50%);
        background: rgba(26, 26, 46, 0.95);
        color: #eaeaea;
        border: 1px solid #2d2d44;
        border-radius: 10px;
        padding: 10px 12px;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
        z-index: 2147483647;
        box-shadow: 0 12px 24px rgba(0, 0, 0, 0.35);
        max-width: 320px;
        width: calc(100% - 32px);
      }

      #${TOOLBAR_ID} .webshield-zapper-title {
        font-size: 13px;
        font-weight: 600;
        margin-bottom: 4px;
      }

      #${TOOLBAR_ID} .webshield-zapper-status {
        font-size: 11px;
        color: #a0a0b0;
        margin-bottom: 8px;
      }

      #${TOOLBAR_ID} .webshield-zapper-actions {
        display: flex;
        gap: 8px;
      }

      #${TOOLBAR_ID} .webshield-zapper-button {
        flex: 1;
        border: none;
        border-radius: 6px;
        padding: 6px 10px;
        font-size: 12px;
        font-weight: 600;
        cursor: pointer;
      }

      #${TOOLBAR_ID} .webshield-zapper-button.secondary {
        background: #2d2d44;
        color: #eaeaea;
      }

      #${TOOLBAR_ID} .webshield-zapper-button.primary {
        background: #4a90d9;
        color: #ffffff;
      }
    `;

    (document.head || document.documentElement).appendChild(style);
  }

  function isUiElement(element) {
    return Boolean(
      element && element.closest && element.closest(`#${TOOLBAR_ID}`),
    );
  }

  function clearHighlight() {
    if (state.highlighted && state.highlighted.classList) {
      state.highlighted.classList.remove(HIGHLIGHT_CLASS);
    }
    state.highlighted = null;
  }

  function setHighlight(element) {
    if (!element || element === state.highlighted) return;
    if (element === document.body || element === document.documentElement)
      return;
    clearHighlight();
    if (element.classList) {
      element.classList.add(HIGHLIGHT_CLASS);
      state.highlighted = element;
    }
  }

  async function addRule(selector) {
    if (!selector || state.rules.has(selector)) {
      updateStatus("Rule already exists");
      return;
    }

    state.rules.add(selector);
    state.sessionRules.push(selector);
    const updatedRules = Array.from(state.rules);
    applyRules(updatedRules);
    await saveRules(updatedRules);
    updateStatus("Rule added");
  }

  async function undoRule() {
    const lastRule = state.sessionRules.pop();
    if (!lastRule) {
      updateStatus("Nothing to undo");
      return;
    }

    state.rules.delete(lastRule);
    const updatedRules = Array.from(state.rules);
    applyRules(updatedRules);
    await saveRules(updatedRules);
    updateStatus("Rule removed");
  }

  function handleMouseMove(event) {
    if (!state.active) return;
    if (isUiElement(event.target)) return;
    setHighlight(event.target);
  }

  function handleClick(event) {
    if (!state.active) return;
    if (isUiElement(event.target)) return;

    event.preventDefault();
    event.stopPropagation();

    const selector = buildSelector(event.target);
    if (!selector) {
      updateStatus("Unable to build selector");
      return;
    }

    addRule(selector);
  }

  function handleKeydown(event) {
    if (!state.active) return;
    if (event.key === "Escape") {
      deactivate();
    }
  }

  function addListeners() {
    document.addEventListener("mousemove", handleMouseMove, true);
    document.addEventListener("click", handleClick, true);
    document.addEventListener("keydown", handleKeydown, true);
  }

  function removeListeners() {
    document.removeEventListener("mousemove", handleMouseMove, true);
    document.removeEventListener("click", handleClick, true);
    document.removeEventListener("keydown", handleKeydown, true);
  }

  function createToolbar() {
    if (state.toolbar) return;

    ensureUiStyles();

    const toolbar = document.createElement("div");
    toolbar.id = TOOLBAR_ID;
    toolbar.innerHTML = `
      <div class="webshield-zapper-title">Element Zapper</div>
      <div class="webshield-zapper-status">Click an element to hide it</div>
      <div class="webshield-zapper-actions">
        <button class="webshield-zapper-button secondary" type="button" data-action="undo">Undo</button>
        <button class="webshield-zapper-button primary" type="button" data-action="exit">Exit</button>
      </div>
    `;

    const statusEl = toolbar.querySelector(".webshield-zapper-status");
    const undoButton = toolbar.querySelector('[data-action="undo"]');
    const exitButton = toolbar.querySelector('[data-action="exit"]');

    if (undoButton) {
      undoButton.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        undoRule();
      });
    }

    if (exitButton) {
      exitButton.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        deactivate();
      });
    }

    state.toolbar = toolbar;
    state.statusEl = statusEl || null;
    document.documentElement.appendChild(toolbar);
  }

  function removeToolbar() {
    if (state.toolbar) {
      state.toolbar.remove();
      state.toolbar = null;
      state.statusEl = null;
    }

    const uiStyle = document.getElementById(UI_STYLE_ID);
    if (uiStyle) {
      uiStyle.remove();
    }
  }

  function activate() {
    if (state.active) {
      updateStatus("Element zapper already active");
      return;
    }

    state.active = true;
    state.sessionRules = [];
    document.documentElement.classList.add(ACTIVE_CLASS);
    document.body?.classList.add(ACTIVE_CLASS);
    createToolbar();
    addListeners();

    loadRules().then((rules) => {
      rules.forEach((rule) => state.rules.add(rule));
      applyRules(Array.from(state.rules));
    });
  }

  function deactivate() {
    if (!state.active) return;
    state.active = false;
    removeListeners();
    clearHighlight();
    removeToolbar();
    document.documentElement.classList.remove(ACTIVE_CLASS);
    document.body?.classList.remove(ACTIVE_CLASS);
  }

  extension.runtime.onMessage.addListener((message) => {
    if (message && message.type === "activateZapper") {
      activate();
    }
  });

  loadRules().then((rules) => {
    state.rules = new Set(rules);
  });
})();
