/**
 * stats.js - Per-tab blocking statistics tracker for WebShield
 * Tracks cosmetic filters, scriptlets, extended CSS, and JS scripts applied per tab.
 */

// Storage for per-tab statistics
const tabStats = new Map();

/**
 * Get or create stats object for a tab
 * @param {number} tabId - The tab ID
 * @returns {Object} Stats object for the tab
 */
export function getTabStats(tabId) {
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
export function incrementStat(tabId, type, count = 1) {
  const stats = getTabStats(tabId);
  stats[type] = (stats[type] || 0) + count;
  stats.total += count;
  return stats.total;
}

/**
 * Reset stats for a tab (called on navigation)
 * @param {number} tabId - The tab ID
 * @param {string} url - The new URL
 */
export function resetTabStats(tabId, url = "") {
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
export function removeTabStats(tabId) {
  tabStats.delete(tabId);
}

/**
 * Get all tab stats (for debugging)
 * @returns {Map} All tab statistics
 */
export function getAllStats() {
  return tabStats;
}
