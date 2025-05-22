// src/background.js

/**
 * WebShield Advanced - Background Script
 * Description: Handles communication with the native application, processes rules,
 *              and serves data to content scripts.
 *              This version is optimized for Manifest V2, uses a single message
 *              response pattern for content script requests, and always fetches
 *              rules from the native host (no caching).
 */

"use strict";

// --- Constants & Configuration ---
const NATIVE_APP_ID = "dev.arjuna.WebShield.Advanced"; // Updated to match our native app ID
const LOG_PREFIX = "[WebShield Advanced BG]";
const DEBUG_MODE = true; // Enable for verbose logs (e.g., detailed object logging)

// Add message types for rules update
const MESSAGE_TYPES = {
  REQUEST_UPDATE: 'requestRulesUpdate',
  RULES_UPDATED: 'rulesUpdated'
};

// --- Browser Compatibility ---
// Ensures that either `window.browser` (Firefox, newer Edge) or `window.chrome` (Chrome, older Edge) is used.
const browser = window.browser || window.chrome;

// --- Logging ---
// Provides structured logging utilities. Prepends messages with a prefix and level.
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

// --- Cache Configuration ---
const CACHE_MAX_SIZE = 100; // Max number of entries in the LRU cache
const CACHE_TTL_MS = 10 * 60 * 1000; // 10 minutes Time-To-Live for cache entries

// Add after the cache configuration
const CRITICAL_RULES_CACHE = new Map(); // For rules that must be applied immediately
const COMMON_DOMAINS = ['google.com', 'facebook.com', 'youtube.com', 'x.com', 'amazon.com', 'instagram.com', 'chatgpt.com', 'whatsapp.com', 'wikipedia.org', 'reddit.com', 'yahoo.co.jp', 'yahoo.com', 'yandex.ru', 'tiktok.com'];
const RULE_FETCH_TIMEOUT = 5000; // 5 second timeout for rule fetching
const PARALLEL_FETCH_LIMIT = 3; // Maximum number of parallel fetches

// Add after the cache configuration
class AsyncLock {
  constructor() {
    this.locks = new Map();
  }

  async acquire(key, callback) {
    if (!this.locks.has(key)) {
      this.locks.set(key, Promise.resolve());
    }

    const currentLock = this.locks.get(key);
    const newLock = currentLock.then(() => callback());
    this.locks.set(key, newLock);

    try {
      return await newLock;
    } finally {
      if (this.locks.get(key) === newLock) {
        this.locks.delete(key);
      }
    }
  }
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

// Improve RuleFetcher implementation
class RuleFetcher {
  constructor() {
    this.activeFetches = new Map();
    this.fetchQueue = [];
    this.processingQueue = false;
    this.lock = new AsyncLock();
    this.metrics = new PerformanceMetrics();
  }

  async fetch(url, priority = 'normal') {
    return this.lock.acquire(url, async () => {
      const hostname = getHostname(url);
      if (!hostname) return null;

      const startTime = performance.now();

      // Check critical cache first
      const criticalRules = CRITICAL_RULES_CACHE.get(hostname);
      if (criticalRules) {
        this.metrics.recordCacheHit('critical');
        log.debug(`Critical rules cache HIT for ${hostname}`);
        return { data: { metadataPayload: criticalRules }, source: "critical_cache" };
      }

      // Check regular cache
      const cachedRules = ruleMetadataCache.get(url);
      if (cachedRules) {
        this.metrics.recordCacheHit('regular');
        log.debug(`Regular cache HIT for ${url}`);
        return { data: { metadataPayload: cachedRules }, source: "memory_cache" };
      }

      this.metrics.recordCacheMiss();

      // If already fetching this URL, return the existing promise
      if (this.activeFetches.has(url)) {
        return this.activeFetches.get(url);
      }

      // Create new fetch promise
      const fetchPromise = this._executeFetch(url, priority);
      this.activeFetches.set(url, fetchPromise);

      try {
        const result = await fetchPromise;
        const fetchTime = performance.now() - startTime;
        this.metrics.recordFetchTime(fetchTime);
        return result;
      } finally {
        this.activeFetches.delete(url);
        this._processQueue();
      }
    });
  }

  async _executeFetch(url, priority) {
    try {
      const startTime = performance.now();

      // Fetch rules with timeout
      const fetchPromise = _fetchRulesFromNativeHostViaMessaging({ url });
      const timeoutPromise = new Promise((_, reject) =>
        setTimeout(() => reject(new Error('Rule fetch timeout')), RULE_FETCH_TIMEOUT)
      );

      const nativeResponseData = await Promise.race([fetchPromise, timeoutPromise]);
      const fetchTime = performance.now() - startTime;
      log.debug(`Rule fetch completed in ${fetchTime.toFixed(2)}ms`);

      // Process and package the rules
      const { metadataPayload } = _transformNativeResponseToMetadata(nativeResponseData, url);

      // Store in appropriate cache
      const hostname = getHostname(url);
      if (COMMON_DOMAINS.includes(hostname)) {
        CRITICAL_RULES_CACHE.set(hostname, metadataPayload);
      } else {
        ruleMetadataCache.set(url, metadataPayload);
      }

      return { data: { metadataPayload }, source: "native_app_fetch" };
    } catch (error) {
      this.metrics.recordError(error);
      log.error(`Failed to fetch rules for ${url}: ${error.message}`);
      throw error;
    }
  }

  _processQueue() {
    if (this.processingQueue || this.fetchQueue.length === 0) return;

    this.processingQueue = true;
    while (this.fetchQueue.length > 0 && this.activeFetches.size < PARALLEL_FETCH_LIMIT) {
      const { url, priority, resolve, reject } = this.fetchQueue.shift();
      this._executeFetch(url, priority).then(resolve).catch(reject);
    }
    this.processingQueue = false;
  }
}

// Initialize the rule fetcher
const ruleFetcher = new RuleFetcher();

// --- Native Host State ---
// Tracks the connection status and port for the persistent native host listener.
// This is for messages FROM the native host, not for request/response calls.
let nativeHostListenerConnected = false;
let nativeListenerPort = null;
// Note: The 'nativeHostConnected' variable used in the original 'sendNativeMessageRequest'
// was local to that promise chain or implied a different connection status.
// For clarity, 'nativeHostListenerConnected' is specific to the persistent listener.

// --- Utilities ---

/**
 * Extracts a valid hostname from a URL string.
 * Normalizes URLs (e.g., adds https:// if missing scheme) and handles common invalid cases.
 * @param {string} urlString - The URL string to parse.
 * @returns {string|null} The hostname, or null if parsing fails or URL is deemed invalid for extension purposes.
 */
const getHostname = (urlString) => {
  if (typeof urlString !== "string" || urlString.trim() === "") {
    log.warn("(getHostname) Received empty or non-string URL.");
    return null;
  }
  try {
    let normalizedUrl = urlString;
    // If no protocol, and doesn't look like a special URL (e.g. about:blank), prepend https.
    if (!normalizedUrl.includes("://") && !normalizedUrl.startsWith("about:")) {
      if (!normalizedUrl.startsWith("http") && !normalizedUrl.includes(":")) {
        // e.g. "example.com"
        normalizedUrl = "https://" + normalizedUrl;
      } else if (!normalizedUrl.startsWith("http")) {
        // e.g. "someservice:8000" or "ftp://example.com"
        // Check if it's a scheme we don't want to prepend http to, like ftp, ws, wss
        const knownSchemes = /^(ftp|ws|wss|file|ed2k):/i;
        if (knownSchemes.test(normalizedUrl)) {
          // Let the URL parser handle these directly if they are valid URLs
        } else if (normalizedUrl.includes(":")) {
          // Potentially a custom scheme or malformed
          log.debug(
            `(getHostname) Skipping URL with potentially unsupported scheme or format: ${normalizedUrl.substring(0, 30)}`,
          );
          return null;
        } else {
          // Default to https if unsure
          normalizedUrl = "https://" + normalizedUrl;
        }
      }
    }

    const url = new URL(normalizedUrl);

    // Handle special browser pages or non-hierarchical URIs
    if (
      url.protocol === "about:" ||
      url.protocol === "chrome:" ||
      url.protocol === "moz-extension:"
    ) {
      log.debug(
        `(getHostname) Skipping special URL: ${normalizedUrl.substring(0, 100)}`,
      );
      return null;
    }
    if (url.origin === "null" || !url.hostname) {
      log.debug(
        `(getHostname) Skipping URL with null origin or no hostname: ${normalizedUrl.substring(0, 100)}`,
      );
      return null;
    }
    // Reject hostnames that are likely not actual internet hostnames (e.g. single words without dots)
    // unless it's localhost. This helps filter out things like internal chrome pages or invalid entries.
    if (url.hostname.indexOf(".") === -1 && url.hostname !== "localhost") {
      log.debug(
        `(getHostname) Skipping likely invalid hostname (no TLD, not localhost): ${url.hostname}`,
      );
      return null;
    }
    return url.hostname;
  } catch (e) {
    log.warn(
      `(getHostname) Failed to parse URL: "${urlString.substring(0, 100)}". Error: ${e.message}`,
    );
    return null;
  }
};

// --- Native Messaging (Request-Response TO Native Host) ---
// Handles sending requests to the native application and receiving potentially chunked responses.

/**
 * Internal helper to accumulate chunks from the native host for a single request.
 * This function encapsulates the loop for sending messages and receiving parts of a large response.
 * @param {string} url - The URL for which rules are being requested.
 * @returns {Promise<{accumulatedData: string, verboseInfo: any}>} Resolves with accumulated data and verbose info.
 * @throws {Error} If communication with native host fails or response is malformed.
 * @private
 */
const _accumulateNativeResponseChunks = async (url) => {
  let accumulatedData = "";
  let verboseInfo = null;
  let moreChunksExpected = true;
  let isFirstRequest = true;

  log.debug(
    `(_accumulateNativeResponseChunks) Starting accumulation for URL: ${url.substring(0, 100)}`,
  );

  while (moreChunksExpected) {
    const messageToSend = {
      action: "getRulesForHost", // Action expected by the native application
      url: url,
      fromBeginning: isFirstRequest, // Tells native app if it should resend from start (if supported)
    };

    log.debug(
      `(_accumulateNativeResponseChunks) Sending chunk request to native host (first: ${isFirstRequest}):`,
      messageToSend,
    );

    try {
      const responseChunk = await browser.runtime.sendNativeMessage(
        NATIVE_APP_ID,
        messageToSend,
      );

      // Validate responseChunk structure
      if (typeof responseChunk !== "object" || responseChunk === null) {
        throw new Error("Invalid response chunk: not an object or null.");
      }
      if (responseChunk.error) {
        // Native application reported an error
        throw new Error(`Native host error: ${responseChunk.error}`);
      }
      // 'data' field should ideally be a string. If missing or other type, treat as empty string for safety.
      const currentChunkData =
        typeof responseChunk.data === "string" ? responseChunk.data : "";
      log.debug(
        `(_accumulateNativeResponseChunks) Received chunk. Data length: ${currentChunkData.length}. Keys:`,
        Object.keys(responseChunk),
      );

      // Update verboseInfo if provided in any chunk
      verboseInfo = responseChunk.verbose ?? verboseInfo;

      // Handle chunking logic
      const isChunkedResponse = responseChunk.chunked === true; // Explicitly check for boolean true
      if (isChunkedResponse) {
        accumulatedData += currentChunkData;
        moreChunksExpected = responseChunk.more === true; // Explicitly check for boolean true
        if (!moreChunksExpected) {
          log.debug(
            `(_accumulateNativeResponseChunks) Last chunk received for ${url.substring(0, 100)}.`,
          );
        }
      } else {
        // If 'chunked' is not true, assume this is the complete data.
        accumulatedData = currentChunkData;
        moreChunksExpected = false;
        log.debug(
          `(_accumulateNativeResponseChunks) Received non-chunked or final response for ${url.substring(0, 100)}.`,
        );
      }

      isFirstRequest = false; // Subsequent requests are not the first
    } catch (error) {
      // This catches errors from browser.runtime.sendNativeMessage itself (e.g., host not found)
      // or errors thrown from the validation logic above.
      log.error(
        `(_accumulateNativeResponseChunks) Error during send/receive for ${url.substring(0, 100)}: ${error.message}`,
      );
      throw new Error(
        `Failed to send/receive message chunk for ${url.substring(0, 100)}: ${error.message}`,
      );
    }
  }
  log.info(
    `(_accumulateNativeResponseChunks) Finished accumulation for ${url.substring(0, 100)}. Total data length: ${accumulatedData.length}.`,
  );
  return { accumulatedData, verboseInfo };
};

/**
 * Internal helper to parse the accumulated JSON data from the native host.
 * @param {string} accumulatedData - The JSON string data.
 * @param {string} urlForLogging - The URL for context in logging.
 * @returns {object} The parsed data object. Returns empty object if data is empty string.
 * @throws {Error} If JSON parsing fails.
 * @private
 */
const _parseAccumulatedNativeResponse = (accumulatedData, urlForLogging) => {
  if (accumulatedData === "") {
    log.info(
      `(_parseAccumulatedNativeResponse) Accumulated data is empty for ${urlForLogging.substring(0, 100)}. Returning empty object.`,
    );
    return {}; // Consistent with original behavior for empty data
  }
  let parsedData;
  try {
    parsedData = JSON.parse(accumulatedData);
  } catch (parseError) {
    log.error(
      `(_parseAccumulatedNativeResponse) JSON parse error for ${urlForLogging.substring(0, 100)}: ${parseError.message}. Data (first 500 chars): ${accumulatedData.substring(0, 500)}`,
    );
    throw new Error(`JSON parse error: ${parseError.message}`); // Propagate for sendNativeMessageRequest to handle
  }

  // Security Enhancement: Validate that parsedData is a non-null object.
  if (typeof parsedData !== "object" || parsedData === null) {
    log.error(
      `(_parseAccumulatedNativeResponse) Parsed data is not a valid object for ${urlForLogging.substring(0, 100)}. Type: ${typeof parsedData}. Value:`,
      parsedData,
    );
    throw new Error(
      "Invalid data structure: Parsed native response is not a non-null object.",
    );
  }

  return parsedData;
};

/**
 * Sends a message to the native application and expects a response.
 * Manages chunked responses and parsing of the final JSON data.
 * @param {{url: string}} originalMessage - The message containing the URL to send.
 * @returns {Promise<{data: object, verbose: any}>} A promise that resolves with the parsed data and verbose info.
 * @throws {Error} If the URL is missing/invalid, or if native communication/parsing fails.
 */
const _fetchRulesFromNativeHostViaMessaging = async (originalMessage) => {
  const url = originalMessage?.url;
  if (!url || typeof url !== "string") {
    log.warn(
      "(_fetchRulesFromNativeHostViaMessaging) Invalid or missing URL in request.",
    );
    throw new Error("URL missing or invalid in native message request.");
  }

  log.info(
    `(_fetchRulesFromNativeHostViaMessaging) Initiating request for ${url.substring(0, 100)}...`,
  );

  try {
    // Step 1: Accumulate all response chunks from the native host
    const { accumulatedData, verboseInfo } =
      await _accumulateNativeResponseChunks(url);

    // Step 2: Parse the accumulated data
    const parsedData = _parseAccumulatedNativeResponse(accumulatedData, url);

    log.info(
      `(_fetchRulesFromNativeHostViaMessaging) Successfully received and parsed data for ${url.substring(0, 100)}.`,
    );
    return { data: parsedData, verbose: verboseInfo };
  } catch (error) {
    // This catches errors from _accumulateNativeResponseChunks or _parseAccumulatedNativeResponse
    log.error(
      `(_fetchRulesFromNativeHostViaMessaging) Native messaging pipeline failed for ${url.substring(0, 100)}: ${error.message}`,
    );
    // No need to manage nativeHostListenerConnected here as it's for the listener port.
    throw error; // Re-throw the error to be handled by the caller (e.g., getAdvancedBlockingDataPackage)
  }
};

// --- LRU Cache Implementation ---
class LruCache {
  constructor(maxSize, ttlMs) {
    this.maxSize = maxSize;
    this.ttlMs = ttlMs;
    this.cache = new Map(); // Stores { key: { value, timestamp, lastAccessed } } - using Map to maintain insertion order for LRU
    log.info(
      `(LruCache) Initialized with maxSize: ${maxSize}, ttlMs: ${ttlMs}`,
    );
  }

  /**
   * Retrieves an item from the cache.
   * If found and not expired, marks it as recently used and returns it.
   * If expired or not found, removes it and returns null.
   * @param {string} key
   * @returns {any|null} The cached value or null.
   */
  get(key) {
    const entry = this.cache.get(key);
    if (!entry) {
      log.debug(`(LruCache.get) MISS for key: ${key.substring(0, 100)}`);
      return null;
    }

    const now = Date.now();
    if (now - entry.timestamp > this.ttlMs) {
      log.debug(
        `(LruCache.get) EXPIRED for key: ${key.substring(0, 100)}. Timestamp: ${entry.timestamp}, TTL: ${this.ttlMs}`,
      );
      this.cache.delete(key);
      return null;
    }

    // Mark as recently used by removing and re-inserting
    this.cache.delete(key);
    entry.lastAccessed = now; // Update lastAccessed time, though not strictly needed for Map-based LRU if re-inserting
    this.cache.set(key, entry);
    log.debug(`(LruCache.get) HIT for key: ${key.substring(0, 100)}`);
    return entry.value;
  }

  /**
   * Adds an item to the cache.
   * If the cache is full, evicts the least recently used item.
   * @param {string} key
   * @param {any} value
   */
  set(key, value) {
    if (this.cache.has(key)) {
      // If key already exists, delete it to re-insert and mark as new/recently used
      this.cache.delete(key);
    } else if (this.cache.size >= this.maxSize) {
      // Evict least recently used item (first item in Map's iteration order)
      const lruKey = this.cache.keys().next().value;
      this.cache.delete(lruKey);
      log.debug(
        `(LruCache.set) EVICTED LRU key: ${lruKey.substring(0, 100)} due to maxSize limit.`,
      );
    }

    const entry = {
      value: value,
      timestamp: Date.now(),
      lastAccessed: Date.now(), // For potential future non-Map based LRU or debugging
    };
    this.cache.set(key, entry);
    log.debug(
      `(LruCache.set) SET key: ${key.substring(0, 100)}. Cache size: ${this.cache.size}`,
    );
  }

  /**
   * Clears all items from the cache.
   */
  clear() {
    this.cache.clear();
    log.info("(LruCache.clear) Cache cleared.");
  }
}

// Initialize the cache instance
const ruleMetadataCache = new LruCache(CACHE_MAX_SIZE, CACHE_TTL_MS);

// --- Rule Processing & Packaging ---
// Transforms raw data from the native host into a format usable by content scripts.

/**
 * Processes scriptlet entries from the native host, ensuring they are valid and correctly formatted.
 * Invalid scriptlets are logged and skipped.
 * @param {Array<string|object>|undefined} rawScriptlets - Array of scriptlets from native host.
 * @param {string} urlForLogging - URL for logging context.
 * @returns {Array<{name: string, args: Array<any>}>} Processed and validated scriptlets.
 * @private
 */
const _processScriptlets = (rawScriptlets, urlForLogging) => {
  // Security Enhancement: Ensure rawScriptlets is an array. If not, log and default to empty.
  if (!Array.isArray(rawScriptlets)) {
    if (rawScriptlets !== undefined && rawScriptlets !== null) {
      // Log only if it exists, is not null, but isn't an array
      log.warn(
        `(_processScriptlets) Input 'rawScriptlets' is not an array for ${urlForLogging.substring(0, 100)}. Type: ${typeof rawScriptlets}. Defaulting to empty array. Value:`,
        rawScriptlets,
      );
    } else if (rawScriptlets === undefined) {
      log.debug(
        `(_processScriptlets) 'rawScriptlets' is undefined for ${urlForLogging.substring(0, 100)}. Defaulting to empty array.`,
      );
    }
    return []; // Return empty array if undefined, null, or not an array
  }

  return rawScriptlets
    .map((s, index) => {
      try {
        let scriptletObj;
        // Security Enhancement: Stricter check for scriptlet object structure.
        if (typeof s === "object" && s !== null) {
          if (typeof s.name !== "string" || s.name.trim() === "") {
            log.warn(
              `(_processScriptlets) Invalid scriptlet object at index ${index}: 'name' must be a non-empty string. For ${urlForLogging.substring(0, 100)}. Scriptlet:`,
              s,
            );
            return null;
          }
          // Args must be an array if present, otherwise default to empty array.
          if (s.args !== undefined && !Array.isArray(s.args)) {
            log.warn(
              `(_processScriptlets) Invalid scriptlet object at index ${index}: 'args' must be an array if present. Got ${typeof s.args}. For ${urlForLogging.substring(0, 100)}. Scriptlet:`,
              s,
            );
            s.args = []; // Default to empty array
          }
          scriptletObj = s;
        } else if (typeof s === "string") {
          // Handle JSON string scriptlets
          if (s.trim() === "") {
            log.warn(
              `(_processScriptlets) Empty scriptlet string at index ${index} for ${urlForLogging.substring(0, 100)}.`,
            );
            return null;
          }
          try {
            scriptletObj = JSON.parse(s);
            // Validate structure after parsing string
            if (
              typeof scriptletObj !== "object" ||
              scriptletObj === null ||
              typeof scriptletObj.name !== "string" ||
              scriptletObj.name.trim() === ""
            ) {
              log.warn(
                `(_processScriptlets) Invalid scriptlet structure after parsing string at index ${index} for ${urlForLogging.substring(0, 100)}:`,
                scriptletObj,
              );
              return null;
            }
            // Ensure 'args' is an array, default to empty array if missing or not an array after parsing.
            if (
              scriptletObj.args !== undefined &&
              !Array.isArray(scriptletObj.args)
            ) {
              log.warn(
                `(_processScriptlets) Invalid scriptlet 'args' after parsing string at index ${index}: must be an array if present. Got ${typeof scriptletObj.args}. Corrected to empty array. For ${urlForLogging.substring(0, 100)}. Scriptlet:`,
                scriptletObj,
              );
              scriptletObj.args = [];
            } else if (scriptletObj.args === undefined) {
              scriptletObj.args = []; // Ensure args property exists
            }
          } catch (e) {
            log.warn(
              `(_processScriptlets) Failed to parse scriptlet JSON string at index ${index} for ${urlForLogging.substring(0, 100)}: "${s.substring(0, 100)}...". Error: ${e.message}`,
            );
            return null; // Skip this scriptlet
          }
        } else {
          // Neither a valid object nor a string
          log.warn(
            `(_processScriptlets) Invalid scriptlet entry type at index ${index} for ${urlForLogging.substring(0, 100)}. Type: ${typeof s}. Entry:`,
            s,
          );
          return null; // Skip this scriptlet
        }

        // At this point, scriptletObj is valid and scriptletObj.args is guaranteed to be an array (possibly empty).
        return { name: scriptletObj.name, args: scriptletObj.args };
      } catch (e) {
        // This catch is a fallback for any unexpected errors during processing of a single scriptlet.
        log.error(
          `(_processScriptlets) Unexpected error processing scriptlet entry at index ${index} for ${urlForLogging.substring(0, 100)}. Error: ${e.message}. Scriptlet:`,
          s,
          e.stack,
        );
        return null; // Skip this scriptlet
      }
    })
    .filter((s) => s !== null); // Filter out any nulls (skipped scriptlets)
};

/**
 * Validates the structure and content of blocking data
 * @param {object} data - The blocking data to validate
 * @returns {boolean} Whether the data is valid
 */
function validateBlockingData(data) {
  if (!data || typeof data !== 'object') {
    log.error('Invalid blocking data: not an object');
    return false;
  }

  const requiredFields = ['cssInject', 'cssExtended', 'scripts', 'scriptlets'];
  const missingFields = requiredFields.filter(field => !(field in data));

  if (missingFields.length > 0) {
    log.error(`Missing required fields: ${missingFields.join(', ')}`);
    return false;
  }

  // Validate each field's type
  if (!Array.isArray(data.cssInject)) {
    log.error('cssInject must be an array');
    return false;
  }
  if (!Array.isArray(data.cssExtended)) {
    log.error('cssExtended must be an array');
    return false;
  }
  if (!Array.isArray(data.scripts)) {
    log.error('scripts must be an array');
    return false;
  }
  if (!Array.isArray(data.scriptlets)) {
    log.error('scriptlets must be an array');
    return false;
  }

  // Validate scriptlet structure
  const invalidScriptlets = data.scriptlets.filter(s =>
    !s || typeof s !== 'object' || typeof s.name !== 'string' || !Array.isArray(s.args)
  );
  if (invalidScriptlets.length > 0) {
    log.error(`Found ${invalidScriptlets.length} invalid scriptlets`);
    return false;
  }

  return true;
}

/**
 * Logs statistics about the blocking data
 * @param {object} data - The blocking data to analyze
 */
function logBlockingDataStats(data) {
  const stats = {
    cssInjectCount: data.cssInject.length,
    cssExtendedCount: data.cssExtended.length,
    scriptsCount: data.scripts.length,
    scriptletsCount: data.scriptlets.length,
    scriptletTypes: [...new Set(data.scriptlets.map(s => s.name))]
  };

  log.info('Blocking Data Statistics:', stats);
  return stats;
}

/**
 * Processes the raw data from the native host and packages it into a metadata payload for content scripts.
 * @param {{data: object, verbose: any}|null} nativeResponseData - The response from sendNativeMessageRequest.
 * @param {string} url - The URL for which rules are being processed (for logging context).
 * @returns {{metadataPayload: object}} The packaged metadata.
 * @throws {Error} If nativeResponseData or its 'data' field is invalid.
 */
const _transformNativeResponseToMetadata = (nativeResponseData, url) => {
  // Security Enhancement: Validate nativeResponseData and its 'data' field (rulesData)
  if (
    typeof nativeResponseData?.data !== "object" ||
    nativeResponseData.data === null
  ) {
    log.error(
      `(_transformNativeResponseToMetadata) Invalid or missing 'data' object in nativeResponseData for ${url.substring(0, 100)}. Response:`,
      nativeResponseData,
    );
    throw new Error(
      "Invalid or missing 'data' object from native host for rule processing.",
    );
  }

  const rulesData = nativeResponseData.data;
  
  // Log statistics about the data
  logBlockingDataStats(rulesData);

  log.debug(
    `(_transformNativeResponseToMetadata) Processing raw native data for ${url.substring(0, 100)}... Top-level keys in rulesData:`,
    Object.keys(rulesData),
  );

  // Helper function to validate and filter string arrays - this can remain local or be moved to a shared util if needed elsewhere
  const validateStringArray = (dataArray, arrayName, urlForLogging) => {
    if (dataArray === undefined || dataArray === null) {
      log.debug(
        `(_transformNativeResponseToMetadata) '${arrayName}' is undefined or null for ${urlForLogging.substring(0, 100)}. Defaulting to empty array.`,
      );
      return []; // Default to empty if undefined or null
    }
    if (!Array.isArray(dataArray)) {
      log.warn(
        `(_transformNativeResponseToMetadata) '${arrayName}' is not an array for ${urlForLogging.substring(0, 100)}. Type: ${typeof dataArray}. Defaulting to empty array. Value:`,
        dataArray,
      );
      return [];
    }
    const filteredArray = dataArray.filter((item) => {
      if (typeof item === "string") return true;
      log.warn(
        `(_transformNativeResponseToMetadata) Non-string item found in '${arrayName}' for ${urlForLogging.substring(0, 100)}. Item:`,
        item,
      );
      return false;
    });
    if (filteredArray.length !== dataArray.length) {
      log.debug(
        `(_transformNativeResponseToMetadata) Some non-string items were filtered from '${arrayName}' for ${urlForLogging.substring(0, 100)}.`,
      );
    }
    return filteredArray;
  };

  // Construct the metadata payload with enhanced validation
  const metadataPayload = {
    cssInject: validateStringArray(rulesData.cssInject, "cssInject", url),
    cssExtended: validateStringArray(rulesData.cssExtended, "cssExtended", url),
    scripts: validateStringArray(rulesData.scripts, "scripts", url),
    scriptlets: _processScriptlets(rulesData.scriptlets, url), // _processScriptlets handles its own array and content validation
    timestamp: Date.now(),
    source: "native_app", // Indicates data came directly from native app (no caching)
  };

  if (DEBUG_MODE) {
    // Log a summary of the packaged data if DEBUG_MODE is on
    log.debug(
      `(_transformNativeResponseToMetadata) Assembled validated metadata package for ${url.substring(0, 100)}. Counts:`,
      {
        cssInjectCount: metadataPayload.cssInject.length,
        cssExtendedCount: metadataPayload.cssExtended.length,
        scriptsCount: metadataPayload.scripts.length,
        scriptletsCount: metadataPayload.scriptlets.length,
        source: metadataPayload.source,
        timestamp: metadataPayload.timestamp,
      },
    );
  }
  return { metadataPayload };
};

// --- Main Content Script Request Handler ---
// Handles requests from content scripts to get blocking data for a given URL.

/**
 * Orchestrates fetching data from the native host and processing it for a given URL.
 * This is the primary function called by the content script message listener.
 * @param {string} url - The URL for which to get blocking data.
 * @returns {Promise<{data?: {metadataPayload: object}, error?: string, source?: string}>}
 *          Resolves with the data package or an error object.
 */
const getAdvancedBlockingDataPackage = async (url) => {
  const hostname = getHostname(url);
  if (!hostname) {
    log.info(`Skipping request for invalid/non-host URL: ${url.substring(0, 100)}`);
    return {
      data: {
        metadataPayload: {
          source: "skipped_invalid_url",
          timestamp: Date.now(),
          cssInject: [],
          cssExtended: [],
          scripts: [],
          scriptlets: [],
        },
      },
    };
  }

  try {
    return await ruleFetcher.fetch(url);
  } catch (error) {
    log.error(`Failed to get data for ${hostname}: ${error.message}`);
    return { error: error.message };
  }
};

// --- Native Host Listener (Messages FROM Native Host) ---
// Manages a persistent connection to the native host for messages initiated BY the native host
// (e.g., notifications about rule updates). This is distinct from the request/response mechanism.

/**
 * Handles messages received from the native host via the persistent listener port (`nativeListenerPort`).
 * @param {object} message - The message received from the native host.
 */
function handleNativeHostMessage(message) {
  log.info("Message received FROM native host listener:", message);
  const action = message?.action;

  switch (action) {
    case "rulesUpdated":
      log.info(
        "(handleNativeHostMessage) Received 'rulesUpdated' notification from native host. Clearing metadata cache.",
      );
      ruleMetadataCache.clear(); // Clear the cache
      break;
    case "pong": // Response to a 'ping' if implemented
      log.debug(
        "(handleNativeHostMessage) Received 'pong' from native host listener, confirming connection health.",
      );
      nativeHostListenerConnected = true; // Re-affirm connection status
      break;
    default:
      log.warn(
        "Received unknown or unhandled action from native host listener:",
        action,
        message,
      );
  }
}

/**
 * Handles disconnection of the persistent native host listener port (`nativeListenerPort`).
 * Sets state variables and logs the event. Reconnection attempts are managed by `connectAndListenToNativeHost`.
 */
function handleNativeHostDisconnect() {
  const lastError = browser.runtime.lastError;
  const errorMsg = lastError
    ? lastError.message
    : "No specific error details provided by runtime.";
  log.warn(
    `Disconnected from native host listener port: ${errorMsg}. Will attempt to reconnect on next relevant event (e.g., startup, or if explicitly triggered).`,
  );

  nativeHostListenerConnected = false;
  if (nativeListenerPort) {
    // Clean up listeners to prevent potential memory leaks if port object somehow persists
    try {
      nativeListenerPort.onMessage.removeListener(handleNativeHostMessage);
      nativeListenerPort.onDisconnect.removeListener(
        handleNativeHostDisconnect,
      );
    } catch (e) {
      log.warn(
        `(handleNativeHostDisconnect) Error removing listeners from old port: ${e.message}`,
      );
    }
  }
  nativeListenerPort = null; // Crucial: Clear the port reference
}

/**
 * Establishes and maintains a persistent connection to listen for messages FROM the native host.
 * If a connection attempt fails, it logs the error and does not retry automatically in a loop
 * to prevent overwhelming the system; retries should be event-driven (e.g., on startup).
 */
function connectAndListenToNativeHost() {
  if (nativeListenerPort) {
    log.debug(
      "(connectAndListenToNativeHost) Native host listener port check: Port object exists.",
    );
    // It's hard to reliably check if an existing port is *truly* alive without sending a message.
    // Relying on onDisconnect to clear nativeListenerPort is the primary mechanism.
    // If nativeHostListenerConnected is true, we assume it's okay for now.
    if (nativeHostListenerConnected) {
      log.debug(
        "(connectAndListenToNativeHost) Listener port already exists and is marked as connected.",
      );
      return;
    }
    // If port object exists but nativeHostListenerConnected is false, it might be a stale state.
    log.warn(
      "(connectAndListenToNativeHost) Listener port object existed but was marked disconnected. Attempting to clear and reconnect.",
    );
    try {
      nativeListenerPort.disconnect(); // Attempt to explicitly disconnect the old port
    } catch (e) {
      log.warn(
        `(connectAndListenToNativeHost) Error disconnecting stale port: ${e.message}`,
      );
    }
    nativeListenerPort = null; // Ensure it's cleared before reconnecting
  }

  log.info(
    "(connectAndListenToNativeHost) Attempting to establish listener connection TO native host...",
  );
  try {
    nativeListenerPort = browser.runtime.connectNative(NATIVE_APP_ID);
    // Connection is established, now set up listeners on this new port.
    nativeListenerPort.onMessage.addListener(handleNativeHostMessage);
    nativeListenerPort.onDisconnect.addListener(handleNativeHostDisconnect);

    nativeHostListenerConnected = true; // Assume connected once connectNative returns without error. onDisconnect will correct this.
    log.info(
      "(connectAndListenToNativeHost) Listener port successfully initiated connection to native host.",
    );

    // Optional: Send a 'ping' to the native host to confirm two-way communication if the native app supports it.
    // This can help verify the connection beyond just the port object creation.
    // nativeListenerPort.postMessage({ action: "ping" });
    // log.debug("(connectAndListenToNativeHost) Sent 'ping' to native host listener.");
  } catch (error) {
    // This catch handles errors from browser.runtime.connectNative itself.
    nativeHostListenerConnected = false;
    nativeListenerPort = null; // Ensure port is null on failure
    log.error(
      `(connectAndListenToNativeHost) Failed to connect listener port to native host: ${error.message}`,
    );
    // Do not automatically retry here to avoid loops. Retry on specific events (startup, etc.).
  }
}

// --- Event Listeners (Extension Lifecycle & Content Script Messages) ---

// Handles extension installation or update.
browser.runtime.onInstalled.addListener((details) => {
  log.info(`Extension onInstalled event. Reason: ${details.reason}`);
  connectAndListenToNativeHost();
  preloadCommonRules().catch(error =>
    log.error('Failed to preload common rules:', error)
  );
});

// Handles browser startup.
browser.runtime.onStartup.addListener(() => {
  log.info("Extension onStartup event: Initializing listener connection...");
  // All caching logic related to rules has been removed.
  // Establish the persistent listener connection to the native host.
  connectAndListenToNativeHost();
});

// Main message listener for requests from content scripts.
// This listener handles actions dispatched from content scripts, primarily 'getAdvancedBlockingData'.
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const action = message?.action;
  const tabId = sender?.tab?.id ?? "N/A"; // Get Tab ID if available
  // Truncate sender URL for brevity in logs if it's very long.
  const senderUrlPreview =
    sender?.url && sender.url.length > 100
      ? sender.url.substring(0, 97) + "..."
      : sender?.url || "N/A";

  log.debug(
    `Message received: action='${action}' from TabID=${tabId}, SenderURL=${senderUrlPreview}`,
  );

  if (action === "getAdvancedBlockingData") {
    const requestUrl = message.url;
    // Validate the URL received from the content script.
    if (
      typeof requestUrl !== "string" ||
      (!requestUrl.startsWith("http") &&
        !requestUrl.startsWith("ftp") &&
        !requestUrl.startsWith("ws") &&
        !requestUrl.startsWith("wss"))
    ) {
      log.warn(
        `(onMessage) Received invalid or unsupported URL scheme for '${action}': ${requestUrl}`,
      );
      // It's important to call sendResponse if returning false or not returning true to close the message channel.
      // However, the context might be invalidated if the content script tab/frame has already navigated away.
      try {
        sendResponse({
          error: "URL is required and must be http(s), ftp(s), ws(s)",
        });
      } catch (e) {
        log.warn(
          `(onMessage) Failed to send error response for invalid URL ('${requestUrl}'). Context likely closed: ${e.message}`,
        );
      }
      return false; // Synchronous response indicating failure; no async work will be done.
    }

    const requestUrlPreview =
      requestUrl.length > 100
        ? requestUrl.substring(0, 97) + "..."
        : requestUrl;
    log.info(
      `(onMessage) Handling 'getAdvancedBlockingData' for URL: ${requestUrlPreview} (TabID ${tabId})`,
    );

    // Use an async IIFE to handle the promise chain for getAdvancedBlockingDataPackage and sendResponse.
    (async () => {
      let responsePayload = null;
      try {
        // This function now handles its own errors and returns an object with an 'error' key if something fails.
        responsePayload = await getAdvancedBlockingDataPackage(requestUrl);

        if (responsePayload && !responsePayload.error) {
          log.debug(
            `(onMessage) Successfully prepared data package for ${requestUrlPreview}. Source: ${responsePayload.source || "unknown"}`,
          );
        } else if (responsePayload?.error) {
          // Error is already logged by getAdvancedBlockingDataPackage, just log that we're sending it.
          log.warn(
            `(onMessage) Sending error response for ${requestUrlPreview}: ${responsePayload.error}`,
          );
        } else {
          // This case should ideally not be reached if getAdvancedBlockingDataPackage always returns a defined object.
          log.warn(
            `(onMessage) 'getAdvancedBlockingDataPackage' returned an unexpected or null/undefined value for ${requestUrlPreview}. Responding with generic error. Value:`,
            responsePayload,
          );
          responsePayload = {
            error:
              "Unknown error: Did not receive valid data or error from data package handler.",
          };
        }
      } catch (e) {
        // This catch is for unexpected errors *within this async IIFE itself*, not from getAdvancedBlockingDataPackage (which should handle its own).
        log.error(
          `(onMessage) Critical error in 'getAdvancedBlockingData' message handler for ${requestUrlPreview}: ${e.message}`,
          e.stack || "(no stack)",
        );
        responsePayload = {
          error:
            e.message ||
            "Unknown background error occurred while processing the request.",
        };
      }

      // Attempt to send the response payload (either data or error) back to the content script.
      try {
        // Check if sendResponse is still a function; the context might have closed.
        if (typeof sendResponse === "function") {
          sendResponse(responsePayload);
        } else {
          log.warn(
            `(onMessage) sendResponse is no longer a function for ${requestUrlPreview}. Context (tab/frame) likely closed before response could be sent.`,
          );
        }
      } catch (e) {
        // This catches errors if sendResponse itself fails (e.g., if the receiving end is truly gone and an error is thrown).
        log.warn(
          `(onMessage) Could not send response for ${requestUrlPreview}. Sender context likely closed, or other error during sendResponse: ${e.message}`,
        );
      }
    })();

    return true; // Crucial: Indicate that sendResponse will be called asynchronously.
  }

  if (action === "reportScriptletError") {
    log.error(
      `(onMessage) SCRIPTLET EXECUTION ERROR reported from Tab ${tabId} (URL: ${senderUrlPreview}):`,
      message.detail,
    );
    // No response needed for this type of message. Consider if sendResponse should be called with {success: true} or similar if sender expects it.
    // For now, assuming no response is fine.
    return false; // No asynchronous response.
  }

  // If the action is not recognized:
  log.warn(
    `(onMessage) Unhandled message action received: '${action}'. Full message:`,
    message,
  );
  // Optionally, send a response indicating the action is unhandled.
  // try { sendResponse({ error: `Unhandled action: ${action}` }); } catch (e) { /* ignore */ }
  return false; // No response for unhandled actions, or synchronous if sendResponse used above.
});

// Add rules update handling
async function handleRulesUpdateRequest(sendResponse) {
  try {
    const response = await browser.runtime.sendNativeMessage(NATIVE_APP_ID, {
      action: 'checkRulesUpdate'
    });

    if (response.hasUpdated && response.rulesData) {
      await notifyTabsOfUpdate(response.rulesData);
    }
    sendResponse({ success: true });
  } catch (error) {
    log.error('Error handling rules update request:', error);
    sendResponse({ success: false, error: error.message });
  }
}

async function notifyTabsOfUpdate(rulesData) {
  const tabs = await browser.tabs.query({});
  const notifications = tabs.map(tab => notifyTab(tab.id, rulesData));
  await Promise.allSettled(notifications);
}

async function notifyTab(tabId, rulesData) {
  try {
    await browser.tabs.sendMessage(tabId, {
      type: MESSAGE_TYPES.RULES_UPDATED,
      rulesData
    });
  } catch (error) {
    log.debug(`Could not send rules update to tab ${tabId}:`, error);
  }
}

// Update message listener to handle rules update requests
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === MESSAGE_TYPES.REQUEST_UPDATE) {
    handleRulesUpdateRequest(sendResponse);
    return true; // Keep the message channel open for the async response
  }
  // ... existing message handling ...
});

// Add preloading function
async function preloadCommonRules() {
  log.info('Preloading rules for common domains...');
  const preloadPromises = COMMON_DOMAINS.map(async domain => {
    try {
      const url = `https://${domain}`;
      await ruleFetcher.fetch(url, 'high');
      log.debug(`Preloaded rules for ${domain}`);
    } catch (error) {
      log.warn(`Failed to preload rules for ${domain}:`, error);
    }
  });
  await Promise.allSettled(preloadPromises);
}

// --- Initialization ---
// Code to run when the background script is first loaded (e.g., on extension install/update or browser startup).

log.info("Background script initializing...");
(() => {
  // Using a simple IIFE for synchronous initialization steps.
  // Attempt to connect the persistent listener to the native host.
  connectAndListenToNativeHost();
  log.info(
    "Background script initialization complete. Listener to native host has been initiated (if successful).",
  );
})();
