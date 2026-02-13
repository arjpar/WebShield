/**
 * background-wrapper.js - Entry point for WebShield background scripts
 *
 * This module wraps the browser.scripting API to intercept CSS/JS insertions
 * and track blocked content statistics before loading the main background script.
 */

import { initBadgeManager, updateBadge } from "./badge-manager.js";
import {
  getTabStats,
  incrementStat,
  resetTabStats,
  removeTabStats,
} from "./stats.js";

// Initialize badge manager first
initBadgeManager();

// Store original browser.scripting methods before wrapping
const originalInsertCSS = browser.scripting.insertCSS.bind(browser.scripting);
const originalExecuteScript = browser.scripting.executeScript.bind(
  browser.scripting,
);

/**
 * Count CSS rules in a CSS string
 * @param {string} css - CSS string
 * @returns {number} Approximate number of CSS rules
 */
function countCssRules(css) {
  if (!css || typeof css !== "string") return 0;

  // Count by looking for selector patterns followed by braces
  // This is an approximation - each rule ends with }
  const rules = css.split("}").filter((r) => r.trim().includes("{"));
  return rules.length;
}

/**
 * Wrapped insertCSS that tracks cosmetic filter insertions
 */
browser.scripting.insertCSS = async function (injection) {
  const result = await originalInsertCSS(injection);

  // Track CSS insertions
  if (injection.target?.tabId) {
    const tabId = injection.target.tabId;
    let cssCount = 0;

    if (injection.css) {
      cssCount = countCssRules(injection.css);
    }

    if (cssCount > 0) {
      incrementStat(tabId, "cosmeticFilters", cssCount);
      const stats = getTabStats(tabId);
      updateBadge(tabId, stats.total);
    }
  }

  return result;
};

/**
 * Detect if an injection is for extended CSS
 * Extended CSS is passed as: args: [extendedCssArray] where extendedCssArray is string[]
 * and the injection function calls insertExtendedCss
 */
function isExtendedCssInjection(injection) {
  if (!injection.args || injection.args.length !== 1) return false;
  const arg = injection.args[0];
  // Extended CSS passes a single array of CSS selector strings
  if (!Array.isArray(arg) || arg.length === 0) return false;
  // All items should be strings (CSS selectors)
  if (typeof arg[0] !== "string") return false;
  // Check if the function body contains insertExtendedCss
  if (injection.func) {
    const funcStr = injection.func.toString();
    if (funcStr.includes("insertExtendedCss")) return true;
  }
  return false;
}

/**
 * Detect if an injection is for a scriptlet
 * Scriptlets are passed as: args: [scriptletSource, scriptletArgs]
 * where scriptletSource has { engine, name, args, version, verbose }
 */
function isScriptletInjection(injection) {
  if (!injection.args || injection.args.length < 1) return false;
  const source = injection.args[0];
  // Scriptlet source is an object with engine and name properties
  return (
    source &&
    typeof source === "object" &&
    !Array.isArray(source) &&
    typeof source.engine === "string" &&
    typeof source.name === "string"
  );
}

/**
 * Detect if an injection is for JS script execution
 * JS scripts call runScripts which injects with a function that creates script elements
 */
function isJsScriptInjection(injection) {
  if (!injection.func) return false;
  const funcStr = injection.func.toString();
  // JS script injection creates script elements to inject code
  return (
    funcStr.includes("createElement") &&
    funcStr.includes("script") &&
    (funcStr.includes("textContent") || funcStr.includes("innerHTML"))
  );
}

/**
 * Wrapped executeScript that tracks scriptlet/extended CSS/JS script executions
 */
browser.scripting.executeScript = async function (injection) {
  const result = await originalExecuteScript(injection);

  // Track script executions
  if (injection.target?.tabId) {
    const tabId = injection.target.tabId;

    if (isExtendedCssInjection(injection)) {
      // Extended CSS - count each CSS selector
      const extendedCssArray = injection.args[0];
      incrementStat(tabId, "extendedCss", extendedCssArray.length);
      const stats = getTabStats(tabId);
      updateBadge(tabId, stats.total);
    } else if (isScriptletInjection(injection)) {
      // Scriptlet - each call is one scriptlet execution
      incrementStat(tabId, "scriptlets", 1);
      const stats = getTabStats(tabId);
      updateBadge(tabId, stats.total);
    } else if (isJsScriptInjection(injection)) {
      // JS script injection - count based on args if available
      // runScriptTexts passes script texts as args[0] array
      let count = 1;
      if (injection.args && Array.isArray(injection.args[0])) {
        count = injection.args[0].length;
      }
      incrementStat(tabId, "scripts", count);
      const stats = getTabStats(tabId);
      updateBadge(tabId, stats.total);
    }
  }

  return result;
};

/**
 * Check if a domain is whitelisted via native messaging
 * @param {string} domain
 * @returns {Promise<{isWhitelisted: boolean}>}
 */
async function handleCheckWhitelist(domain) {
  try {
    const response = await browser.runtime.sendNativeMessage("application.id", {
      type: "checkWhitelist",
      payload: { domain: domain },
    });

    if (response && response.payload) {
      return { isWhitelisted: response.payload.isWhitelisted === true };
    }
    return { isWhitelisted: false };
  } catch (error) {
    console.error("[WebShield] Error checking whitelist:", error);
    return { isWhitelisted: false };
  }
}

/**
 * Toggle whitelist status for a domain via native messaging
 * @param {string} domain
 * @param {boolean} shouldWhitelist
 * @returns {Promise<{success: boolean}>}
 */
async function handleToggleWhitelist(domain, shouldWhitelist) {
  try {
    const response = await browser.runtime.sendNativeMessage("application.id", {
      type: "toggleWhitelist",
      payload: {
        domain: domain,
        whitelist: shouldWhitelist,
      },
    });

    if (response && response.payload) {
      return { success: response.payload.success === true };
    }
    return { success: false };
  } catch (error) {
    console.error("[WebShield] Error toggling whitelist:", error);
    return { success: false };
  }
}

// Add message listener for popup stats and whitelist requests
browser.runtime.onMessage.addListener((request, sender) => {
  // Handle stats request from popup
  if (request.type === "getStats") {
    return (async () => {
      let tabId = request.tabId;

      // If no tabId provided, get the active tab
      if (!tabId) {
        const tabs = await browser.tabs.query({
          active: true,
          currentWindow: true,
        });
        if (tabs.length > 0) {
          tabId = tabs[0].id;
        }
      }

      if (tabId) {
        const stats = getTabStats(tabId);
        return { stats };
      }

      return {
        stats: {
          cosmeticFilters: 0,
          scriptlets: 0,
          extendedCss: 0,
          scripts: 0,
          total: 0,
        },
      };
    })();
  }

  // Handle whitelist check from popup
  if (request.type === "checkWhitelist" && request.domain) {
    return handleCheckWhitelist(request.domain);
  }

  // Handle whitelist toggle from popup
  if (request.type === "toggleWhitelist" && request.domain !== undefined) {
    return handleToggleWhitelist(request.domain, request.whitelist);
  }

  // Don't handle other messages - let background.js handle them
  return false;
});

console.log(
  "[WebShield] Background wrapper initialized - API interception active",
);

// Now dynamically import the main background script
// This ensures our wrappers are in place before background.js runs
import("./background.js")
  .then(() => {
    console.log("[WebShield] Main background script loaded");
  })
  .catch((error) => {
    console.error("[WebShield] Failed to load background script:", error);
  });
