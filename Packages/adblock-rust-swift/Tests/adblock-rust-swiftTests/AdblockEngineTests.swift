import Foundation
import Testing
@testable import adblock_rust_swift

@Test func contentBlockerRulesSmokeTest() throws {
    let result = contentBlockerRules(fromFilterSet: "||example.com^\n")

    #expect(result.truncated == false)
    #expect(result.unsupportedRulesCount == 0)
    let data = try #require(result.json.data(using: .utf8))
    let decoded = try JSONSerialization.jsonObject(with: data)
    let rules = try #require(decoded as? [[String: Any]])
    #expect(rules.isEmpty == false)
}

@Test func contentBlockerRulesUnsupportedCountTest() {
    let result = contentBlockerRules(fromFilterSet: """
    ||example.com^
    ||foo.com$redirect=bar.js

    """)

    #expect(result.unsupportedRulesCount == 1)
}

@Test func contentBlockerRulesCustomLimitTruncatesOutput() throws {
    let result = contentBlockerRules(
        fromFilterSet: """
        ||one.example^
        ||two.example^
        ||three.example^

        """,
        ruleLimit: 2
    )

    #expect(result.truncated)
    let data = try #require(result.json.data(using: .utf8))
    let decoded = try JSONSerialization.jsonObject(with: data)
    let rules = try #require(decoded as? [[String: Any]])
    #expect(rules.count == 2)
}

@Test func contentBlockerRulesDefaultLimitRemainsUntruncated() {
    let result = contentBlockerRules(fromFilterSet: """
    ||one.example^
    ||two.example^
    ||three.example^

    """)

    #expect(result.truncated == false)
    #expect(result.unsupportedRulesCount == 0)
}

@Test func contentBlockerRulesUnsupportedCountSurvivesCustomLimit() {
    let result = contentBlockerRules(
        fromFilterSet: """
        ||example.com^
        ||foo.com$redirect=bar.js

        """,
        ruleLimit: 1
    )

    #expect(result.unsupportedRulesCount == 1)
}

@Test func defaultResourcesSmokeTest() {
    let resources = AdblockEngine.defaultResourcesJSON()

    #expect(resources.contains(#""name":"nowebrtc.js""#))
}

@Test func cosmeticResourcesSmokeTest() {
    let engine = AdblockEngine(filterSet: """
    example.com##.ad
    ##.sponsor

    """)

    let resources = engine.cosmeticResources(for: "https://example.com/article")
    #expect(resources.contains(".ad"))

    let stylesheet = engine.stylesheetForCosmeticRules(
        classes: ["sponsor"],
        ids: [],
        exceptionsJSON: resources
    )
    #expect(stylesheet.contains(".sponsor"))
}

@Test func serializedEngineRoundTripSmokeTest() {
    let original = AdblockEngine(filterSet: """
    example.com##.ad

    """)
    original.useDefaultResources()

    let data = original.serializedData()
    #expect(data.isEmpty == false)

    let restored = AdblockEngine(serializedData: data)
    restored.useDefaultResources()

    let resources = restored.cosmeticResourceDetails(
        for: "https://example.com/article"
    )
    #expect(resources.hideSelectors.contains(".ad"))
}

@Test func genericClassIdStylesheetSmokeTest() {
    let engine = AdblockEngine(filterSet: """
    ##.sponsor
    ###ad-slot

    """)
    let resources = engine.cosmeticResourceDetails(for: "https://example.com/")
    let stylesheet = engine.stylesheetForCosmeticRules(
        classes: ["sponsor"],
        ids: ["ad-slot"],
        resources: resources
    )

    #expect(stylesheet.contains(".sponsor"))
    #expect(stylesheet.contains("#ad-slot"))
}

@Test func genericClassIdSelectorsSmokeTest() {
    let engine = AdblockEngine(filterSet: """
    ##.ADBox
    ###ad-slot

    """)
    let resources = engine.cosmeticResourceDetails(for: "https://example.com/")
    let selectors = engine.selectorsForCosmeticRules(
        classes: ["ADBox"],
        ids: ["ad-slot"],
        resources: resources
    )

    #expect(selectors.contains(".ADBox"))
    #expect(selectors.contains("#ad-slot"))
    #expect(selectors.contains { $0.contains("display: none") } == false)
}

@Test func genericClassIdStylesheetStillReturnsCssRules() {
    let engine = AdblockEngine(filterSet: """
    ##.ADBox

    """)
    let stylesheet = engine.stylesheetForCosmeticRules(
        classes: ["ADBox"],
        ids: [],
        exceptionsJSON: "[]"
    )

    #expect(stylesheet.contains(".ADBox { display: none !important; }"))
}

@Test func defaultResourceScriptletSmokeTest() {
    let engine = AdblockEngine(filterSet: """
    example.com##+js(nowebrtc)

    """)
    engine.useDefaultResources()

    let resources = engine.cosmeticResourceDetails(
        for: "https://example.com/article"
    )

    #expect(resources.injectedScript.isEmpty == false)
    #expect(resources.injectedScript.contains("try"))
    #expect(resources.scriptletInjections.map(\.name).contains("nowebrtc.js"))
}

@Test func importantRuleOverridesNetworkException() {
    let engine = AdblockEngine(filterSet: """
    ||ads.example.com^$important
    @@||ads.example.com^

    """)

    let result = engine.checkNetworkRequest(
        url: "https://ads.example.com/script.js",
        sourceURL: "https://publisher.example/",
        requestType: "script"
    )

    #expect(result.matched)
    #expect(result.important)
    #expect(result.exception == nil)
    #expect(result.filter?.contains("$important") == true)
}

@Test func proceduralCosmeticFiltersAreSerializedForContentScript() throws {
    let engine = AdblockEngine(filterSet: """
    example.com##div:has(.ad):remove()
    example.com##div:has-text(Sponsored)
    example.com##div:matches-css(width: 300px)

    """)

    let resources = engine.cosmeticResourceDetails(
        for: "https://example.com/article"
    )
    let proceduralActions = try resources.proceduralActions.map(jsonObject)

    let selectorTypes = Set(
        proceduralActions.flatMap { action -> [String] in
            guard let selector = action["selector"] as? [[String: Any]] else {
                return []
            }
            return selector.compactMap { $0["type"] as? String }
        }
    )
    let cssSelectorArgs = Set(
        proceduralActions.flatMap { action -> [String] in
            guard let selector = action["selector"] as? [[String: Any]] else {
                return []
            }
            return selector.compactMap { $0["arg"] as? String }
        }
    )
    let actionTypes = Set(
        proceduralActions.compactMap {
            ($0["action"] as? [String: Any])?["type"] as? String
        }
    )

    #expect(resources.proceduralActions.count == 3)
    #expect(selectorTypes.contains("css-selector"))
    #expect(selectorTypes.contains("has-text"))
    #expect(selectorTypes.contains("matches-css"))
    #expect(cssSelectorArgs.contains("div:has(.ad)"))
    #expect(actionTypes.contains("remove"))
}

@Test func defaultScriptletResourcesPrepareParameterizedInjectionCode() {
    let engine = AdblockEngine(filterSet: """
    example.com##+js(abort-current-inline-script, document.createElement, adsbygoogle)
    example.com##+js(set-constant, navigator.webdriver, false)

    """)
    engine.useDefaultResources()

    let resources = engine.cosmeticResourceDetails(
        for: "https://example.com/article"
    )

    #expect(resources.injectedScript.isEmpty == false)
    #expect(resources.injectedScript.contains("document.createElement"))
    #expect(resources.injectedScript.contains("adsbygoogle"))
    #expect(resources.injectedScript.contains("navigator.webdriver"))
    let invocations = resources.scriptletInjections
    #expect(invocations.map(\.name).contains("abort-current-script.js"))
    #expect(invocations.contains {
        $0.name == "set-constant.js"
            && $0.args == ["navigator.webdriver", "false"]
    })
}

@Test func frameScopedScriptletRulesExposeFrameOnlyInvocation() {
    let engine = AdblockEngine(filterSet: """
    example.com>>##+js(set, frameSentinel, undefined)

    """)
    engine.useDefaultResources()

    let topResources = engine.cosmeticResourceDetails(
        for: "https://example.com/page.html",
        isTopFrame: true
    )
    let frameResources = engine.cosmeticResourceDetails(
        for: "https://example.com/frame.html",
        isTopFrame: false
    )

    #expect(topResources.injectedScript.contains("frameSentinel") == false)
    #expect(topResources.scriptletInjections.isEmpty)
    #expect(frameResources.injectedScript.contains("frameSentinel"))
    #expect(frameResources.scriptletInjections.contains {
        $0.name == "set-constant.js"
            && $0.args == ["frameSentinel", "undefined"]
    })

    let reloadedEngine = AdblockEngine(serializedData: engine.serializedData())
    reloadedEngine.useDefaultResources()
    let reloadedFrameResources = reloadedEngine.cosmeticResourceDetails(
        for: "https://example.com/frame.html",
        isTopFrame: false
    )
    #expect(reloadedFrameResources.injectedScript.contains("frameSentinel"))
}

@Test func youtubeRulesExposeStructuredScriptletInvocations() {
    let engine = AdblockEngine(filterSet: youtubeScriptletRules)
    engine.useDefaultResources()

    let resources = engine.cosmeticResourceDetails(
        for: "https://www.youtube.com/watch?v=ApXoWvfEYVU"
    )
    let names = Set(resources.scriptletInjections.map(\.name))

    #expect(resources.injectedScript.isEmpty == false)
    #expect(names.contains("trusted-replace-fetch-response.js"))
    #expect(names.contains("trusted-replace-xhr-response.js"))
    #expect(names.contains("set-constant.js"))
    #expect(names.contains("json-prune-fetch-response.js"))
    #expect(names.contains("json-prune.js"))
    #expect(resources.scriptletInjections.contains {
        $0.name == "trusted-replace-fetch-response.js"
            && $0.args.contains(#""adPlacements""#)
            && $0.args.contains("player?")
    })
    #expect(resources.scriptletInjections.contains {
        $0.name == "set-constant.js"
            && $0.args == [
                "ytInitialPlayerResponse.adPlacements",
                "undefined",
            ]
    })
}

@Test func webExtensionScriptletInjectionUsesEarliestMainWorldPath() throws {
    let root = repositoryRootURL()
    let background = try String(
        contentsOf: root.appendingPathComponent(
            "WebShieldAdvanced/Resources/background.js"
        ),
        encoding: .utf8
    )

    #expect(background.contains("browser.scripting.executeScript"))
    #expect(background.contains(#"world: "MAIN""#))
    #expect(background.contains("injectImmediately: true"))
    #expect(background.contains("frameIds"))

    let manifestData = try Data(
        contentsOf: root.appendingPathComponent(
            "WebShieldAdvanced/Resources/manifest.json"
        )
    )
    let manifest = try #require(
        JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )
    let contentScripts = try #require(
        manifest["content_scripts"] as? [[String: Any]]
    )
    let firstContentScript = try #require(contentScripts.first)
    let scripts = try #require(firstContentScript["js"] as? [String])

    #expect(firstContentScript["run_at"] as? String == "document_start")
    #expect(firstContentScript["all_frames"] as? Bool == true)
    #expect(Array(scripts.prefix(2)) == [
        "procedural_filters.js",
        "content_cosmetic.js",
    ])
}

@Test func webExtensionScriptletInjectionUsesEngineAssembledBundle() throws {
    let root = repositoryRootURL()
    let background = try String(
        contentsOf: root.appendingPathComponent(
            "WebShieldAdvanced/Resources/background.js"
        ),
        encoding: .utf8
    )
    let contentScript = try String(
        contentsOf: root.appendingPathComponent(
            "WebShieldAdvanced/Resources/content_cosmetic.js"
        ),
        encoding: .utf8
    )
    let runnerURL = root.appendingPathComponent(
        "WebShieldAdvanced/Resources/scriptlet_runner.js"
    )

    #expect(FileManager.default.fileExists(atPath: runnerURL.path) == false)
    #expect(background.contains("__webshieldRunScriptlet"))
    #expect(background.contains("window.eval"))
    #expect(background.contains("scriptlet_runner") == false)
    #expect(background.contains("injectScriptlets") == false)

    let injectedFunction = try sourceSection(
        background,
        from: "function __webshieldRunScriptlet",
        to: "function injectionResult"
    )
    let contentMessage = try sourceSection(
        contentScript,
        from: #"type: "injectScriptlet""#,
        to: "}).then"
    )
    #expect(background.contains("__webshieldCheckScriptletOrigin") == false)
    #expect(injectedFunction.contains("globalThis.__webshieldScriptletGlobals"))
    #expect(injectedFunction.contains("${code}"))
    #expect(injectedFunction.contains("set-constant.js") == false)
    #expect(injectedFunction.contains("json-prune-fetch-response.js") == false)
    #expect(contentScript.contains(#"type: "injectScriptlet""#))
    #expect(contentScript.contains("payload: { code, url: state.url }"))
    #expect(contentScript.contains("scriptletInjections") == false)
    #expect(contentScript.contains("isTopFrame: state.isTopFrame"))
    #expect(contentMessage.contains("invocations") == false)
}

@Test func cspRulesAreAvailableAtRuntimeButUnsupportedBySafariConversion() {
    let rules = "||example.com^$csp=script-src 'none'\n"
    let engine = AdblockEngine(filterSet: rules)

    let result = engine.checkNetworkRequest(
        url: "https://example.com/article",
        sourceURL: "https://example.com/",
        requestType: "document"
    )
    let conversion = contentBlockerRules(fromFilterSet: rules)

    #expect(result.cspDirectives == "script-src 'none'")
    #expect(conversion.unsupportedRulesCount == 1)
}

@Test func redirectAndRemoveparamRulesAreRuntimeOnlyForNow() {
    let rules = """
    ||ads.example.com/script.js$script,redirect=empty
    ||example.com^$removeparam=utm_source

    """
    let engine = AdblockEngine(filterSet: rules)
    engine.useDefaultResources()

    let redirect = engine.checkNetworkRequest(
        url: "https://ads.example.com/script.js",
        sourceURL: "https://publisher.example/",
        requestType: "script"
    )
    let rewritten = engine.checkNetworkRequest(
        url: "https://example.com/page?utm_source=newsletter&keep=1",
        sourceURL: "https://example.com/",
        requestType: "document"
    )
    let conversion = contentBlockerRules(fromFilterSet: rules)

    #expect(redirect.matched)
    #expect(redirect.redirect != nil)
    #expect(rewritten.matched == false)
    #expect(rewritten.rewrittenURL == "https://example.com/page?keep=1")
    #expect(conversion.unsupportedRulesCount == 2)
}

@Test func unsupportedNetworkModifiersDoNotProduceRuntimeActions() {
    let engine = AdblockEngine(filterSet: """
    ||tracker.example^$removeheader=Set-Cookie
    ||example.com^$inline-script
    ||example.com^$inline-font

    """)

    let result = engine.checkNetworkRequest(
        url: "https://tracker.example/pixel.js",
        sourceURL: "https://example.com/",
        requestType: "script"
    )

    #expect(result.matched == false)
    #expect(result.redirect == nil)
    #expect(result.rewrittenURL == nil)
    #expect(result.cspDirectives == nil)
}

private func jsonObject(from string: String) throws -> [String: Any] {
    let data = try #require(string.data(using: .utf8))
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
}

private func repositoryRootURL(filePath: String = #filePath) -> URL {
    var url = URL(fileURLWithPath: filePath)
    for _ in 0..<5 {
        url.deleteLastPathComponent()
    }
    return url
}

private func sourceSection(_ source: String, from startMarker: String, to endMarker: String) throws -> String {
    let start = try #require(source.range(of: startMarker)?.lowerBound)
    let end = try #require(source[start...].range(of: endMarker)?.lowerBound)
    return String(source[start..<end])
}

private let youtubeScriptletRules = #"""
*_ad_$media,domain=youtube.com,3p
! @@||youtube.com/get_video_info?*timedtext_editor$xhr,1p
tv.youtube.com##+js(trusted-replace-xhr-response, '"adPlacements"', '"no_ads"', /playlist\?list=|\/player(?:\?.+)?$|watch\?[tv]=/)
!#if !cap_html_filtering
www.youtube.com##+js(trusted-replace-xhr-response, /"adPlacements.*?([A-Z]"\}|"\}{2\,4})\}\]\,/, , /playlist\?list=|\/player(?:\?.+)?$|watch\?[tv]=/)
www.youtube.com##+js(trusted-replace-xhr-response, /"adPlacements.*?("adSlots"|"adBreakHeartbeatParams")/gms, $1, /\/player(?:\?.+)?$/)
www.youtube.com##+js(trusted-replace-fetch-response, '"adPlacements"', '"no_ads"', player?)
www.youtube.com##+js(trusted-replace-fetch-response, '"adSlots"', '"no_ads"', player?)
!#else
||www.youtube.com/playlist?list=$xhr,1p,replace=/"adPlacements"/"no_ads"/
||www.youtube.com/playlist?list=$xhr,1p,replace=/"adSlots"/"no_ads"/
||www.youtube.com/watch?$xhr,1p,replace=/"adPlacements"/"no_ads"/
||www.youtube.com/watch?$xhr,1p,replace=/"adSlots"/"no_ads"/
||www.youtube.com/youtubei/v1/player?$xhr,1p,replace=/"adPlacements"/"no_ads"/
||www.youtube.com/youtubei/v1/player?$xhr,1p,replace=/"adSlots"/"no_ads"/
!#endif
m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(set, ytInitialPlayerResponse.playerAds, undefined)
m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(set, ytInitialPlayerResponse.adPlacements, undefined)
m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(set, ytInitialPlayerResponse.adSlots, undefined)
m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(set, playerResponse.adPlacements, undefined)
m.youtube.com,music.youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune, playerResponse.adPlacements playerResponse.playerAds playerResponse.adSlots adPlacements playerAds adSlots important)
youtube.com##.ytlr-horizontal-list-renderer__items > .yt-virtual-list__container > .yt-virtual-list__item--visible.yt-virtual-list__item--selected.yt-virtual-list__item:has-text(Ad)
m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune-fetch-response, reelWatchSequenceResponse.entries.[-].command.reelWatchEndpoint.adClientParams.isAd entries.[-].command.reelWatchEndpoint.adClientParams.isAd, , propsToMatch, url:/reel_watch_sequence?)
m.youtube.com,music.youtube.com,tv.youtube.com,www.youtube.com,youtubekids.com,youtube-nocookie.com##+js(json-prune, entries.[-].command.reelWatchEndpoint.adClientParams.isAd)
||youtube.com/youtubei/v1/get_watch?$xhr,1p,replace=/"adPlacements"/"no_ads"/
||youtube.com/youtubei/v1/get_watch?$xhr,1p,replace=/"adSlots"/"no_ads"/
||youtube.com/get_video$media,redirect=noopmp4-1s,domain=games2rule.com
*$frame,denyallow=facebook.com|google.com|youtube.com,domain=foxseotools.com
*$frame,denyallow=cloudflare.com|facebook.com|google.com|hcaptcha.com|youtube.com|jungleofferwall.com,domain=dutchycorp.*
*$script,3p,denyallow=cloudflare.net|fastly.net|google.com|googleapis.com|gstatic.com|jwpcdn.com|jsdelivr.net|eastream.net|youtube.com|ytimg.com,domain=vidfast.co
*$frame,denyallow=cloudflare.com|facebook.com|google.com|hcaptcha.com|youtube.com,domain=fc.lc|fc-lc.com
||goodnewsnetwork.org^$csp=script-src 'self' 'unsafe-inline' 'unsafe-eval' *.googletagservices.com *.wp.com *.air.tv *.addthis.com *.cloudflare.com *.facebook.net *.facebook.com *.gstatic.com *.youtube.com *.ytimg.com *.google.com *.googletagmanager.com *.instagram.com
||youtube.com/embed/*$domain=1shortlink.com
"""#
