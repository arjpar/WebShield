// src/content.js

/**
 * WebShield Advanced - Content Script
 * Description: This script runs in the context of web pages, requests blocking rules
 *              from the background script, and applies them (CSS, scripts, scriptlets).
 *              It's optimized for Manifest V2 and uses a single message request to
 *              fetch all rules.
 *
 * Key Changes from original:
 * - Removed content script-side registries (cssRegistry, etc.) as rule uniqueness is
 *   expected to be handled by the background script or native host.
 * - Scriptlet application logic is now fully contained within this content script.
 * - Scriptlets are applied by iterating through metadata and executing them.
 * - Passes `verbose: true` (if DEBUG_MODE is true) to scriptlet execution calls.
 */

"use strict";

// IIFE to encapsulate the entire script and avoid polluting the global scope.
(function () {
  // --- Globals & Browser API Check ---
  const browser = window.browser || window.chrome;
  if (typeof browser === "undefined" || !browser.runtime?.sendMessage) {
    // If basic browser APIs aren't available, the script cannot function.
    console.error(
      "[WebShield Advanced CS] Browser APIs (browser.runtime.sendMessage) not available. Aborting content script.",
    );
    return;
  }

  // --- Configuration ---
  const LOG_PREFIX = "[WebShield Advanced CS]"; // Prefix for all console messages
  const MAX_INIT_ATTEMPTS = 3; // Max attempts to fetch rules from background
  const RETRY_DELAY_MS = 150; // Base delay for retries, increases exponentially
  const DEBUG_MODE = true; // Enables verbose logging for development
  const RULE_FETCH_TIMEOUT_MS = 10000; // Timeout for waiting for response from background script

  // --- Logging Utilities ---
  /**
   * Structured logging utility.
   * @property {Function} info - Logs informational messages.
   * @property {Function} error - Logs error messages.
   * @property {Function} warn - Logs warning messages.
   * @property {Function} debug - Logs debug messages, conditional on DEBUG_MODE.
   */
  const log = {
    info: (message, ...args) =>
      console.info(`${LOG_PREFIX} INFO: ${message}`, ...args),
    error: (message, ...args) =>
      console.error(`${LOG_PREFIX} ERROR: ${message}`, ...args),
    warn: (message, ...args) =>
      console.warn(`${LOG_PREFIX} WARN: ${message}`, ...args),
    debug: (message, ...args) => {
      if (DEBUG_MODE) console.log(`${LOG_PREFIX} DEBUG: ${message}`, ...args);
    },
  };

  // --- URL Validation & Initial Checks ---
  // Validates the initial URL to ensure the script should run on the current page.
  let initialUrl = "";
  try {
    // Special case for about:blank iframes, often used for ad content.
    // We might want to run in some iframes, but perhaps not blank ones if they are top-level or specific kinds.
    // The current check seems to be about not running if it's a blank iframe that isn't the top window.
    if (window.location.href === "about:blank" && window.top !== window.self) {
      log.info(
        "(Initial URL Check) Skipping execution for 'about:blank' iframe that is not the top window.",
      );
      return;
    }
    initialUrl = window.location.href;
    // Ensure the URL is http or https. Other schemes (ftp, file, chrome:, etc.) are ignored.
    if (!initialUrl || !initialUrl.match(/^https?:\/\//)) {
      // This specific error message helps distinguish from other catch scenarios.
      throw new Error("URL is invalid or not HTTP/HTTPS.");
    }
  } catch (e) {
    // Log warnings or info based on the type of URL or error.
    if (
      initialUrl &&
      !initialUrl.startsWith("about:") &&
      !initialUrl.startsWith("chrome")
    ) {
      // If we had an initialUrl but it failed validation or access.
      log.warn(
        `(Initial URL Check) Cannot access or validate window.location.href. Aborting. URL (approx): ${String(initialUrl).substring(0, 100)}. Error: ${e.message}`,
      );
    } else if (!initialUrl.startsWith("about:")) {
      // For non-web URLs that are not 'about:blank' (which might be handled or expected in some cases).
      log.info(
        `(Initial URL Check) Skipping non-web URL or inaccessible URL: ${String(initialUrl).substring(0, 100)}`,
      );
    }
    // If URL is invalid or not http/https, script should not proceed.
    return;
  }

  const isDocumentStartRun = document.readyState === "loading";
  log.info(
    `Script loaded. Is document_start: ${isDocumentStartRun}, Current readyState: ${document.readyState}, Initial URL: ${initialUrl.substring(0, 100)}...`,
  );

  // --- Core Utilities ---

  /**
   * Executes a given string of JavaScript code by injecting it into the page.
   * The script is injected into <head> or <html>, run, and then removed.
   * @param {string} code - The JavaScript code to execute.
   * @param {string} [identifier="script"] - A descriptive identifier for the script (used in data-wsa-source attribute and logs).
   */
  const executeScript = (code, identifier = "script") => {
    if (typeof code !== "string" || code.trim() === "") {
      log.debug(
        `(executeScript) Skipping empty or invalid code for identifier: ${identifier}`,
      );
      return Promise.resolve({ success: false, error: 'Empty or invalid code' });
    }
    log.debug(`(executeScript) Injecting script identified as: ${identifier}`);
    return new Promise((resolve) => {
      try {
        const scriptElement = document.createElement("script");
        scriptElement.setAttribute("data-wsa-source", identifier);

        const container = document.head || document.documentElement;
        if (!container) {
          throw new Error("Cannot find <head> or <html> element to inject script.");
        }

        // Create a unique identifier for this script execution
        const executionId = `wsa_exec_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
        
        // Wrap the code to track execution and ensure it sets the success flag
        const wrappedCode = `
          (function() {
            try {
              ${code};
              window["${executionId}"] = { 
                success: true, 
                timestamp: Date.now(),
                executed: true
              };
            } catch (e) {
              window["${executionId}"] = { 
                success: false, 
                error: e.message, 
                timestamp: Date.now(),
                executed: false
              };
            }
          })();
        `;
        
        scriptElement.textContent = wrappedCode;

        // Handle script load and execution
        scriptElement.onload = () => {
          // Script has been loaded and executed
          const result = window[executionId];
          delete window[executionId];
          
          // Clean up the script element
          if (scriptElement.parentNode === container) {
            container.removeChild(scriptElement);
          }

          if (result?.success === true && result?.executed === true) {
            log.debug(`(executeScript) Script '${identifier}' executed successfully`);
            resolve({ success: true, result });
          } else {
            const error = result?.error || 'Script execution failed';
            log.warn(`(executeScript) Script '${identifier}' execution failed: ${error}`);
            resolve({ success: false, error });
          }
        };

        scriptElement.onerror = (error) => {
          // Script failed to load
          delete window[executionId];
          
          // Clean up the script element
          if (scriptElement.parentNode === container) {
            container.removeChild(scriptElement);
          }

          log.warn(`(executeScript) Script '${identifier}' load error:`, error);
          resolve({ success: false, error: 'Script load error' });
        };

        // Add the script to the page to start execution
        container.prepend(scriptElement);
      } catch (e) {
        log.error(
          `(executeScript) Error injecting script '${identifier}': ${e.message}`,
          e.stack,
        );
        resolve({ success: false, error: e.message });
      }
    });
  };

  // --- Scriptlet Error Reporting ---
  let scriptletErrorListenerAdded = false;
  /**
   * Sets up a global event listener for "WebShieldScriptletError" custom events.
   * These events are expected to be dispatched by scriptlets themselves when they encounter errors.
   * This handler forwards the error details to the background script.
   */
  function setupScriptletErrorListener() {
    if (scriptletErrorListenerAdded || typeof window === "undefined") return;

    window.addEventListener("WebShieldScriptletError", (event) => {
      const detail = event.detail || {};
      const scriptletName = detail.scriptletName || "UnknownScriptlet";
      const errorMessage =
        detail.errorMessage || "No error message provided by scriptlet.";
      const errorStack =
        detail.errorStack || "No stack trace provided by scriptlet.";

      log.error(
        `(Scriptlet Error Handler) Captured error from scriptlet: '${scriptletName}'. Message: ${errorMessage}`,
        `Stack: ${errorStack}`,
      );

      try {
        if (browser?.runtime?.sendMessage) {
          let currentUrl = "unknown_url_in_error_handler";
          try {
            currentUrl = window.location.href; // Attempt to get current URL at time of error
          } catch (urlError) {
            log.warn(
              "(Scriptlet Error Handler) Could not retrieve window.location.href for error report.",
            );
          }

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
            .catch((sendError) => {
              // Catch errors if sendMessage itself fails (e.g., extension context invalidated)
              log.warn(
                `(Scriptlet Error Handler) Failed to send scriptlet error report to background: ${sendError.message}`,
              );
            });
        }
      } catch (e) {
        log.warn(
          `(Scriptlet Error Handler) Unexpected error while trying to report scriptlet error: ${e.message}`,
        );
      }
    });
    scriptletErrorListenerAdded = true;
    log.info(
      "(setupScriptletErrorListener) Global scriptlet error listener attached to window.",
    );
  }
  // Initialize the error listener as early as possible.
  try {
    if (
      typeof window !== "undefined" &&
      typeof window.addEventListener === "function"
    ) {
      setupScriptletErrorListener();
    }
  } catch (e) {
    log.error(
      "(setupScriptletErrorListener) Failed to attach global scriptlet error listener:",
      e.message,
    );
  }

  // --- Rule Application Helpers ---

  /**
   * Applies an array of CSS style strings to the page by creating and injecting a <style> element.
   * @param {string[]} styles - An array of CSS rule strings.
   */
  const applyCss = async (styles) => {
    if (!Array.isArray(styles) || styles.length === 0) {
      log.debug("(applyCss) No CSS styles provided to apply.");
      return false;
    }
    const cssText = styles.join("\n");
    if (!cssText.trim()) {
      log.debug("(applyCss) CSS styles content is empty after join/trim.");
      return false;
    }

    log.debug(`(applyCss) Applying ${styles.length} CSS rules.`);
    try {
      const styleElement = document.createElement("style");
      styleElement.setAttribute("type", "text/css");
      styleElement.setAttribute("data-wsa-source", "css-inject");
      styleElement.textContent = cssText;

      const head = document.head || document.documentElement;
      if (head) {
        head.appendChild(styleElement);
        
        // Verify CSS application
        const appliedRules = Array.from(document.styleSheets)
          .filter(sheet => sheet.ownerNode === styleElement)
          .flatMap(sheet => Array.from(sheet.cssRules))
          .map(rule => rule.cssText);
        
        const success = appliedRules.length === styles.length;
        log.info(`(applyCss) Applied ${appliedRules.length}/${styles.length} CSS rules`);
        return success;
      } else {
        log.error("(applyCss) Critical: Cannot find <head> or <html> to inject CSS styles.");
        return false;
      }
    } catch (e) {
      log.error("(applyCss) Failed to inject CSS styles:", e.message, e.stack);
      return false;
    }
  };

  /**
   * Applies an array of "Extended CSS" rules using the `window.ExtendedCss` library.
   * @param {string[]} extendedCssRules - An array of Extended CSS rule strings.
   */
  const applyExtendedCss = async (extendedCssRules) => {
    if (!Array.isArray(extendedCssRules) || extendedCssRules.length === 0) {
      log.debug("(applyExtendedCss) No ExtendedCSS rules provided.");
      return false;
    }

    const validRuleStrings = extendedCssRules
      .map((s) => (typeof s === "string" ? s.trim() : ""))
      .filter((s) => s.length > 0 && !s.startsWith("!"));

    if (validRuleStrings.length === 0) {
      log.debug("(applyExtendedCss) No valid ExtendedCSS rules after filtering.");
      return false;
    }

    const formattedRules = validRuleStrings.map(rule => {
      if (rule.includes('{')) {
        return rule;
      }
      return `${rule} { display: none !important; }`;
    });

    if (typeof window.ExtendedCss !== "function") {
      log.warn("(applyExtendedCss) ExtendedCss library is not available.");
      return false;
    }

    log.debug(`(applyExtendedCss) Applying ${formattedRules.length} ExtendedCSS rules.`);

    try {
      if (typeof window.ExtendedCss.init === 'function') {
        window.ExtendedCss.init();
      }

      const extCssInstance = new window.ExtendedCss({
        cssRules: formattedRules
      });
      extCssInstance.apply();

      // Store instance for cleanup
      if (!window._extendedCssInstances) {
        window._extendedCssInstances = new Set();
      }
      window._extendedCssInstances.add(extCssInstance);

      // Verify each rule individually
      let successfulRules = 0;
      for (const rule of formattedRules) {
        try {
          const selector = rule.split('{')[0].trim();
          const elements = document.querySelectorAll(selector);
          if (elements.length > 0) {
            successfulRules++;
          }
        } catch (e) {
          log.debug(`(applyExtendedCss) Verification warning for rule: ${rule}`, e);
        }
      }

      const success = successfulRules > 0;
      log.info(`(applyExtendedCss) Applied ${successfulRules}/${formattedRules.length} Extended CSS rules`);
      return success;

    } catch (e) {
      log.error(
        "(applyExtendedCss) Error applying Extended CSS rules:",
        e.message,
        e.stack,
        "\nRules attempted:",
        formattedRules,
      );
      return false;
    }
  };

  // Add cleanup for ExtendedCss instances
  const cleanupExtendedCss = () => {
    if (window._extendedCssInstances) {
      window._extendedCssInstances.forEach(instance => {
        try {
          if (instance && typeof instance.dispose === 'function') {
            instance.dispose();
          }
        } catch (e) {
          log.warn("(cleanupExtendedCss) Error disposing ExtendedCss instance:", e.message);
        }
      });
      window._extendedCssInstances.clear();
    }
  };

  /**
   * Applies an array of standard JavaScript code strings.
   * @param {string[]} scripts - An array of JavaScript code strings.
   */
  const applyScripts = async (scripts) => {
    if (!Array.isArray(scripts) || scripts.length === 0) {
      log.debug("(applyScripts) No scripts provided to apply.");
      return false;
    }

    log.debug(`(applyScripts) Applying ${scripts.length} standard scripts combined into one block.`);
    
    try {
      const combinedScript = scripts.join("\n");
      const scriptElement = document.createElement("script");
      scriptElement.setAttribute("type", "text/javascript");
      scriptElement.setAttribute("data-wsa-source", "standard-script-combined");

      // Create a unique identifier for this script execution
      const executionId = `wsa_script_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
      
      // Wrap the code to track execution
      const wrappedCode = `
        (function() {
          try {
            ${combinedScript};
            window["${executionId}"] = { success: true };
          } catch (e) {
            window["${executionId}"] = { 
              success: false, 
              error: e.message 
            };
          }
        })();
      `;
      
      scriptElement.textContent = wrappedCode;

      // Add error handling
      scriptElement.onerror = (error) => {
        log.error("(applyScripts) Script execution error:", error);
        window[executionId] = { 
          success: false, 
          error: error.message
        };
      };

      // Execute the script
      const head = document.head || document.documentElement;
      if (head) {
        head.appendChild(scriptElement);
        
        // Wait for script execution
        await new Promise(resolve => setTimeout(resolve, 100));
        
        // Get execution results
        const result = window[executionId];
        delete window[executionId];
        
        if (result?.success) {
          log.info(`(applyScripts) Successfully applied script block`);
        } else {
          log.warn(`(applyScripts) Script execution failed: ${result?.error || 'Unknown error'}`);
        }
        
        return result?.success === true;
      } else {
        log.error("(applyScripts) Critical: Cannot find <head> or <html> to inject script.");
        return false;
      }
    } catch (e) {
      log.error("(applyScripts) Failed to inject script:", e.message, e.stack);
      return false;
    }
  };

  // Add scriptlet execution helper
  const executeScriptlet = (name, args = []) => {
    try {
      if (!name || typeof name !== 'string') {
        throw new Error('Invalid scriptlet name');
      }

      // Use AdGuard's scriptlet library
      if (typeof window.scriptlets !== 'undefined' && typeof window.scriptlets.invoke === 'function') {
        const result = window.scriptlets.invoke(name, args);
        return result !== false;
      }
      throw new Error('Scriptlet library not available');
    } catch (e) {
      log.error(`(executeScriptlet) Failed to execute scriptlet ${name}:`, e);
      return false;
    }
  };

  const applySingleScriptlet = async (scriptlet, debugMode = false) => {
    if (!scriptlet || !scriptlet.name) {
      log.debug("(applySingleScriptlet) Invalid scriptlet provided.");
      return false;
    }

    const scriptletName = scriptlet.name;
    const scriptletArgs = scriptlet.args || [];

    log.debug(`(applySingleScriptlet) Applying scriptlet: ${scriptletName} with args:`, scriptletArgs);

    try {
      const success = executeScriptlet(scriptletName, scriptletArgs);
      if (success) {
        log.info(`(applySingleScriptlet) Successfully applied scriptlet: ${scriptletName}`);
      } else {
        log.warn(`(applySingleScriptlet) Failed to apply scriptlet: ${scriptletName}`);
      }
      return success;
    } catch (e) {
      log.error(
        `(applySingleScriptlet) Failed to apply scriptlet ${scriptletName}:`,
        e.message,
        e.stack,
      );
      return false;
    }
  };

  // --- Main Rule Application Logic ---

  /**
   * Verifies that rules were properly applied to the page
   * @param {object} payload - The rules payload that was applied
   * @returns {object} Verification results
   */
  async function verifyRuleApplication(payload) {
    const results = {
      cssInject: { applied: 0, total: payload.cssInject.length },
      cssExtended: { applied: 0, total: payload.cssExtended.length },
      scripts: { applied: 0, total: payload.scripts.length },
      scriptlets: { applied: 0, total: payload.scriptlets.length }
    };

    // Verify CSS injection
    const styleElements = document.querySelectorAll('style[data-wsa-source="css-inject"]');
    results.cssInject.applied = styleElements.length;

    // Verify Extended CSS
    const extendedCssElements = document.querySelectorAll('style[data-wsa-source="css-extended"]');
    results.cssExtended.applied = extendedCssElements.length;

    // Verify Scripts
    const scriptElements = document.querySelectorAll('script[data-wsa-source="standard-script-combined"]');
    results.scripts.applied = scriptElements.length;

    // Verify Scriptlets
    const scriptletElements = document.querySelectorAll('script[data-wsa-source^="scriptlet-"]');
    results.scriptlets.applied = scriptletElements.length;

    return results;
  }

  // Add PerformanceMetrics class
  class PerformanceMetrics {
    constructor() {
      this.metrics = {
        fetchTimes: [],
        applicationTimes: [],
        cacheHits: { critical: 0, regular: 0 },
        cacheMisses: 0,
        errors: []
      };
    }

    recordFetchTime(time) {
      this.metrics.fetchTimes.push(time);
    }

    recordApplicationTime(time) {
      this.metrics.applicationTimes.push(time);
    }

    recordCacheHit(type) {
      this.metrics.cacheHits[type]++;
    }

    recordCacheMiss() {
      this.metrics.cacheMisses++;
    }

    recordError(error) {
      this.metrics.errors.push({
        message: error.message,
        timestamp: Date.now()
      });
    }

    getAverageFetchTime() {
      return this.metrics.fetchTimes.length > 0 
        ? this.metrics.fetchTimes.reduce((a, b) => a + b, 0) / this.metrics.fetchTimes.length 
        : 0;
    }

    getAverageApplicationTime() {
      return this.metrics.applicationTimes.length > 0 
        ? this.metrics.applicationTimes.reduce((a, b) => a + b, 0) / this.metrics.applicationTimes.length 
        : 0;
    }

    getCacheHitRate() {
      const totalHits = this.metrics.cacheHits.critical + this.metrics.cacheHits.regular;
      const totalRequests = totalHits + this.metrics.cacheMisses;
      return totalRequests > 0 ? totalHits / totalRequests : 0;
    }

    getMetrics() {
      return {
        ...this.metrics,
        averageFetchTime: this.getAverageFetchTime(),
        averageApplicationTime: this.getAverageApplicationTime(),
        cacheHitRate: this.getCacheHitRate()
      };
    }
  }

  /**
   * Monitors rule application and tracks success/failure
   */
  class RuleApplicationMonitor {
    constructor() {
      this.appliedRules = new Map();
      this.failedRules = new Map();
      this.stats = {
        cssInject: { total: 0, successful: 0 },
        cssExtended: { total: 0, successful: 0 },
        scripts: { total: 0, successful: 0 },
        scriptlets: { total: 0, successful: 0 }
      };
      this.hasLoggedSummary = false;
    }

    trackRuleApplication(type, rule, success) {
      if (success) {
        this.appliedRules.set(rule, type);
        this.stats[type].successful++;
      } else {
        this.failedRules.set(rule, type);
      }
      this.stats[type].total++;
    }

    logCategoryVerification(type) {
      const stats = this.stats[type];
      const typeName = type.replace(/([A-Z])/g, ' $1').trim();
      const successRate = stats.total > 0 ? (stats.successful / stats.total * 100).toFixed(1) : 0;
      log.info(`[${typeName}] ${stats.successful}/${stats.total} rules applied (${successRate}%)`);
    }

    logStats() {
      if (this.hasLoggedSummary) return;
      
      // Calculate totals
      const totalRules = Object.values(this.stats).reduce((sum, stat) => sum + stat.total, 0);
      const totalSuccessful = Object.values(this.stats).reduce((sum, stat) => sum + stat.successful, 0);
      const totalSuccessRate = totalRules > 0 ? (totalSuccessful / totalRules * 100).toFixed(1) : 0;
      
      // Log summary
      log.info('=== WebShield Advanced Blocking Summary ===');
      log.info(`Total: ${totalSuccessful}/${totalRules} rules applied (${totalSuccessRate}%)`);
      
      // Log category breakdown
      Object.entries(this.stats).forEach(([type, typeStats]) => {
        const typeName = type.replace(/([A-Z])/g, ' $1').trim();
        const successRate = typeStats.total > 0 ? (typeStats.successful / typeStats.total * 100).toFixed(1) : 0;
        log.info(`  ${typeName}: ${typeStats.successful}/${typeStats.total} (${successRate}%)`);
      });

      this.hasLoggedSummary = true;
    }

    getStats() {
      const totalRules = Object.values(this.stats).reduce((sum, type) => sum + type.total, 0);
      const totalSuccessful = Object.values(this.stats).reduce((sum, type) => sum + type.successful, 0);
      
      return {
        applied: this.appliedRules.size,
        failed: this.failedRules.size,
        byType: this.stats,
        total: {
          rules: totalRules,
          successful: totalSuccessful,
          successRate: totalRules > 0 ? (totalSuccessful / totalRules * 100).toFixed(1) + '%' : '0%'
        }
      };
    }
  }

  // Add RuleCache implementation
  class RuleCache {
    constructor(maxSize = 1000) {
      this.maxSize = maxSize;
      this.cache = new Map();
      this.accessCount = new Map();
    }

    set(key, value) {
      if (this.cache.size >= this.maxSize) {
        const lruKey = this.getLRUKey();
        this.cache.delete(lruKey);
        this.accessCount.delete(lruKey);
      }
      this.cache.set(key, value);
      this.accessCount.set(key, Date.now());
    }

    get(key) {
      if (this.cache.has(key)) {
        this.accessCount.set(key, Date.now());
        return this.cache.get(key);
      }
      return null;
    }

    has(key) {
      return this.cache.has(key);
    }

    delete(key) {
      this.cache.delete(key);
      this.accessCount.delete(key);
    }

    clear() {
      this.cache.clear();
      this.accessCount.clear();
    }

    getLRUKey() {
      return Array.from(this.accessCount.entries())
        .sort(([,a], [,b]) => a - b)[0][0];
    }
  }

  // Improve RuleProcessor implementation
  class RuleProcessor {
    constructor() {
      this.monitor = new RuleApplicationMonitor();
      this.ruleCache = new Map();
      this.cleanupHandlers = new Set();
      this.metrics = new PerformanceMetrics();
    }

    async processRules(rules) {
      const startTime = performance.now();
      
      try {
        // Process all rules
        await this.processRuleSet(rules);
        
        const totalTime = performance.now() - startTime;
        this.metrics.recordApplicationTime(totalTime);
        log.info(`All rules applied in ${totalTime.toFixed(2)}ms`);

        // Log final comprehensive statistics
        this.monitor.logStats();
        
        return this.monitor.getStats();
      } catch (error) {
        this.metrics.recordError(error);
        throw error;
      }
    }

    async processRuleSet(rules) {
      // Process CSS rules
      if (rules.cssInject.length > 0) {
        await this.processCssRules(rules.cssInject);
        this.monitor.logCategoryVerification('cssInject');
      }
      
      // Process Extended CSS rules
      if (rules.cssExtended.length > 0) {
        await this.processExtendedCssRules(rules.cssExtended);
        this.monitor.logCategoryVerification('cssExtended');
      }
      
      // Process Script rules
      if (rules.scripts.length > 0) {
        await this.processScriptRules(rules.scripts);
        this.monitor.logCategoryVerification('scripts');
      }
      
      // Process Scriptlet rules
      if (rules.scriptlets.length > 0) {
        await this.processScriptletRules(rules.scriptlets);
        this.monitor.logCategoryVerification('scriptlets');
      }
    }

    async processCssRules(rules) {
      if (!rules.length) return true;
      
      const cacheKey = `css-${rules.join('')}`;
      if (this.ruleCache.has(cacheKey)) {
        log.debug(`CSS cache HIT`);
        return true;
      }

      try {
        const success = await applyCss(rules);
        this.monitor.trackRuleApplication('cssInject', rules, success);
        if (success) {
          this.ruleCache.set(cacheKey, true);
        }
        return success;
      } catch (error) {
        this.monitor.trackRuleApplication('cssInject', rules, false);
        return false;
      }
    }

    async processExtendedCssRules(rules) {
      if (!rules.length) return true;
      
      const cacheKey = `extended-${rules.join('')}`;
      if (this.ruleCache.has(cacheKey)) {
        log.debug(`Extended CSS cache HIT`);
        return true;
      }

      try {
        const success = await applyExtendedCss(rules);
        this.monitor.trackRuleApplication('cssExtended', rules, success);
        if (success) {
          this.ruleCache.set(cacheKey, true);
        }
        return success;
      } catch (error) {
        this.monitor.trackRuleApplication('cssExtended', rules, false);
        return false;
      }
    }

    async processScriptRules(rules) {
      if (!rules.length) return true;
      
      const cacheKey = `script-${rules.join('')}`;
      if (this.ruleCache.has(cacheKey)) {
        log.debug(`Script cache HIT`);
        return true;
      }

      try {
        const success = await applyScripts(rules);
        this.monitor.trackRuleApplication('scripts', rules, success);
        if (success) {
          this.ruleCache.set(cacheKey, true);
        }
        return success;
      } catch (error) {
        this.monitor.trackRuleApplication('scripts', rules, false);
        return false;
      }
    }

    async processScriptletRules(scriptlets) {
      if (!scriptlets.length) return true;
      
      const results = await Promise.all(
        scriptlets.map(async scriptlet => {
          const cacheKey = `scriptlet-${scriptlet.name}-${scriptlet.args.join('')}`;
          if (this.ruleCache.has(cacheKey)) {
            log.debug(`Scriptlet cache HIT for ${scriptlet.name}`);
            return true;
          }

          try {
            const success = await applySingleScriptlet(scriptlet, DEBUG_MODE);
            this.monitor.trackRuleApplication('scriptlets', scriptlet, success);
            if (success) {
              this.ruleCache.set(cacheKey, true);
            }
            return success;
          } catch (error) {
            this.monitor.trackRuleApplication('scriptlets', scriptlet, false);
            return false;
          }
        })
      );

      return results.every(result => result);
    }

    cleanup() {
      this.cleanupHandlers.forEach(handler => {
        try {
          handler();
        } catch (error) {
          log.error('Error during cleanup:', error);
        }
      });
      this.cleanupHandlers.clear();
      this.ruleCache.clear();
      cleanupExtendedCss();
    }
  }

  // Update applyCombinedRules to avoid duplicate logging
  const applyCombinedRules = async (payload) => {
    if (!payload || typeof payload.metadataPayload !== "object" || payload.metadataPayload === null) {
      log.error("Invalid payload: missing or invalid metadataPayload. Cannot apply rules.");
      return;
    }

    const processor = new RuleProcessor();
    
    // Add cleanup handler for page unload
    window.addEventListener('unload', () => processor.cleanup());
    
    try {
      await processor.processRules(payload.metadataPayload);
      
      // Log performance metrics
      log.info('Performance Metrics:', processor.metrics.getMetrics());
    } catch (error) {
      log.error('Rule application failed:', error);
    }
  };

  // --- Initialization & Data Fetching ---

  /**
   * Requests the combined set of rules from the background script with a retry mechanism.
   * Implements exponential backoff with jitter for retries.
   * @param {{action: string, url: string}} message - The message to send to the background script.
   * @param {number} [attempt=1] - The current retry attempt number.
   * @returns {Promise<object>} A promise that resolves with the data payload ({ metadataPayload }) from the background.
   * @throws {Error} If retries are exhausted or a non-retryable error occurs.
   */
  const requestCombinedRulesWithRetry = async (message, attempt = 1) => {
    const actionDescription = message?.action || "unknown action"; // For logging
    log.debug(
      `(requestCombinedRulesWithRetry) Attempt ${attempt}/${MAX_INIT_ATTEMPTS} for action: '${actionDescription}', URL: ${message.url.substring(0, 100)}`,
    );

    try {
      if (!browser?.runtime?.sendMessage) {
        // This should have been caught at the very start of the IIFE, but check again for safety.
        throw new Error("Browser runtime or sendMessage API is unavailable.");
      }

      // Use Promise.race to implement a timeout for the sendMessage call.
      const response = await Promise.race([
        browser.runtime.sendMessage(message),
        new Promise((_, reject) =>
          setTimeout(
            () =>
              reject(
                new Error(
                  `Background script request timed out after ${RULE_FETCH_TIMEOUT_MS}ms`,
                ),
              ),
            RULE_FETCH_TIMEOUT_MS,
          ),
        ),
      ]);

      // Check for browser.runtime.lastError, which can indicate issues like the extension context being invalidated.
      if (browser.runtime.lastError) {
        throw new Error(
          `Browser runtime error during sendMessage: ${browser.runtime.lastError.message}`,
        );
      }

      // Check if the response itself indicates an error from the background script.
      if (response?.error) {
        const nonRetryableErrorMessages = [
          "Native host not connected", // Critical native host issue
          "Invalid URL", // URL itself is bad, no point retrying with same URL
          "URL is required", // Background script validation
          "Native host request failed", // If native host fails definitively
          "JSON parse error", // If background had issues parsing native response
          "Could not establish connection. Receiving end does not exist", // Background script not listening
          "Extension context invalidated", // Extension is being updated/disabled
        ];
        // If the error message includes any non-retryable phrases, fail immediately.
        if (
          nonRetryableErrorMessages.some((errMsg) =>
            response.error.includes(errMsg),
          )
        ) {
          log.error(
            `(requestCombinedRulesWithRetry) Non-retryable error for '${actionDescription}': ${response.error}`,
          );
          throw new Error(response.error); // Propagate as a non-retryable error
        }
        // For other errors, treat them as potentially transient.
        throw new Error(`Background script error: ${response.error}`);
      }

      // Validate the structure of the successful response.
      if (
        typeof response?.data?.metadataPayload !== "object" ||
        response.data.metadataPayload === null
      ) {
        log.error(
          "(requestCombinedRulesWithRetry) Invalid payload structure received from background script:",
          response,
        );
        throw new Error(
          "Invalid payload structure from background (missing or invalid data.metadataPayload).",
        );
      }

      log.debug(
        `(requestCombinedRulesWithRetry) Successfully received rules for '${actionDescription}'. Source: ${response.source || "N/A"}`,
      );
      return response.data; // Expected to be { metadataPayload: { ... } }
    } catch (error) {
      log.warn(
        `(requestCombinedRulesWithRetry) Attempt ${attempt} FAILED for '${actionDescription}': ${error.message}`,
      );

      const isFinalAttempt = attempt >= MAX_INIT_ATTEMPTS;
      const isNonRecoverableError = [
        // Subset of non-retryable, plus timeout, for final decision
        "Native host not connected",
        "Invalid URL",
        "URL is required",
        "Native host request failed",
        "Could not establish connection. Receiving end does not exist",
        "Extension context invalidated",
        "Background script request timed out", // Timeout is also considered non-recoverable for retry loop
      ].some((msg) => error.message.includes(msg));

      if (isFinalAttempt || isNonRecoverableError) {
        log.error(
          `(requestCombinedRulesWithRetry) FINAL failure for '${actionDescription}'. No more retries. Error: ${error.message}`,
        );
        throw error; // Re-throw the error to be caught by the caller (initialize)
      }

      // Calculate delay with exponential backoff and jitter
      const jitter = Math.random() * 100; // Adds 0-100ms jitter
      const delay = RETRY_DELAY_MS * Math.pow(2, attempt - 1) + jitter;
      log.info(
        `(requestCombinedRulesWithRetry) Retrying '${actionDescription}' in ${delay.toFixed(0)} ms...`,
      );

      await new Promise((resolve) => setTimeout(resolve, delay));
      return requestCombinedRulesWithRetry(message, attempt + 1); // Recursive call for next attempt
    }
  };

  /**
   * Initializes the content script by fetching and applying rules.
   * Validates the URL again before making a request.
   */
  const initialize = async () => {
    const initTimerLabel = "WSA:FullInitializationDuration";
    console.time(initTimerLabel);
    log.info("(initialize) Starting content script initialization sequence...");

    let currentValidUrl = "";
    try {
      // Re-validate URL at the time of initialization, as it might have changed (though less likely for content scripts).
      currentValidUrl = window.location.href;
      if (!currentValidUrl || !currentValidUrl.match(/^https?:\/\//)) {
        throw new Error("URL at initialization is invalid or not HTTP/HTTPS.");
      }
      log.debug(
        `(initialize) Current URL for rule fetching: ${currentValidUrl.substring(0, 100)}...`,
      );
    } catch (e) {
      log.error(
        `(initialize) Failed to get or validate current URL at initialization. Aborting. Error: ${e.message}`,
      );
      console.timeEnd(initTimerLabel);
      return; // Cannot proceed without a valid URL
    }

    try {
      log.debug(
        "(initialize) Requesting blocking data package from background script...",
      );
      const ruleFetchTimerLabel = "WSA:RuleFetchDuration";
      console.time(ruleFetchTimerLabel);

      const payload = await requestCombinedRulesWithRetry({
        action: "getAdvancedBlockingData",
        url: currentValidUrl,
      });
      console.timeEnd(ruleFetchTimerLabel);

      if (DEBUG_MODE) {
        log.debug(
          "(initialize) Successfully received payload from background. Preparing to apply rules.",
          payload,
        );
      }

      const processor = new RuleProcessor();
      
      // Add cleanup handler for page unload
      window.addEventListener('unload', () => processor.cleanup());
      
      await processor.processRules(payload.metadataPayload);
      
      // Log final statistics
      processor.monitor.logStats();
      
      // Log performance metrics
      log.info('Performance Metrics:', processor.metrics.getMetrics());

      log.info("(initialize) Initialization sequence completed successfully.");
    } catch (error) {
      // This catches errors from requestCombinedRulesWithRetry (final failure) or critical errors in applyCombinedRules.
      log.error(
        `(initialize) Initialization sequence FAILED critically: ${error.message}`,
        error.stack,
      );
    } finally {
      console.timeEnd(initTimerLabel); // Log total initialization time
    }
  };

  // --- Script Execution Trigger ---
  // Use setTimeout to delay initialization slightly, allowing the page to potentially complete more of its own setup.
  // This can sometimes help with timing issues or ensure that document.head is available.
  log.debug(
    "(Trigger) Queueing content script initialization using setTimeout(0).",
  );
  setTimeout(() => {
    initialize().catch((e) => {
      // This catch is a final safeguard for any unhandled promise rejections from initialize() itself.
      log.error(
        "(Trigger) Unhandled critical error during async initialize kickoff:",
        e.message,
        e.stack,
      );
    });
  }, 0); // Using 0ms timeout defers execution until the current call stack clears.

  // Add message types for rules update
  const MESSAGE_TYPES = {
    RULES_UPDATED: 'rulesUpdated',
    WEB_SHIELD_RULES_UPDATED: 'WebShieldRulesUpdated'
  };

  // Add rules update handling
  function handleRulesUpdate(rulesData) {
    if (!isValidRulesData(rulesData)) {
      log.error('Invalid rules data received');
      return;
    }

    window.postMessage({
      type: MESSAGE_TYPES.WEB_SHIELD_RULES_UPDATED,
      rulesData
    }, '*');
  }

  function isValidRulesData(data) {
    return typeof data === 'string' && data.length > 0;
  }

  // Update message listener to handle rules updates
  browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === MESSAGE_TYPES.RULES_UPDATED) {
      handleRulesUpdate(message.rulesData);
    }
    // ... existing message handling ...
  });

  // Request initial rules update
  browser.runtime.sendMessage({ type: 'requestRulesUpdate' })
    .catch(error => log.error('Error requesting initial rules update:', error));
})(); // End of IIFE
