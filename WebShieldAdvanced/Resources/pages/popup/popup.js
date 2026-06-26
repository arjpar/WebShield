/**
 * popup.js - Popup script for WebShield extension
 *
 * Fetches and displays blocking statistics for the current tab.
 * Also handles per-site whitelist (trusted sites) toggle.
 */

const LOG_PREFIX = '[WebShield Popup]';
const LOG_DEBUG = true;
const log = {
  info:  (...a) => console.log(LOG_PREFIX, ...a),
  debug: (...a) => { if (LOG_DEBUG) console.debug(LOG_PREFIX, ...a); },
  warn:  (...a) => console.warn(LOG_PREFIX, ...a),
  error: (...a) => console.error(LOG_PREFIX, ...a),
};

// Current domain being displayed
let currentDomain = null;

// Zapper rules for the current domain
let zapperRules = [];

// Storage key prefix for zapper rules
const ZAPPER_RULES_PREFIX = 'webshield_zapper_rules_';

/**
 * Get the current active tab
 * @returns {Promise<browser.tabs.Tab|null>}
 */
async function getCurrentTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs.length > 0 ? tabs[0] : null;
}

/**
 * Format a number for display
 * @param {number} num
 * @returns {string}
 */
function formatNumber(num) {
  if (num >= 1000000) {
    return (num / 1000000).toFixed(1) + 'M';
  }
  if (num >= 1000) {
    return (num / 1000).toFixed(1) + 'k';
  }
  return String(num);
}

/**
 * Extract domain from URL
 * @param {string} url
 * @returns {string}
 */
function extractDomain(url) {
  try {
    const urlObj = new URL(url);
    return urlObj.hostname;
  } catch {
    return url || 'Unknown';
  }
}

/**
 * Normalize domain by removing www. prefix
 * @param {string} domain
 * @returns {string}
 */
function normalizeDomain(domain) {
  if (domain.startsWith('www.')) {
    return domain.substring(4);
  }
  return domain;
}

/**
 * Update the whitelist toggle UI
 * @param {boolean} isWhitelisted - Whether the current domain is whitelisted
 */
function updateWhitelistUI(isWhitelisted) {
  const toggleEl = document.getElementById('whitelist-toggle');
  const trustedBadgeEl = document.getElementById('trusted-badge');
  const statusDotEl = document.getElementById('status-dot');
  const statusTextEl = document.getElementById('status-text');

  if (toggleEl) {
    toggleEl.checked = isWhitelisted;
  }

  if (trustedBadgeEl) {
    if (isWhitelisted) {
      trustedBadgeEl.classList.remove('hidden');
    } else {
      trustedBadgeEl.classList.add('hidden');
    }
  }

  // Update status indicator for whitelisted sites
  if (isWhitelisted) {
    statusDotEl.className = 'status-dot inactive';
    statusTextEl.textContent = 'Protection disabled for this site';
  }
}

/**
 * Check if the current domain is whitelisted
 * @param {string} domain
 * @returns {Promise<boolean>}
 */
async function checkWhitelistStatus(domain) {
  try {
    const normalized = normalizeDomain(domain);
    log.debug(`checkWhitelistStatus domain=${normalized}`);
    const response = await browser.runtime.sendMessage({
      type: 'checkWhitelist',
      domain: normalized
    });
    const isWhitelisted = response && response.isWhitelisted === true;
    log.info(`checkWhitelistStatus ← domain=${normalized} whitelisted=${isWhitelisted}`);
    return isWhitelisted;
  } catch (error) {
    log.error('Error checking whitelist:', error);
    return false;
  }
}

/**
 * Toggle the whitelist status for a domain
 * @param {string} domain
 * @param {boolean} shouldWhitelist
 * @returns {Promise<boolean>}
 */
async function toggleWhitelist(domain, shouldWhitelist) {
  try {
    const normalized = normalizeDomain(domain);
    log.info(`toggleWhitelist domain=${normalized} whitelist=${shouldWhitelist}`);
    const response = await browser.runtime.sendMessage({
      type: 'toggleWhitelist',
      domain: normalized,
      whitelist: shouldWhitelist
    });
    const success = response && response.success === true;
    log.info(`toggleWhitelist ← domain=${normalized} success=${success}`);
    return success;
  } catch (error) {
    log.error('Error toggling whitelist:', error);
    return false;
  }
}

/**
 * Activate the element zapper for the current tab
 * @returns {Promise<boolean>}
 */
async function activateZapper() {
  try {
    const tab = await getCurrentTab();
    if (!tab || !tab.id) {
      log.warn('activateZapper: no active tab');
      return false;
    }

    await browser.tabs.sendMessage(tab.id, { type: 'activateZapper' });
    log.info(`activateZapper sent → tab=${tab.id}`);
    return true;
  } catch (error) {
    log.error('Error activating zapper:', error);
    return false;
  }
}

/**
 * Setup element zapper button handler
 */
function setupZapperButton() {
  const buttonEl = document.getElementById('zapper-button');
  if (!buttonEl) return;

  buttonEl.addEventListener('click', async () => {
    buttonEl.disabled = true;
    const success = await activateZapper();

    if (success) {
      const statusTextEl = document.getElementById('status-text');
      if (statusTextEl) {
        statusTextEl.textContent = 'Element zapper active. Click on the page.';
      }
      window.close();
    } else {
      showError('Failed to activate element zapper');
      buttonEl.disabled = false;
    }
  });
}

/**
 * Get storage key for zapper rules for a domain
 * @param {string} domain
 * @returns {string}
 */
function getZapperStorageKey(domain) {
  return `${ZAPPER_RULES_PREFIX}${domain}`;
}

/**
 * Load zapper rules for the current domain from storage
 * @param {string} domain
 * @returns {Promise<string[]>}
 */
async function loadZapperRules(domain) {
  try {
    const key = getZapperStorageKey(domain);
    const result = await browser.storage.local.get(key);
    const rules = Array.isArray(result[key]) ? result[key] : [];
    log.info(`loadZapperRules domain=${domain} count=${rules.length}`);
    return rules;
  } catch (error) {
    log.error('Error loading zapper rules:', error);
    return [];
  }
}

/**
 * Save zapper rules for the current domain to storage
 * @param {string} domain
 * @param {string[]} rules
 * @returns {Promise<void>}
 */
async function saveZapperRules(domain, rules) {
  try {
    const key = getZapperStorageKey(domain);
    await browser.storage.local.set({ [key]: rules });
    log.info(`saveZapperRules domain=${domain} count=${rules.length}`);
  } catch (error) {
    log.error('Error saving zapper rules:', error);
  }
}

/**
 * Delete a specific zapper rule
 * @param {string} rule
 * @returns {Promise<void>}
 */
async function deleteZapperRule(rule) {
  if (!currentDomain) return;

  log.info(`deleteZapperRule domain=${currentDomain} selector=${rule}`);
  zapperRules = zapperRules.filter(r => r !== rule);
  await saveZapperRules(currentDomain, zapperRules);
  renderZapperRules();

  // Reload the current tab to apply changes
  const tab = await getCurrentTab();
  if (tab && tab.id) {
    browser.tabs.reload(tab.id);
  }
}

/**
 * Delete all zapper rules for the current domain
 * @returns {Promise<void>}
 */
async function deleteAllZapperRules() {
  if (!currentDomain) return;

  log.info(`deleteAllZapperRules domain=${currentDomain} previous=${zapperRules.length}`);
  zapperRules = [];
  await saveZapperRules(currentDomain, zapperRules);
  renderZapperRules();

  // Reload the current tab to apply changes
  const tab = await getCurrentTab();
  if (tab && tab.id) {
    browser.tabs.reload(tab.id);
  }
}

/**
 * Render the zapper rules in the UI
 */
function renderZapperRules() {
  const sectionEl = document.getElementById('zapper-rules-section');
  const countEl = document.getElementById('zapper-rules-count');
  const listEl = document.getElementById('zapper-rules-list');
  const clearAllEl = document.getElementById('zapper-clear-all');

  if (!sectionEl || !countEl || !listEl || !clearAllEl) return;

  // Update count
  countEl.textContent = zapperRules.length;

  // Show/hide section based on whether there are rules
  if (zapperRules.length > 0) {
    sectionEl.style.display = 'block';
  } else {
    sectionEl.style.display = 'none';
    return;
  }

  // Clear and rebuild list
  listEl.innerHTML = '';

  if (zapperRules.length === 0) {
    const emptyEl = document.createElement('div');
    emptyEl.className = 'zapper-rules-empty';
    emptyEl.textContent = 'No hidden elements on this site';
    listEl.appendChild(emptyEl);
    clearAllEl.style.display = 'none';
  } else {
    zapperRules.forEach(rule => {
      const itemEl = document.createElement('div');
      itemEl.className = 'zapper-rule-item';

      const selectorEl = document.createElement('span');
      selectorEl.className = 'zapper-rule-selector';
      selectorEl.textContent = rule;
      selectorEl.title = rule; // Show full selector on hover

      const deleteEl = document.createElement('button');
      deleteEl.className = 'zapper-rule-delete';
      deleteEl.textContent = '×';
      deleteEl.title = 'Remove this rule';
      deleteEl.addEventListener('click', (e) => {
        e.stopPropagation();
        deleteZapperRule(rule);
      });

      itemEl.appendChild(selectorEl);
      itemEl.appendChild(deleteEl);
      listEl.appendChild(itemEl);
    });

    clearAllEl.style.display = 'block';
  }
}

/**
 * Setup zapper rules UI event handlers
 */
function setupZapperRulesUI() {
  const toggleEl = document.getElementById('zapper-rules-toggle');
  const listEl = document.getElementById('zapper-rules-list');
  const clearAllEl = document.getElementById('zapper-clear-all');

  if (toggleEl && listEl) {
    toggleEl.addEventListener('click', () => {
      const isExpanded = listEl.classList.toggle('visible');
      toggleEl.classList.toggle('expanded', isExpanded);
    });
  }

  if (clearAllEl) {
    clearAllEl.addEventListener('click', () => {
      // Note: confirm() doesn't work in Safari extension popups
      // Using direct deletion - button text should make intent clear
      deleteAllZapperRules();
    });
  }
}

/**
 * Update the UI with stats
 * @param {Object} stats - Stats object
 * @param {string} domain - Current domain
 * @param {boolean} isWhitelisted - Whether domain is whitelisted
 */
function updateUI(stats, domain, isWhitelisted = false) {
  const loadingEl = document.getElementById('loading');
  const contentEl = document.getElementById('content');
  const totalCountEl = document.getElementById('total-count');
  const cssCountEl = document.getElementById('css-count');
  const extcssCountEl = document.getElementById('extcss-count');
  const scriptCountEl = document.getElementById('script-count');
  const domainEl = document.getElementById('domain');
  const statusDotEl = document.getElementById('status-dot');
  const statusTextEl = document.getElementById('status-text');

  // Hide loading, show content
  loadingEl.style.display = 'none';
  contentEl.style.display = 'block';

  // Update counts
  const total = stats.total || 0;
  totalCountEl.textContent = formatNumber(total);
  totalCountEl.className = total > 0 ? 'stats-count' : 'stats-count zero';

  cssCountEl.textContent = formatNumber(stats.cosmeticFilters || 0);
  extcssCountEl.textContent = formatNumber(stats.extendedCss || 0);
  // Combine scriptlets and JS scripts for display
  const totalScripts = (stats.scriptlets || 0) + (stats.scripts || 0);
  scriptCountEl.textContent = formatNumber(totalScripts);

  // Update domain
  domainEl.textContent = domain;

  // Update status based on whitelist and blocking status
  if (isWhitelisted) {
    statusDotEl.className = 'status-dot inactive';
    statusTextEl.textContent = 'Protection disabled for this site';
  } else if (total > 0) {
    statusDotEl.className = 'status-dot';
    statusTextEl.textContent = 'Advanced protection active';
  } else {
    statusDotEl.className = 'status-dot inactive';
    statusTextEl.textContent = 'No items blocked on this page';
  }

  // Update whitelist toggle
  updateWhitelistUI(isWhitelisted);
}

/**
 * Show error state
 * @param {string} message
 */
function showError(message) {
  const loadingEl = document.getElementById('loading');
  const contentEl = document.getElementById('content');

  loadingEl.style.display = 'none';
  contentEl.style.display = 'block';

  const statusTextEl = document.getElementById('status-text');
  const statusDotEl = document.getElementById('status-dot');

  statusDotEl.className = 'status-dot inactive';
  statusTextEl.textContent = message;
}

/**
 * Setup whitelist toggle event handler
 */
function setupWhitelistToggle() {
  const toggleEl = document.getElementById('whitelist-toggle');
  if (!toggleEl) return;

  toggleEl.addEventListener('change', async (event) => {
    if (!currentDomain) return;

    const shouldWhitelist = event.target.checked;
    toggleEl.disabled = true;

    const success = await toggleWhitelist(currentDomain, shouldWhitelist);

    if (success) {
      updateWhitelistUI(shouldWhitelist);

      // Show status update
      const statusTextEl = document.getElementById('status-text');
      if (shouldWhitelist) {
        statusTextEl.textContent = 'Site added to trusted list';
      } else {
        statusTextEl.textContent = 'Site removed from trusted list';
      }

      // Optionally reload the current tab to apply changes
      setTimeout(async () => {
        const tab = await getCurrentTab();
        if (tab && tab.id) {
          browser.tabs.reload(tab.id);
        }
      }, 500);
    } else {
      // Revert toggle on failure
      toggleEl.checked = !shouldWhitelist;
      showError('Failed to update trusted sites');
    }

    toggleEl.disabled = false;
  });
}

/**
 * Initialize popup
 */
async function init() {
  log.info('init: starting');
  try {
    // Setup toggle handler
    setupWhitelistToggle();
    setupZapperButton();
    setupZapperRulesUI();
    log.debug('init: UI handlers wired');

    // Get current tab
    const tab = await getCurrentTab();

    if (!tab) {
      log.warn('init: no active tab');
      showError('No active tab');
      return;
    }
    log.debug(`init: tab resolved id=${tab.id} url=${tab.url}`);

    // Check if URL is blockable
    if (!tab.url || (!tab.url.startsWith('http://') && !tab.url.startsWith('https://'))) {
      log.info(`init: URL not blockable (${tab.url}) — disabling toggle`);
      updateUI({ total: 0, cosmeticFilters: 0, extendedCss: 0, scriptlets: 0, scripts: 0 }, 'N/A', false);
      showError('Protection not available on this page');

      // Disable toggle for non-http pages
      const toggleEl = document.getElementById('whitelist-toggle');
      if (toggleEl) toggleEl.disabled = true;
      const zapperButtonEl = document.getElementById('zapper-button');
      if (zapperButtonEl) {
        zapperButtonEl.disabled = true;
        const hintEl = document.getElementById('zapper-hint');
        if (hintEl) hintEl.textContent = 'Element zapper is unavailable on this page';
      }
      return;
    }

    const domain = extractDomain(tab.url);
    currentDomain = domain;
    log.info(`init: domain=${domain}`);

    // Check whitelist status first
    const isWhitelisted = await checkWhitelistStatus(domain);

    // Load and display zapper rules for this domain
    zapperRules = await loadZapperRules(domain);
    renderZapperRules();

    // Request stats from background script
    log.debug(`init: requesting stats for tab=${tab.id}`);
    const response = await browser.runtime.sendMessage({
      type: 'getStats',
      tabId: tab.id
    });

    if (response && response.stats) {
      log.info(`init: stats received total=${response.stats.total}`);
      updateUI(response.stats, domain, isWhitelisted);
    } else {
      log.warn('init: no stats in response, rendering zeros');
      updateUI({ total: 0, cosmeticFilters: 0, extendedCss: 0, scriptlets: 0, scripts: 0 }, domain, isWhitelisted);
    }
    log.info('init: UI ready');
  } catch (error) {
    log.error('init failed:', error);
    showError('Failed to load stats');
  }
}

// Initialize when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
