/**
 * background.js — WebShield background page.
 *
 * Router for the content_cosmetic.js ↔ native bridge. Message types:
 *
 *   cosmeticSetup       → forwarded to native; returns per-URL hideSelectors,
 *                         proceduralActions, exceptions, scriptletInjections,
 *                         injectedScript, genericHide, engineTimestamp.
 *   cosmeticSelectors   → forwarded to native; returns class/id-targeted
 *                         hide selectors for newly discovered DOM elements.
 *   injectScriptlet     → runs the engine's pre-composed scriptlet bundle in
 *                         the page main world via browser.scripting.executeScript
 *                         (world: "MAIN", injectImmediately: true, frameIds).
 *
 * Also handles popup-originated messages: getStats, checkWhitelist,
 * toggleWhitelist, plus zapperRuleAdded from the in-page element zapper.
 */

const {
	initBadgeManager,
	updateBadge,
} = globalThis.WebShieldBadgeManager;
const {
	getTabStats,
	incrementStat,
} = globalThis.WebShieldStats;

const NATIVE_APP_ID = "application.id";

const LOG_PREFIX = "[WebShield BG]";
const LOG_DEBUG = true;
const log = {
	info: (...a) => console.log(LOG_PREFIX, ...a),
	debug: (...a) => {
		if (LOG_DEBUG) console.debug(LOG_PREFIX, ...a);
	},
	warn: (...a) => console.warn(LOG_PREFIX, ...a),
	error: (...a) => console.error(LOG_PREFIX, ...a),
};

initBadgeManager();

// ---------- native plumbing ----------

async function callNative(type, payload) {
	const started = performance.now();
	log.debug(`callNative → ${type}`, payload ? Object.keys(payload) : []);
	try {
		const response = await browser.runtime.sendNativeMessage(NATIVE_APP_ID, {
			type,
			payload,
		});
		const ms = (performance.now() - started).toFixed(1);
		const payloadKeys = response?.payload ? Object.keys(response.payload) : [];
		log.debug(`callNative ← ${type} (${ms}ms)`, payloadKeys);
		return response ?? null;
	} catch (error) {
		log.error(`native ${type} failed:`, error);
		return null;
	}
}

// ---------- scriptlet injection ----------

function scriptletHead(code, n = 120) {
	if (typeof code !== "string") return "<non-string>";
	const oneLine = code.replace(/\s+/g, " ").trim();
	return oneLine.length > n ? oneLine.slice(0, n) + "…" : oneLine;
}

// Best-effort count of scriptlets in a Brave adblock-rust bundle.
// Each scriptlet is wrapped in `try { ... } catch (...) { ... }` at the top
// level, so counting `try {` occurrences is a reasonable approximation.
function approxScriptletCount(code) {
	if (typeof code !== "string") return 0;
	const matches = code.match(/\btry\s*\{/g);
	return matches ? matches.length : 1;
}

/**
 * Body of the injected function. Dispatched via browser.scripting.executeScript
 * with world: "MAIN" + injectImmediately: true, so it runs in the page's main
 * world at document_start. The `(0, window.eval)(wrapped)` call is a no-op hop
 * (we're already in main world) but stays as a defensive evaluator in case the
 * runtime substitutes the wrapped IIFE through a different scope. Falls back to
 * inserting a `<script>` element if eval is blocked (e.g. strict CSP).
 * The scriptlet source itself is the Brave/adblock-rust assembled bundle.
 */
function __webshieldRunScriptlet(code, expectedURL) {
	const PREFIX = "[WebShield Scriptlet]";
	const codeLen = typeof code === "string" ? code.length : 0;
	const head =
		typeof code === "string"
			? code.replace(/\s+/g, " ").trim().slice(0, 120)
			: "<non-string>";
	const started = performance.now();
	console.log(
		`${PREFIX} start url=${location.href} origin=${location.origin} ` +
			`codeLen=${codeLen} head=${head}`,
	);
	try {
		if (typeof expectedURL === "string" && expectedURL.length > 0) {
			const expectedOrigin = new URL(expectedURL, location.href).origin;
			if (expectedOrigin !== location.origin) {
				const message = `origin mismatch expected=${expectedOrigin} actual=${location.origin}`;
				console.log(`${PREFIX} skipped: ${message}`);
				return { ok: true, skipped: true, error: message };
			}
		}

		const wrapped = `
(() => {
	const scriptletGlobals = globalThis.__webshieldScriptletGlobals
		|| (globalThis.__webshieldScriptletGlobals = new Map());
	const deAmpEnabled = false;
${code}
})();
`;
		let method = "window.eval";
		try {
			(0, window.eval)(wrapped);
		} catch (evalError) {
			method = "script-element";
			const script = document.createElement("script");
			script.textContent = wrapped;
			(document.documentElement || document.head || document).appendChild(script);
			script.remove();
		}
		const ms = (performance.now() - started).toFixed(1);
		console.log(`${PREFIX} complete url=${location.href} method=${method} (${ms}ms)`);
		return { ok: true, applied: 1, method };
	} catch (error) {
		console.error(`${PREFIX} threw url=${location.href}:`, error);
		return { ok: false, error: String(error) };
	}
}

function injectionResult(response) {
	if (!Array.isArray(response)) return { ok: true };
	let applied = 0;
	const unsupported = [];
	let firstError;
	for (const item of response) {
		const result = item?.result ?? item;
		if (!result || typeof result !== "object") continue;
		if (Number.isFinite(result.applied)) applied += result.applied;
		if (Array.isArray(result.unsupported)) {
			unsupported.push(...result.unsupported);
		}
		if (result.ok === false && !result.skipped && firstError === undefined) {
			firstError = result.error || "unknown";
		}
	}
	if (firstError !== undefined && applied === 0) {
		return { ok: false, error: firstError, applied, unsupported };
	}
	return { ok: true, applied, unsupported };
}

async function injectScriptlet(tabId, frameId, code, expectedURL) {
	if (!tabId || typeof code !== "string" || code.trim().length === 0) {
		log.debug(
			`injectScriptlet skipped tab=${tabId} frame=${frameId ?? "*"} ` +
				`codeLen=${typeof code === "string" ? code.length : 0}`,
		);
		return { ok: false, reason: "empty" };
	}
	const head = scriptletHead(code);
	const approxCount = approxScriptletCount(code);
	const targetFrame = typeof frameId === "number" ? frameId : 0;
	log.info(
		`injectScriptlet → tab=${tabId} frame=${targetFrame} ` +
			`url=${expectedURL || "(unknown)"} codeLen=${code.length} ` +
			`bundle≈${approxCount} head=${head}`,
	);
	const started = performance.now();
	try {
		const response = await browser.scripting.executeScript({
			target: { tabId, frameIds: [targetFrame] },
			world: "MAIN",
			injectImmediately: true,
			func: __webshieldRunScriptlet,
			args: [code, expectedURL || ""],
		});
		const result = injectionResult(response);
		const ms = (performance.now() - started).toFixed(1);
		if (result.ok === false) {
			log.warn(
				`injectScriptlet ✗ tab=${tabId} frame=${targetFrame} ` +
					`url=${expectedURL} (${ms}ms): ${result.error || "unknown"}`,
			);
			return result;
		}
		incrementStat(tabId, "scriptlets", approxCount);
		const stats = getTabStats(tabId);
		updateBadge(tabId, stats.total);
		log.info(
			`injectScriptlet ✓ tab=${tabId} frame=${targetFrame} ` +
				`(${ms}ms) applied=${result.applied} tabScriptlets=${stats.scriptlets}`,
		);
		return { ok: true, applied: result.applied };
	} catch (error) {
		log.error(
			`injectScriptlet ✗ tab=${tabId} frame=${frameId ?? "*"} ` +
				`url=${expectedURL}:`,
			error,
		);
		return { ok: false, error: String(error) };
	}
}

// ---------- stat counting for cosmetic injections ----------

function countCosmeticHits(tabId, payload) {
	if (!tabId || !payload) return;
	const hideCount = Array.isArray(payload.hideSelectors)
		? payload.hideSelectors.length
		: 0;
	const procCount = Array.isArray(payload.proceduralActions)
		? payload.proceduralActions.length
		: 0;
	if (hideCount > 0) incrementStat(tabId, "cosmeticFilters", hideCount);
	if (procCount > 0) incrementStat(tabId, "extendedCss", procCount);
	if (hideCount > 0 || procCount > 0) {
		const total = getTabStats(tabId).total;
		updateBadge(tabId, total);
		log.info(
			`cosmeticSetup → tab=${tabId} hide=${hideCount} proc=${procCount} total=${total}`,
		);
	} else {
		log.debug(`cosmeticSetup → tab=${tabId} no hits`);
	}
}

function countSelectorHits(tabId, payload) {
	if (!tabId || !payload) return;
	const count = Array.isArray(payload.selectors) ? payload.selectors.length : 0;
	if (count > 0) {
		incrementStat(tabId, "cosmeticFilters", count);
		const total = getTabStats(tabId).total;
		updateBadge(tabId, total);
		log.info(
			`cosmeticSelectors → tab=${tabId} selectors=${count} total=${total}`,
		);
	} else {
		log.debug(`cosmeticSelectors → tab=${tabId} no selectors`);
	}
}

// ---------- popup / whitelist handlers ----------

async function popupGetStats(tabId) {
	if (!tabId) {
		const tabs = await browser.tabs.query({
			active: true,
			currentWindow: true,
		});
		if (tabs.length > 0) tabId = tabs[0].id;
	}
	if (!tabId) {
		log.warn("popupGetStats: no tabId resolved, returning zeros");
		return {
			stats: {
				cosmeticFilters: 0,
				scriptlets: 0,
				extendedCss: 0,
				scripts: 0,
				total: 0,
			},
		};
	}
	const stats = getTabStats(tabId);
	log.info(`popupGetStats tab=${tabId} total=${stats.total}`);
	return { stats };
}

async function popupCheckWhitelist(domain) {
	if (!domain) {
		log.warn("popupCheckWhitelist: no domain provided");
		return { isWhitelisted: false };
	}
	log.info(`popupCheckWhitelist domain=${domain}`);
	const response = await callNative("checkWhitelist", { domain });
	const isWhitelisted = response?.payload?.isWhitelisted === true;
	log.info(
		`popupCheckWhitelist ← domain=${domain} whitelisted=${isWhitelisted}`,
	);
	return { isWhitelisted };
}

async function popupToggleWhitelist(domain, whitelist) {
	if (!domain) {
		log.warn("popupToggleWhitelist: no domain provided");
		return { success: false };
	}
	log.info(`popupToggleWhitelist domain=${domain} whitelist=${whitelist}`);
	const response = await callNative("toggleWhitelist", { domain, whitelist });
	const success = response?.payload?.success === true;
	log.info(`popupToggleWhitelist ← domain=${domain} success=${success}`);
	return { success };
}

async function zapperRuleAdded(tabId) {
	if (!tabId) {
		log.warn("zapperRuleAdded: no tabId");
		return { ok: false };
	}
	incrementStat(tabId, "cosmeticFilters", 1);
	const total = getTabStats(tabId).total;
	updateBadge(tabId, total);
	log.info(`zapperRuleAdded tab=${tabId} total=${total}`);
	return { ok: true };
}

// ---------- message routing ----------

browser.runtime.onMessage.addListener((request, sender) => {
	if (!request || typeof request !== "object") return false;
	const tabId = sender?.tab?.id;
	const frameId = sender?.frameId;
	log.debug(`onMessage type=${request.type} tab=${tabId} frame=${frameId}`);

	switch (request.type) {
		case "cosmeticSetup":
			return (async () => {
				const response = await callNative(
					"cosmeticSetup",
					request.payload || {},
				);
				countCosmeticHits(tabId, response?.payload);
				return response;
			})();

		case "cosmeticSelectors":
			return (async () => {
				const response = await callNative(
					"cosmeticSelectors",
					request.payload || {},
				);
				countSelectorHits(tabId, response?.payload);
				return response;
			})();

		case "injectScriptlet":
			return injectScriptlet(
				tabId,
				frameId,
				request.payload?.code,
				request.payload?.url,
			);

		case "getStats":
			return popupGetStats(request.tabId);

		case "checkWhitelist":
			return popupCheckWhitelist(request.domain);

		case "toggleWhitelist":
			return popupToggleWhitelist(request.domain, request.whitelist === true);

		case "zapperRuleAdded":
			return zapperRuleAdded(tabId);

		default:
			log.warn(`onMessage: unhandled type=${request.type}`);
			return false;
	}
});

log.info("background ready");
