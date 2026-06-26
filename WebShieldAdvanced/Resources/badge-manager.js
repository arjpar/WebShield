/**
 * badge-manager.js - Manages the extension toolbar badge display
 * Shows blocked item counts on the extension icon like uBlock Origin.
 */

(function initWebShieldBadgeManager(global) {
const {
  getTabStats,
  resetTabStats,
  removeTabStats,
} = global.WebShieldStats;

const LOG_PREFIX = '[WebShield Badge]';
const LOG_DEBUG = true;
const log = {
  info:  (...a) => console.log(LOG_PREFIX, ...a),
  debug: (...a) => { if (LOG_DEBUG) console.debug(LOG_PREFIX, ...a); },
  warn:  (...a) => console.warn(LOG_PREFIX, ...a),
  error: (...a) => console.error(LOG_PREFIX, ...a),
};

// Badge colors
const COLORS = {
  active: '#4a90d9',    // Blue when blocking
  inactive: '#999999',  // Gray when nothing blocked
  disabled: '#ff6b6b'   // Red when disabled (future use)
};

/**
 * Format count for badge display
 * @param {number} count - The count to format
 * @returns {string} Formatted count string
 */
function formatBadgeCount(count) {
  if (count === 0) return '';
  if (count >= 1000000) return Math.floor(count / 1000000) + 'M';
  if (count >= 10000) return Math.floor(count / 1000) + 'k';
  if (count >= 1000) return (count / 1000).toFixed(1) + 'k';
  return String(count);
}

/**
 * Update the badge for a specific tab
 * @param {number} tabId - The tab ID
 * @param {number} count - The count to display
 */
function updateBadge(tabId, count) {
  const text = formatBadgeCount(count);
  const color = count > 0 ? COLORS.active : COLORS.inactive;
  const action = browser.browserAction || browser.action;

  try {
    action.setBadgeText({
      text: text,
      tabId: tabId
    });

    action.setBadgeBackgroundColor({
      color: color,
      tabId: tabId
    });
    log.debug(`updateBadge tab=${tabId} count=${count} text='${text}'`);
  } catch (error) {
    log.error('Failed to update badge:', error);
  }
}

/**
 * Initialize badge manager - set up tab event listeners
 */
function initBadgeManager() {
  // Reset badge on navigation or reload
  browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.status === 'loading') {
      // Reset on any page load - use changeInfo.url if available (navigation),
      // otherwise use tab.url (reload of same page)
      const url = changeInfo.url || tab?.url || '';
      resetTabStats(tabId, url);
      updateBadge(tabId, 0);
      log.debug(`tabs.onUpdated loading tab=${tabId} url=${url}`);
    }
  });

  // Clean up when tab closes
  browser.tabs.onRemoved.addListener((tabId) => {
    removeTabStats(tabId);
    log.debug(`tabs.onRemoved tab=${tabId}`);
  });

  // Update badge when switching tabs (show correct count for active tab)
  browser.tabs.onActivated.addListener(({ tabId }) => {
    const stats = getTabStats(tabId);
    updateBadge(tabId, stats.total);
    log.debug(`tabs.onActivated tab=${tabId} total=${stats.total}`);
  });

  log.info('badge manager initialized');
}

/**
 * Get stats for a tab (used by popup)
 * @param {number} tabId - The tab ID
 * @returns {Object} Stats for the tab
 */
function getStatsForPopup(tabId) {
  return getTabStats(tabId);
}

global.WebShieldBadgeManager = {
  updateBadge,
  initBadgeManager,
  getStatsForPopup,
};
})(globalThis);
