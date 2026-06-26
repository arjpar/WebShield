/**
 * stats.js - Per-tab blocking statistics tracker for WebShield
 * Tracks cosmetic filters, scriptlets, extended CSS, and JS scripts applied per tab.
 */

(function initWebShieldStats(global) {
const LOG_PREFIX = '[WebShield Stats]';
const LOG_DEBUG = true;
const log = {
  debug: (...a) => { if (LOG_DEBUG) console.debug(LOG_PREFIX, ...a); },
};

// Storage for per-tab statistics
const tabStats = new Map();

/**
 * Get or create stats object for a tab
 * @param {number} tabId - The tab ID
 * @returns {Object} Stats object for the tab
 */
function getTabStats(tabId) {
  if (!tabStats.has(tabId)) {
    tabStats.set(tabId, {
      cosmeticFilters: 0,
      scriptlets: 0,
      extendedCss: 0,
      scripts: 0,
      total: 0,
      url: "",
    });
  }
  return tabStats.get(tabId);
}

/**
 * Increment a specific stat type for a tab
 * @param {number} tabId - The tab ID
 * @param {string} type - Type of stat ('cosmeticFilters', 'scriptlets', 'extendedCss', 'scripts')
 * @param {number} count - Amount to increment (default 1)
 */
function incrementStat(tabId, type, count = 1) {
  const stats = getTabStats(tabId);
  stats[type] = (stats[type] || 0) + count;
  stats.total += count;
  log.debug(`incrementStat tab=${tabId} ${type}+=${count} → ${type}=${stats[type]} total=${stats.total}`);
  return stats.total;
}

/**
 * Reset stats for a tab (called on navigation)
 * @param {number} tabId - The tab ID
 * @param {string} url - The new URL
 */
function resetTabStats(tabId, url = "") {
  tabStats.set(tabId, {
    cosmeticFilters: 0,
    scriptlets: 0,
    extendedCss: 0,
    scripts: 0,
    total: 0,
    url: url,
  });
}

/**
 * Remove stats for a closed tab
 * @param {number} tabId - The tab ID
 */
function removeTabStats(tabId) {
  tabStats.delete(tabId);
}

/**
 * Get all tab stats (for debugging)
 * @returns {Map} All tab statistics
 */
function getAllStats() {
  return tabStats;
}

global.WebShieldStats = {
  getTabStats,
  incrementStat,
  resetTabStats,
  removeTabStats,
  getAllStats,
};
})(globalThis);
