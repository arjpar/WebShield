// src/content.js

/**
 * WebShield Advanced - Content Script (Optimized MV2 - Single Message Request)
 * CHANGE: Removed content script registries (cssRegistry, etc.). Potential for duplicate injections if background sends redundant data.
 * CHANGE: Scriptlet application moved entirely to content script.
 * CHANGE: Apply scriptlets concurrently using Promise.allSettled.
 * CHANGE: Pass verbose: true to scriptlet execution calls.
 */

"use strict";

// Wrap in IIFE
(function () {
  const browser = window.browser || window.chrome;
  if (typeof browser === "undefined" || !browser.runtime?.sendMessage) {
    console.error(
      "[WebShield Advanced CS] Browser APIs not available. Aborting.",
    );
    return;
  }

  // --- Configuration & Globals ---
  const LOG_PREFIX = "[WebShield Advanced CS]";
  const MAX_INIT_ATTEMPTS = 3;
  const RETRY_DELAY_MS = 150;
  const DEBUG_MODE = true;

  const log = {
    info: (msg, ...args) => console.info(`${LOG_PREFIX} ${msg}`, ...args),
    error: (msg, ...args) => console.error(`${LOG_PREFIX} ${msg}`, ...args),
    warn: (msg, ...args) => console.warn(`${LOG_PREFIX} ${msg}`, ...args),
    debug: (msg, ...args) => {
      if (DEBUG_MODE) console.log(`${LOG_PREFIX} [DEBUG] ${msg}`, ...args);
    },
  };

  // --- Initial URL Capture & Validation ---
  let initialUrl = "";
  try {
    if (window.location.href === "about:blank" && window.top !== window.self) {
      log.info(`Initial: Skipping execution for about:blank iframe.`);
      return;
    }
    initialUrl = window.location.href;
    if (!initialUrl || !initialUrl.match(/^https?:\/\//)) {
      throw new Error("URL invalid/non-HTTP(S)");
    }
  } catch (e) {
    if (
      initialUrl &&
      !initialUrl.startsWith("about:") &&
      !initialUrl.startsWith("chrome")
    ) {
      log.warn(
        `Initial: Cannot access or validate window.location.href. Aborting. URL: ${String(initialUrl).substring(0, 100)}`,
        e.message,
      );
    } else if (!initialUrl.startsWith("about:")) {
      log.info(
        `Initial: Skipping non-web URL: ${String(initialUrl).substring(0, 100)}`,
      );
    }
    return;
  }
  const isDocumentStart = document.readyState === "loading";
  log.info(
    `Script running. document_start: ${isDocumentStart}, readyState: ${document.readyState}, Initial URL: ${initialUrl.substring(0, 100)}...`,
  );

  // --- Registries & Utilities ---
  // REMOVED: createRegistry and registry instances (cssRegistry, scriptsRegistry, extendedCssRegistry)
  // REMOVED: computeSHA256Hash (no longer needed without registries)

  const executeScript = (code, identifier = "script") => {
    if (typeof code !== "string" || code.trim() === "") {
      log.debug(`(executeScript) Skipping empty code for: ${identifier}`);
      return;
    }
    log.debug(`(executeScript) Injecting: ${identifier}`);
    try {
      const scriptElement = document.createElement("script");
      scriptElement.textContent = code;
      scriptElement.setAttribute("data-wsa-source", identifier);
      const container = document.head || document.documentElement;
      if (!container)
        throw new Error("Cannot find <head> or <html> to inject script.");
      container.prepend(scriptElement);
      if (scriptElement.parentNode === container)
        container.removeChild(scriptElement);
      else
        log.warn(
          `(executeScript) Injected script for ${identifier} was moved or removed before cleanup.`,
        );
    } catch (e) {
      log.error(
        `(executeScript) Error injecting ${identifier}:`,
        e.message,
        e.stack,
      );
    }
  };

  // --- Error Reporting Setup ---
  let errorListenerAdded = false;
  function setupErrorListener() {
    // Keep this function as is
    if (errorListenerAdded || typeof window === "undefined") return;
    window.addEventListener("WebShieldScriptletError", (event) => {
      const detail = event.detail || {};
      const scriptletName = detail.scriptletName || "UnknownScriptlet";
      const errorMessage = detail.errorMessage || "No error message provided";
      const errorStack = detail.errorStack || "No stack trace available";
      log.error(
        `(Scriptlet Error Handler) Scriptlet: ${scriptletName} | Message: ${errorMessage}`,
        `Stack: ${errorStack}`,
      );
      try {
        if (browser?.runtime?.sendMessage) {
          let currentUrl = "unknown";
          try {
            currentUrl = window.location.href;
          } catch (e) {}
          browser.runtime
            .sendMessage({
              action: "reportScriptletError",
              detail: {
                scriptletName: String(scriptletName),
                errorMessage: String(errorMessage),
                errorStack: String(errorStack),
                url: currentUrl,
              },
            })
            .catch((e) =>
              log.warn("Failed to send scriptlet error report:", e.message),
            );
        }
      } catch (e) {
        log.warn("Error trying to send scriptlet error report:", e.message);
      }
    });
    errorListenerAdded = true;
    log.info("Scriptlet error listener attached.");
  }
  try {
    if (
      typeof window !== "undefined" &&
      typeof window.addEventListener === "function"
    ) {
      setupErrorListener();
    }
  } catch (e) {
    log.error("Failed setupErrorListener:", e);
  }

  // --- Rule Application Logic ---
  const applyCss = async (styles) => {
    if (!Array.isArray(styles) || styles.length === 0) return;
    const cssText = styles.join("\n");
    if (!cssText.trim()) return;
    // REMOVED: Hash calculation and registry check
    log.debug(`(applyCss) Applying ${styles.length} rules.`);
    try {
      const styleElement = document.createElement("style");
      styleElement.setAttribute("type", "text/css");
      styleElement.setAttribute("data-wsa-source", "css-inject");
      styleElement.textContent = cssText;
      const head = document.head || document.documentElement;
      if (head) {
        head.appendChild(styleElement);
        // REMOVED: cssRegistry.set(cssHash);
        log.debug("(applyCss) CSS rules applied successfully.");
      } else {
        log.error(
          "(applyCss) Critical: Cannot find <head> or <html> to inject styles.",
        );
      }
    } catch (e) {
      log.error("(applyCss) Failed to inject styles:", e);
    }
  };

  const applyExtendedCss = async (extendedCssRules) => {
    if (!Array.isArray(extendedCssRules) || extendedCssRules.length === 0)
      return;
    const validRuleStrings = extendedCssRules
      .map((s) => (typeof s === "string" ? s.trim() : ""))
      .filter((s) => s.length > 0 && !s.startsWith("!"));
    if (validRuleStrings.length === 0) {
      log.debug("(applyExtendedCss) No valid rules after filtering.");
      return;
    }
    const formattedCssRules = validRuleStrings.map((rule) => {
      rule = rule.replace(/\[-ext-([^=]+)=["'](.*?)["']\]/g, ":$1($2)");
      if (rule.includes("{") && rule.includes("}")) return rule;
      else if (rule.trim().endsWith(":remove()")) return rule;
      else return `${rule} { display: none !important; }`;
    });
    const rulesText = formattedCssRules.join("\n");
    if (!rulesText.trim()) return;
    // REMOVED: Hash calculation and registry check
    if (typeof window.ExtendedCss !== "function") {
      log.warn(
        "(applyExtendedCss) ExtendedCss library (window.ExtendedCss) not found. Cannot apply rules.",
      );
      return;
    }
    log.debug(
      `(applyExtendedCss) Applying ${formattedCssRules.length} formatted ExtendedCSS rules.`,
    );
    try {
      const extCss = new window.ExtendedCss({ cssRules: formattedCssRules });
      extCss.apply();
      // REMOVED: extendedCssRegistry.set(rulesHash);
      log.debug(
        "(applyExtendedCss) ExtendedCss library apply() called successfully.",
      );
    } catch (e) {
      log.error(
        "(applyExtendedCss) Error constructing or applying rules via ExtendedCss library:",
        e.message,
        e.stack,
        "\nFormatted rules passed:",
        formattedCssRules,
      );
    }
  };

  const applyScripts = async (scripts) => {
    if (!Array.isArray(scripts) || scripts.length === 0) return;
    const scriptText = scripts.join(";\n");
    if (!scriptText.trim()) return;
    // REMOVED: Hash calculation and registry check
    log.debug(`(applyScripts) Applying ${scripts.length} standard scripts.`);
    try {
      executeScript(scriptText, "standard-script-combined");
      // REMOVED: scriptsRegistry.set(scriptHash);
      log.debug("(applyScripts) Standard scripts applied successfully.");
    } catch (e) {
      log.error(
        "(applyScripts) Failed during standard script injection process.",
      );
    }
  };

  /**
   * Invokes and executes a single scriptlet.
   * @param {object} sMeta - A single scriptlet metadata object { name: '...', args: [...] }.
   * @param {boolean} verbose - Whether to enable verbose logging within scriptlets.
   */
  const applySingleScriptlet = (sMeta, verbose) => {
    if (
      typeof sMeta !== "object" ||
      sMeta === null ||
      typeof sMeta.name !== "string"
    ) {
      log.warn(
        "(applySingleScriptlet) Skipping invalid scriptlet metadata entry:",
        sMeta,
      );
      return;
    }
    const param = {
      name: sMeta.name,
      args: sMeta.args || [],
      engine: "safari-extension",
    };
    if (!!verbose) param.verbose = true;
    let executableCode = "";
    try {
      if (
        typeof window.scriptlets === "undefined" ||
        typeof window.scriptlets.invoke !== "function"
      ) {
        throw new Error(
          "window.scriptlets.invoke is not available. Ensure scriptlets.js content script is loaded first.",
        );
      }
      executableCode = window.scriptlets.invoke(param);
    } catch (invokeError) {
      log.error(
        `(applySingleScriptlet) Error INVOKING scriptlet '${param.name}':`,
        invokeError.message,
        invokeError.stack,
      );
      return;
    }
    if (
      executableCode &&
      typeof executableCode === "string" &&
      executableCode.trim() !== ""
    ) {
      try {
        executeScript(executableCode, `scriptlet-${param.name}`);
        log.debug(
          `(applySingleScriptlet) Dispatched execution for scriptlet '${param.name}'`,
        );
      } catch (execError) {
        log.error(
          `(applySingleScriptlet) Error EXECUTING scriptlet '${param.name}':`,
          execError.message,
          execError.stack,
        );
      }
    } else if (verbose) {
      log.debug(
        `(applySingleScriptlet) No executable code returned for scriptlet '${param.name}'. Return value:`,
        executableCode,
      );
    }
  };

  /**
   * Applies all rules (CSS, scripts, scriptlets) concurrently.
   * @param {object} payload - The object containing { metadataPayload }.
   */
  const applyCombinedRules = async (payload) => {
    if (
      !payload ||
      typeof payload.metadataPayload !== "object" ||
      payload.metadataPayload === null
    ) {
      log.error(
        "(applyCombinedRules) Invalid payload received (missing or invalid metadataPayload).",
      );
      return;
    }
    const { metadataPayload } = payload;
    console.time("WSA:ApplyCombinedRules");
    log.info("(applyCombinedRules) Starting concurrent rule application...");
    log.debug(
      "(applyCombinedRules) Received Metadata Payload Summary:",
      payload.metadataPayload,
    );

    const applicationPromises = [
      applyScripts(metadataPayload.scripts),
      applyCss(metadataPayload.cssInject),
      applyExtendedCss(metadataPayload.cssExtended),
      Promise.resolve().then(() => {
        console.time("WSA:ApplyScriptletsBatch");
        const scriptletMetadata = metadataPayload.scriptlets || [];
        if (scriptletMetadata.length > 0) {
          log.debug(
            `(applyCombinedRules) Applying ${scriptletMetadata.length} scriptlets batch...`,
          );
          scriptletMetadata.forEach((sMeta) =>
            applySingleScriptlet(sMeta, DEBUG_MODE),
          );
        } else {
          log.debug(
            "(applyCombinedRules) No scriptlets to apply in this batch.",
          );
        }
        console.timeEnd("WSA:ApplyScriptletsBatch");
      }),
    ];

    console.time("WSA:ApplyAllSettled");
    try {
      const results = await Promise.allSettled(applicationPromises);
      results.forEach((result, index) => {
        if (result.status === "rejected") {
          const type =
            index === 0
              ? "Scripts"
              : index === 1
                ? "CSS"
                : index === 2
                  ? "ExtendedCSS"
                  : "ScriptletsBatch";
          log.error(
            `(applyCombinedRules) Error applying ${type}:`,
            result.reason,
          );
        }
      });
      log.debug("(applyCombinedRules) All rule applications settled.");
    } catch (e) {
      log.error(
        "(applyCombinedRules) Unexpected error during Promise.allSettled:",
        e,
      );
    }
    console.timeEnd("WSA:ApplyAllSettled");
    log.info("(applyCombinedRules) Rule application sequence finished.");
    console.timeEnd("WSA:ApplyCombinedRules");
  };

  // --- Initialization Logic ---
  const requestCombinedRulesWithRetry = async (message, attempt = 1) => {
    const action = message?.action || "unknown action";
    log.debug(
      `(requestCombinedRules) Attempt ${attempt}/${MAX_INIT_ATTEMPTS} for action: ${action}`,
    );
    try {
      if (!browser?.runtime?.sendMessage)
        throw new Error("Browser runtime or sendMessage is unavailable.");
      const response = await Promise.race([
        browser.runtime.sendMessage(message),
        new Promise((_, reject) =>
          setTimeout(
            () =>
              reject(
                new Error("Background script request timed out after 10s"),
              ),
            10000,
          ),
        ),
      ]);
      if (browser.runtime.lastError)
        throw new Error(
          `Browser runtime error: ${browser.runtime.lastError.message}`,
        );
      if (response?.error) {
        const nonRetryableMessages = [
          "Native host not connected",
          "Invalid URL",
          "URL is required",
          "Native host request failed",
          "JSON parse error",
          "Could not establish connection. Receiving end does not exist",
          "Extension context invalidated",
        ];
        if (nonRetryableMessages.some((e) => response.error.includes(e))) {
          log.error(
            `(requestCombinedRules) Non-retryable error for ${action}: ${response.error}`,
          );
          throw new Error(response.error);
        }
        throw new Error(response.error);
      }
      // Ensure the core structure response.data.metadataPayload exists
      if (
        typeof response?.data?.metadataPayload !== "object" ||
        response.data.metadataPayload === null
      ) {
        log.error(
          "(requestCombinedRules) Invalid payload structure received from background:",
          response,
        );
        throw new Error(
          "Invalid payload structure (missing or invalid metadataPayload) from background",
        );
      }
      log.debug(
        `(requestCombinedRules) Success for ${action} (source: ${response.source || "N/A"})`,
      );
      return response.data; // Return { metadataPayload }
    } catch (error) {
      log.warn(
        `(requestCombinedRules) Attempt ${attempt} FAILED for ${action}:`,
        error.message,
      );
      const finalFailureMessages = [
        "Native host not connected",
        "Invalid URL",
        "URL is required",
        "Native host request failed",
        "Could not establish connection. Receiving end does not exist",
        "Extension context invalidated",
        "Background script request timed out",
      ];
      if (
        attempt >= MAX_INIT_ATTEMPTS ||
        finalFailureMessages.some((msg) => error.message.includes(msg))
      ) {
        log.error(
          `(requestCombinedRules) FINAL failure for ${action}. No more retries.`,
        );
        throw error;
      }
      const delay =
        RETRY_DELAY_MS * Math.pow(2, attempt - 1) + Math.random() * 100;
      log.info(
        `(requestCombinedRules) Retrying ${action} in ${delay.toFixed(0)} ms...`,
      );
      await new Promise((resolve) => setTimeout(resolve, delay));
      return requestCombinedRulesWithRetry(message, attempt + 1);
    }
  };

  const initialize = async () => {
    console.time("WSA:InitializeTotal");
    log.info(
      "(initialize) Starting initialization sequence (single message)...",
    );
    let currentValidUrl = "";
    try {
      currentValidUrl = window.location.href;
      if (!currentValidUrl || !currentValidUrl.match(/^https?:\/\//)) {
        throw new Error("Re-validated URL is invalid or non-HTTP(S)");
      }
      log.debug(
        `(initialize) Re-validated URL OK: ${currentValidUrl.substring(0, 100)}...`,
      );
    } catch (e) {
      log.error(
        "(initialize) FAILED TO GET/VALIDATE URL before request:",
        e.message,
      );
      console.timeEnd("WSA:InitializeTotal");
      return;
    }
    try {
      log.debug("(initialize) Requesting blocking data package...");
      console.time("WSA:FetchPackage");
      const payload = await requestCombinedRulesWithRetry({
        action: "getAdvancedBlockingData",
        url: currentValidUrl,
      });
      console.timeEnd("WSA:FetchPackage");
      log.debug(
        "(initialize) Received payload. Applying rules...",
        payload.metadataPayload,
      );
      await applyCombinedRules(payload);
      log.info("(initialize) Initialization sequence finished successfully.");
    } catch (error) {
      log.error(
        "(initialize) Initialization sequence FAILED:",
        error.message,
        error.stack,
      );
    } finally {
      console.timeEnd("WSA:InitializeTotal");
    }
  };

  // --- Trigger Initialization ---
  log.debug("Queueing initialization using setTimeout(0).");
  setTimeout(() => {
    initialize().catch((e) => {
      log.error(
        "Unhandled error during async initialize kickoff:",
        e.message,
        e.stack,
      );
    });
  }, 0);
})(); // End IIFE
