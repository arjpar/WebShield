import Foundation
import adblock_ffi

public struct ContentBlockerConversionResult: Sendable {
    public let json: String
    public let truncated: Bool
    public let unsupportedRulesCount: UInt64

    public init(
        json: String,
        truncated: Bool,
        unsupportedRulesCount: UInt64 = 0
    ) {
        self.json = json
        self.truncated = truncated
        self.unsupportedRulesCount = unsupportedRulesCount
    }
}

public struct CosmeticResources: Codable, Sendable {
    public struct ScriptletInvocation: Codable, Sendable {
        public let name: String
        public let args: [String]

        public init(name: String, args: [String] = []) {
            self.name = name
            self.args = args
        }
    }

    public let hideSelectors: [String]
    public let proceduralActions: [String]
    public let exceptions: [String]
    public let injectedScript: String
    public let scriptletInjections: [ScriptletInvocation]
    public let generichide: Bool

    public init(
        hideSelectors: [String] = [],
        proceduralActions: [String] = [],
        exceptions: [String] = [],
        injectedScript: String = "",
        scriptletInjections: [ScriptletInvocation] = [],
        generichide: Bool = false
    ) {
        self.hideSelectors = hideSelectors
        self.proceduralActions = proceduralActions
        self.exceptions = exceptions
        self.injectedScript = injectedScript
        self.scriptletInjections = scriptletInjections
        self.generichide = generichide
    }

    private enum CodingKeys: String, CodingKey {
        case hideSelectors = "hide_selectors"
        case proceduralActions = "procedural_actions"
        case exceptions
        case injectedScript = "injected_script"
        case scriptletInjections = "scriptlet_injections"
        case generichide
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hideSelectors = try container.decodeIfPresent(
            [String].self,
            forKey: .hideSelectors
        ) ?? []
        self.proceduralActions = try container.decodeIfPresent(
            [String].self,
            forKey: .proceduralActions
        ) ?? []
        self.exceptions = try container.decodeIfPresent(
            [String].self,
            forKey: .exceptions
        ) ?? []
        self.injectedScript = try container.decodeIfPresent(
            String.self,
            forKey: .injectedScript
        ) ?? ""
        self.scriptletInjections = try container.decodeIfPresent(
            [ScriptletInvocation].self,
            forKey: .scriptletInjections
        ) ?? []
        self.generichide = try container.decodeIfPresent(
            Bool.self,
            forKey: .generichide
        ) ?? false
    }
}

public struct NetworkRequestResult: Sendable {
    public let matched: Bool
    public let important: Bool
    public let redirect: String?
    public let rewrittenURL: String?
    public let exception: String?
    public let filter: String?
    public let cspDirectives: String?

    public init(
        matched: Bool,
        important: Bool,
        redirect: String? = nil,
        rewrittenURL: String? = nil,
        exception: String? = nil,
        filter: String? = nil,
        cspDirectives: String? = nil
    ) {
        self.matched = matched
        self.important = important
        self.redirect = redirect
        self.rewrittenURL = rewrittenURL
        self.exception = exception
        self.filter = filter
        self.cspDirectives = cspDirectives
    }
}

public final class AdblockEngine: @unchecked Sendable {
    public static let defaultContentBlockerRuleLimit = 150_000

    private let engine: ABAdblockEngine

    public init(filterSet: String) {
        self.engine = ABAdblockEngine(filterSet: filterSet)
    }

    public init(serializedData: Data) {
        self.engine = ABAdblockEngine(serializedData: serializedData)
    }

    public static func contentBlockerRules(
        fromFilterSet filterSet: String,
        ruleLimit: Int = AdblockEngine.defaultContentBlockerRuleLimit
    ) -> ContentBlockerConversionResult {
        let sanitizedLimit = max(1, ruleLimit)
        let result = ABAdblockEngine.contentBlockerRules(
            fromFilterSet: filterSet,
            ruleLimit: UInt(sanitizedLimit)
        )
        return ContentBlockerConversionResult(
            json: result.json,
            truncated: result.isTruncated,
            unsupportedRulesCount: result.unsupportedRulesCount
        )
    }

    public static func defaultResourcesJSON() -> String {
        ABAdblockEngine.defaultResourcesJSON()
    }

    public func serializedData() -> Data {
        engine.serializedData()
    }

    public func useResources(json: String) {
        engine.useResources(json: json)
    }

    public func useDefaultResources() {
        useResources(json: Self.defaultResourcesJSON())
    }

    public func cosmeticResources(
        for url: String,
        isTopFrame: Bool = true
    ) -> String {
        engine.cosmeticResources(for: url, topFrame: isTopFrame)
    }

    public func checkNetworkRequest(
        url: String,
        sourceURL: String,
        requestType: String
    ) -> NetworkRequestResult {
        let result = engine.checkNetworkRequest(
            url: url,
            sourceURL: sourceURL,
            requestType: requestType
        )

        func nilIfEmpty(_ value: String) -> String? {
            value.isEmpty ? nil : value
        }

        return NetworkRequestResult(
            matched: result.matched,
            important: result.important,
            redirect: nilIfEmpty(result.redirect),
            rewrittenURL: nilIfEmpty(result.rewrittenURL),
            exception: nilIfEmpty(result.exception),
            filter: nilIfEmpty(result.filter),
            cspDirectives: nilIfEmpty(result.cspDirectives)
        )
    }

    public func cosmeticResourceDetails(
        for url: String,
        isTopFrame: Bool = true
    ) -> CosmeticResources {
        guard
            let data = cosmeticResources(
                for: url,
                isTopFrame: isTopFrame
            ).data(using: .utf8),
            let resources = try? JSONDecoder().decode(
                CosmeticResources.self,
                from: data
            )
        else {
            return CosmeticResources()
        }

        return resources
    }

    public func stylesheetForCosmeticRules(
        classes: [String],
        ids: [String],
        exceptionsJSON: String = "[]"
    ) -> String {
        engine.stylesheetForCosmeticRules(
            classes: classes,
            ids: ids,
            exceptionsJSON: exceptionsJSON
        )
    }

    public func selectorsForCosmeticRules(
        classes: [String],
        ids: [String],
        exceptionsJSON: String = "[]"
    ) -> [String] {
        engine.selectorsForCosmeticRules(
            classes: classes,
            ids: ids,
            exceptionsJSON: exceptionsJSON
        )
    }

    public func selectorsForCosmeticRules(
        classes: [String],
        ids: [String],
        resources: CosmeticResources
    ) -> [String] {
        let exceptionsData = (try? JSONEncoder().encode(resources.exceptions))
            ?? Data("[]".utf8)
        let exceptionsJSON = String(data: exceptionsData, encoding: .utf8) ?? "[]"

        return selectorsForCosmeticRules(
            classes: classes,
            ids: ids,
            exceptionsJSON: exceptionsJSON
        )
    }

    public func stylesheetForCosmeticRules(
        classes: [String],
        ids: [String],
        resources: CosmeticResources
    ) -> String {
        let exceptionsData = (try? JSONEncoder().encode(resources.exceptions))
            ?? Data("[]".utf8)
        let exceptionsJSON = String(data: exceptionsData, encoding: .utf8) ?? "[]"

        return stylesheetForCosmeticRules(
            classes: classes,
            ids: ids,
            exceptionsJSON: exceptionsJSON
        )
    }
}

public func contentBlockerRules(
    fromFilterSet filterSet: String,
    ruleLimit: Int = AdblockEngine.defaultContentBlockerRuleLimit
) -> ContentBlockerConversionResult {
    AdblockEngine.contentBlockerRules(
        fromFilterSet: filterSet,
        ruleLimit: ruleLimit
    )
}
