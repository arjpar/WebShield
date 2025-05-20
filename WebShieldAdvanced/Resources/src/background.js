// src/background.js

/**
 * WebShield Advanced - Background Script (Optimized MV2 - Single Message Response)
 * CHANGE: Removed ALL caching (Memory & Storage). Always fetches from native host.
 * CHANGE: Removed scriptlet code packaging; only sends metadata.
 */

"use strict";

const browser = window.browser || window.chrome;

// --- Configuration ---
const NATIVE_APP_ID = "application.id"; // *** Replace with your actual native app ID ***
const LOG_PREFIX = "[WebShield Advanced BG]";
// REMOVED: MEMORY_CACHE_MAX_ITEMS
const DEBUG_MODE = true; // Enable for verbose logs

// --- Logging ---
const log = {
  info: (msg, ...args) => console.info(`${LOG_PREFIX} ${msg}`, ...args),
  error: (msg, ...args) => console.error(`${LOG_PREFIX} ${msg}`, ...args),
  warn: (msg, ...args) => console.warn(`${LOG_PREFIX} ${msg}`, ...args),
  debug: (msg, ...args) => {
    if (DEBUG_MODE) console.log(`${LOG_PREFIX} [DEBUG] ${msg}`, ...args);
  },
};

// --- Caches ---
// REMOVED: ruleMetadataMemoryCache

// --- Native Host State ---
let nativeHostConnected = false;
let nativePort = null;

// --- Utilities ---
const getHostname = (urlString) => {
  // Keep this function as is
  try {
    if (!urlString.includes("://")) {
      if (!urlString.startsWith("http") && !urlString.includes(":"))
        urlString = "https://" + urlString;
      else if (!urlString.startsWith("http")) {
        if (urlString.includes(":")) {
          log.debug(
            `(getHostname) Skipping non-http(s) URL prefix: ${urlString.substring(0, 20)}`,
          );
          return null;
        }
        urlString = "https://" + urlString;
      }
    }
    const url = new URL(urlString);
    if (url.origin === "null" || !url.hostname) {
      log.debug(
        `(getHostname) Skipping URL with null origin or no hostname: ${urlString.substring(0, 100)}`,
      );
      return null;
    }
    return url.hostname;
  } catch (e) {
    log.warn(
      `(getHostname) Failed to parse URL: "${urlString.substring(0, 100)}"`,
      e.message,
    );
    return null;
  }
};

// --- Cache Loading/Saving ---
// REMOVED: All caching functions (loadPersistentCacheToMemory, saveMetadataToStorage)

// --- Native Messaging (Request/Response TO Native Host) ---
const sendNativeMessageRequest = (originalMessage) => {
  // Keep this function as is
  return new Promise(async (resolve, reject) => {
    const url = originalMessage.url;
    if (!url) return reject(new Error("URL missing"));
    log.info(
      `(sendNativeMessageRequest) Sending request for ${url.substring(0, 100)}...`,
    );
    try {
      let accumulatedData = "",
        isChunked = false,
        verboseInfo = null,
        moreChunks = true,
        isFirstChunkRequest = true;
      while (moreChunks) {
        const messageToSend = {
          action: "getRulesForHost",
          url: url,
          fromBeginning: isFirstChunkRequest,
        };
        log.debug(
          "(sendNativeMessageRequest) Sending message to native host:",
          JSON.stringify(messageToSend).substring(0, 500),
        );
        const responseChunk = await browser.runtime.sendNativeMessage(
          NATIVE_APP_ID,
          messageToSend,
        );
        if (typeof responseChunk !== "object" || responseChunk === null)
          throw new Error(
            "Invalid response chunk received (not an object or null)",
          );
        log.debug(
          "(sendNativeMessageRequest) Received response chunk keys:",
          Object.keys(responseChunk),
        );
        nativeHostConnected = true;
        if (responseChunk.error) throw new Error(responseChunk.error);
        isChunked = responseChunk.chunked ?? isChunked;
        verboseInfo = responseChunk.verbose ?? verboseInfo;
        const currentChunkData = String(responseChunk.data || "");
        if (isChunked) {
          accumulatedData += currentChunkData;
          moreChunks = responseChunk.more ?? false;
        } else {
          accumulatedData = currentChunkData;
          moreChunks = false;
        }
        isFirstChunkRequest = false;
      }
      log.info(
        `(sendNativeMessageRequest) Finished receiving data for ${url.substring(0, 100)}. Total Length: ${accumulatedData.length}.`,
      );
      if (accumulatedData === "") {
        log.info(
          `(sendNativeMessageRequest) Received empty data for ${url.substring(0, 100)}.`,
        );
        resolve({ data: {}, verbose: verboseInfo });
        return;
      }
      try {
        const parsedData = JSON.parse(accumulatedData);
        resolve({ data: parsedData, verbose: verboseInfo });
      } catch (parseError) {
        log.error(
          `(sendNativeMessageRequest) JSON parse error for ${url.substring(0, 100)}: ${parseError.message}. Data received (first 500 chars): ${accumulatedData.substring(0, 500)}`,
        );
        reject(new Error(`JSON parse error: ${parseError.message}`));
      }
    } catch (error) {
      const errMsg = error?.message || String(error);
      log.error(
        `(sendNativeMessageRequest) Native messaging failed for ${url.substring(0, 100)}:`,
        errMsg,
      );
      nativeHostConnected = false;
      reject(new Error(errMsg));
    }
  });
};

// --- Rule Metadata & Code Processing ---
const processAndPackageRules = (nativeResponseData, url) => {
  // Keep this function as is
  if (
    !nativeResponseData ||
    typeof nativeResponseData.data !== "object" ||
    nativeResponseData.data === null
  ) {
    throw new Error("Invalid or empty data object received from native host.");
  }
  const rulesData = nativeResponseData.data;
  log.debug(
    `(processAndPackageRules) Processing raw native data for ${url.substring(0, 100)}...`,
  );
  const metadataPayload = {
    cssInject: rulesData.cssInject || [],
    cssExtended: rulesData.cssExtended || [],
    scripts: rulesData.scripts || [],
    scriptlets: [],
    timestamp: Date.now(),
    source: "native_app",
  };
  if (rulesData.scriptlets && Array.isArray(rulesData.scriptlets)) {
    metadataPayload.scriptlets = rulesData.scriptlets
      .map((s) => {
        try {
          let scriptletObj;
          if (typeof s === "object" && s !== null && typeof s.name === "string")
            scriptletObj = s;
          else if (typeof s === "string") scriptletObj = JSON.parse(s);
          else return null;
          if (
            typeof scriptletObj !== "object" ||
            typeof scriptletObj.name !== "string"
          )
            throw new Error("Invalid scriptlet object structure");
          return { name: scriptletObj.name, args: scriptletObj.args || [] };
        } catch (e) {
          log.warn(
            `(processAndPackageRules) Failed to parse/validate scriptlet entry for ${url.substring(0, 100)}:`,
            s,
            e.message,
          );
          return null;
        }
      })
      .filter((s) => s !== null);
  }
  log.debug(
    `(processAndPackageRules) Assembled metadata package for ${url.substring(0, 100)}.`,
    {
      /* summary */
    },
  );
  return { metadataPayload };
};

// --- Main Request Handler Logic ---
const getAdvancedBlockingDataPackage = async (url) => {
  const hostname = getHostname(url);
  if (!hostname) {
    log.info(
      `(getAdvancedBlockingDataPackage) Skipping request for invalid/non-host URL: ${url.substring(0, 100)}`,
    );
    return { data: { metadataPayload: { source: "skipped_invalid_url" } } };
  }
  log.info(
    `(getAdvancedBlockingDataPackage) Request received for: ${hostname} (URL: ${url.substring(0, 100)}...) - NO CACHING`,
  );

  // REMOVED: Memory Cache Check
  // REMOVED: Storage Cache Check

  // ALWAYS Request from Native Host
  log.info(
    `(getAdvancedBlockingDataPackage) Requesting from NATIVE host for ${hostname} (no cache lookup).`,
  );
  try {
    const nativeResponseData = await sendNativeMessageRequest({ url: url });
    const { metadataPayload } = processAndPackageRules(nativeResponseData, url);

    // REMOVED: Caching logic (memory and storage)

    return { data: { metadataPayload }, source: "native_app_nocache" }; // Indicate source
  } catch (nativeError) {
    log.error(
      `(getAdvancedBlockingDataPackage) NATIVE request failed for ${hostname}:`,
      nativeError.message,
    );
    return { error: nativeError.message || "Native host request failed" };
  }
};

// --- Native Host Communication (Listener FOR Native Host) ---
function handleNativeHostMessage(message) {
  log.info("Message received FROM native host:", message);
  const action = message?.action;
  if (action === "rulesUpdated") {
    // Only log now, no cache to clear
    log.info(
      "Received 'rulesUpdated' notification from native host. No cache to clear.",
    );
    // REMOVED: ruleMetadataMemoryCache.clear();
    // REMOVED: clearPersistentStorageCache();
  } else if (action === "pong") {
    log.debug("Received pong from native host.");
    nativeHostConnected = true;
  } else {
    log.warn(
      "Received unknown or unhandled action from native host:",
      action,
      message,
    );
  }
}

function handleNativeHostDisconnect() {
  // Keep this function as is
  nativeHostConnected = false;
  const errorMsg = browser.runtime.lastError
    ? browser.runtime.lastError.message
    : "No error details";
  log.warn(
    `Disconnected from native host listener port: ${errorMsg}. Will attempt reconnect on next request or startup.`,
  );
  nativePort = null;
}

function connectAndListenToNativeHost() {
  // Keep this function as is
  if (nativePort) {
    log.debug("Native host listener port check: Already exists.");
    return;
  }
  log.info(
    "Attempting to establish connection for listening TO native host...",
  );
  try {
    nativePort = browser.runtime.connectNative(NATIVE_APP_ID);
    nativeHostConnected = true;
    log.info("Listener port connected to native host.");
    nativePort.onMessage.addListener(handleNativeHostMessage);
    nativePort.onDisconnect.addListener(handleNativeHostDisconnect);
  } catch (error) {
    nativeHostConnected = false;
    nativePort = null;
    log.error("Failed to connect listener port to native host:", error.message);
  }
}

// --- Event Listeners (Extension Lifecycle & Content Script Messages) ---
browser.runtime.onInstalled.addListener(async (details) => {
  log.info(`onInstalled event: ${details.reason}`);
  // REMOVED: Cache loading/clearing logic
  connectAndListenToNativeHost();
});

browser.runtime.onStartup.addListener(async () => {
  log.info("onStartup event: Initializing listener connection...");
  // REMOVED: Cache loading logic
  connectAndListenToNativeHost();
});

// Main Message Listener (from Content Scripts) - Keep this function as is
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const action = message?.action;
  const tabId = sender?.tab?.id ?? "N/A";
  const senderUrl = sender?.url?.substring(0, 100) || "N/A";
  log.debug(
    `Message received: action=${action} from Tab=${tabId} URL=${senderUrl}`,
  );

  if (action === "getAdvancedBlockingData") {
    const url = message.url;
    if (typeof url !== "string" || !url.startsWith("http")) {
      log.warn(`Received invalid URL for ${action}: ${url}`);
      try {
        sendResponse({ error: "URL is required and must be http/https" });
      } catch (e) {}
      return false;
    }
    log.info(
      `Handling getAdvancedBlockingData request for: ${url.substring(0, 100)}... (Tab ${tabId})`,
    );
    (async () => {
      let response = null;
      try {
        response = await getAdvancedBlockingDataPackage(url); // Will always fetch from native now
        if (response && !response.error) {
          log.debug(
            `Sending metadata package response for ${url.substring(0, 50)}... (Source: ${response.source})`,
          );
        } else if (response?.error) {
          log.warn(
            `Sending error response for ${url.substring(0, 50)}...: ${response.error}`,
          );
        } else {
          log.warn(
            `getAdvancedBlockingDataPackage returned unexpected value for ${url.substring(0, 50)}:`,
            response,
          );
          response = { error: "Unknown error retrieving blocking data." };
        }
      } catch (e) {
        log.error(
          `Critical error in getAdvancedBlockingData handler for ${url}:`,
          e.message,
          e.stack,
        );
        response = {
          error: e.message || "Unknown background error processing request",
        };
      }
      try {
        if (typeof sendResponse === "function") sendResponse(response);
        else
          log.warn(
            `sendResponse is no longer a function for ${url.substring(0, 50)}. Context likely closed.`,
          );
      } catch (e) {
        log.warn(
          `Could not send metadata package response for ${url.substring(0, 50)}... Sender context likely closed:`,
          e.message,
        );
      }
    })();
    return true; // Indicate asynchronous response
  }

  if (action === "reportScriptletError") {
    log.error(
      `SCRIPTLET EXECUTION ERROR reported from Tab ${tabId} (URL: ${senderUrl}):`,
      message.detail,
    );
    return false; // No response needed
  }

  log.warn(`Unhandled message action received: ${action}`);
  return false;
});

// --- Initial Setup ---
log.info("Background script initializing...");
(async () => {
  connectAndListenToNativeHost();
  log.info("Background script initialization complete.");
})();
