/*
 * WebExtension v1.0.0 (build date: Sat, 12 Jul 2025 21:09:27 GMT)
 * (c) 2025 ameshkov
 * Released under the ISC license
 * https://github.com/ameshkov/safari-blocker
 */
(function (browser) {
  "use strict";

  const LOG_PREFIX = "[WebShield Advanced] (Background)";
  console.log(`${LOG_PREFIX} Background script loaded.`);

  // Global variable to track the engine timestamp.
  let engineTimestamp = 0;
  let verbose = false; // Verbose logging flag
  // Cache to store the rules for a given URL. The key is a URL (string) and
  // the value is a ResponseMessage. Caching responses allows us to respond to
  // content script requests quickly while also updating the cache in the
  // background.
  const cache = new Map();
  // Returns a cache key for the given URL and top-level URL.
  const cacheKey = (url, topUrl) => `${url}#${topUrl ?? ""}`;

  /**
   * Makes a native messaging request to obtain rules for the given message.
   * Also handles cache invalidation if the engine timestamp has changed.
   *
   * @param request - Original request from the content script.
   * @param url - Page URL for which the rules are requested.
   * @param topUrl - Top-level page URL (to distinguish between frames)
   * @returns The response message from the native host.
   */
  const requestRules = async (request, url, topUrl) => {
    console.log(
      `${LOG_PREFIX} Sending native message for url:`,
      url,
      "topUrl:",
      topUrl,
      "request:",
      request
    );
    // Prepare the request payload.
    request.payload = {
      url,
      topUrl,
    };
    // Send the request to the native messaging host and wait for the response.
    const response = await browser.runtime.sendNativeMessage(
      "application.id",
      request
    );
    console.log(`${LOG_PREFIX} Received native response:`, response);
    const message = response;
    // Mark the end of background processing in the trace.
    message.trace.backgroundEnd = new Date().getTime();
    // Extract the configuration from the response payload.
    const configuration = message.payload;
    // new ContentScript(configuration).run(true, "[WebShield Advanced]");
    // If the engine timestamp has been updated, clear the cache and update
    // the timestamp.
    if (configuration.engineTimestamp !== engineTimestamp) {
      console.log(
        `${LOG_PREFIX} Engine timestamp changed from`,
        engineTimestamp,
        "to",
        configuration.engineTimestamp,
        "- clearing cache."
      );
      cache.clear();
      engineTimestamp = configuration.engineTimestamp;
    }
    // Save the new message in the cache for the given URL.
    const key = cacheKey(url, topUrl);
    cache.set(key, message);
    console.log(`${LOG_PREFIX} Cached response for key:`, key);
    return message;
  };

  // Helper for conditional logging
  function vLog(...args) {
    if (verbose) {
      console.log(...args);
    }
  }

  /**
   * Message listener that intercepts messages sent to the background script.
   * It tries to immediately return a cached response if available while also
   * updating the cache in the background.
   */
  browser.runtime.onMessage.addListener(async (request, sender) => {
    // Set verbose flag if requested by content script
    if (request && typeof request.verbose === "boolean") {
      verbose = true;
      console.log(`${LOG_PREFIX} Verbose mode set to:`, verbose);
    }
    console.log(
      `${LOG_PREFIX} onMessage received:`,
      request,
      "sender:",
      sender
    );
    // Cast the incoming request as a Message.
    const message = request;
    // Extract the URL from the sender data.
    const senderData = sender;
    const { url } = senderData;
    const topUrl = senderData.frameId === 0 ? null : senderData.tab.url;
    const key = cacheKey(url, topUrl);
    console.log(`${LOG_PREFIX} Computed cache key:`, key);
    // If there is already a cached response for this URL:
    if (cache.has(key)) {
      console.log(`${LOG_PREFIX} Cache hit for key:`, key);
      // Fire off a new request to update the cache in the background.
      requestRules(message, url, topUrl);
      // Retrieve the cached response.
      const cachedMessage = cache.get(key);
      // Get the current time for updating trace values.
      const now = new Date().getTime();
      if (cachedMessage) {
        // Update all relevant trace timestamps so that the caller can see
        // recent trace data.
        cachedMessage.trace.contentStart = message.trace.contentStart;
        cachedMessage.trace.backgroundStart = now;
        cachedMessage.trace.backgroundEnd = now;
        cachedMessage.trace.nativeStart = now;
        cachedMessage.trace.nativeEnd = now;
      }
      // Return the cached message immediately.
      console.log(
        `${LOG_PREFIX} Returning cached message for key:`,
        key,
        cachedMessage
      );
      return cachedMessage;
    }
    // If there is no cached response, mark the start time for background
    // processing.
    message.trace.backgroundStart = new Date().getTime();
    console.log(
      `${LOG_PREFIX} Cache miss for key:`,
      key,
      "- requesting rules from native host."
    );
    // Await the native request to get a fresh response.
    const responseMessage = await requestRules(message, url, topUrl);
    // Return the new response.
    console.log(
      `${LOG_PREFIX} Returning new response for key:`,
      key,
      responseMessage
    );
    return responseMessage;
  });
})(browser);
