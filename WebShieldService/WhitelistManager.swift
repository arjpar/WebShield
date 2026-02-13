//
//  WhitelistManager.swift
//  WebShield
//
//  Created by Claude on 2026-01-19.
//

import Foundation

/// WhitelistManager provides functionality for managing whitelisted (trusted) domains
/// where content blocking should be disabled.
///
/// This class stores whitelisted domains in the shared app group container so they can
/// be accessed by both the main app and Safari extensions.
public final class WhitelistManager: @unchecked Sendable {
    /// Shared singleton instance of WhitelistManager.
    public static let shared = WhitelistManager()
    private let logger = WebShieldLogger.shared
    private let logCategory = "Whitelist"

    /// UserDefaults key for storing whitelisted domains
    private static let whitelistedDomainsKey = "whitelistedDomains"

    /// UserDefaults instance using the app group container
    /// Using a stored property instead of computed to ensure consistent access
    /// and proper synchronization across operations
    private let userDefaults: UserDefaults

    /// Private initializer for singleton pattern
    private init() {
        // Initialize UserDefaults once with the app group suite
        // This ensures all operations use the same instance for proper synchronization
        self.userDefaults = UserDefaults(suiteName: GroupIdentifier.shared.value) ?? .standard
    }

    // MARK: - Public API

    /// Returns all whitelisted domains.
    ///
    /// - Returns: Array of domain strings that are whitelisted.
    public var whitelistedDomains: [String] {
        userDefaults.stringArray(forKey: Self.whitelistedDomainsKey) ?? []
    }

    /// Adds a domain to the whitelist.
    ///
    /// - Parameter domain: The domain to whitelist (e.g., "example.com").
    /// - Returns: True if the domain was added, false if it was already whitelisted or invalid.
    @discardableResult
    public func addDomain(_ domain: String) -> Bool {
        let normalized = normalizeDomain(domain)
        guard !normalized.isEmpty else {
            logger.error(
                "WhitelistManager: Cannot add empty domain",
                category: logCategory
            )
            return false
        }

        guard isValidDomain(normalized) else {
            logger.error(
                "WhitelistManager: Invalid domain format: \(normalized)",
                category: logCategory
            )
            return false
        }

        var domains = whitelistedDomains
        guard !domains.contains(normalized) else {
            logger.info(
                "WhitelistManager: Domain already whitelisted: \(normalized)",
                category: logCategory
            )
            return false
        }

        domains.append(normalized)
        userDefaults.set(domains, forKey: Self.whitelistedDomainsKey)
        logger.info(
            "WhitelistManager: Added domain to whitelist: \(normalized)",
            category: logCategory
        )
        return true
    }

    /// Removes a domain from the whitelist.
    ///
    /// - Parameter domain: The domain to remove from the whitelist.
    /// - Returns: True if the domain was removed, false if it wasn't in the whitelist.
    @discardableResult
    public func removeDomain(_ domain: String) -> Bool {
        let normalized = normalizeDomain(domain)
        var domains = whitelistedDomains

        guard let index = domains.firstIndex(of: normalized) else {
            logger.info(
                "WhitelistManager: Domain not in whitelist: \(normalized)",
                category: logCategory
            )
            return false
        }

        domains.remove(at: index)
        userDefaults.set(domains, forKey: Self.whitelistedDomainsKey)
        logger.info(
            "WhitelistManager: Removed domain from whitelist: \(normalized)",
            category: logCategory
        )
        return true
    }

    /// Checks if a domain is whitelisted.
    ///
    /// This method also checks if any parent domain is whitelisted.
    /// For example, if "example.com" is whitelisted, "sub.example.com" will also be considered whitelisted.
    ///
    /// - Parameter domain: The domain to check.
    /// - Returns: True if the domain or any of its parent domains is whitelisted.
    public func isDomainWhitelisted(_ domain: String) -> Bool {
        let normalized = normalizeDomain(domain)
        let domains = whitelistedDomains

        // Check for exact match
        if domains.contains(normalized) {
            return true
        }

        // Check if any whitelisted domain is a parent of this domain
        for whitelistedDomain in domains {
            if normalized == whitelistedDomain ||
                normalized.hasSuffix("." + whitelistedDomain) {
                return true
            }
        }

        return false
    }

    /// Checks if a host is whitelisted (alias for isDomainWhitelisted).
    ///
    /// - Parameter host: The host to check.
    /// - Returns: True if the host or any of its parent domains is whitelisted.
    public func isHostWhitelisted(_ host: String) -> Bool {
        isDomainWhitelisted(host)
    }

    /// Toggles the whitelist status of a domain.
    ///
    /// - Parameter domain: The domain to toggle.
    /// - Returns: True if the domain is now whitelisted, false if it was removed.
    @discardableResult
    public func toggleDomain(_ domain: String) -> Bool {
        let normalized = normalizeDomain(domain)
        if isDomainWhitelisted(normalized) {
            removeDomain(normalized)
            return false
        } else {
            addDomain(normalized)
            return true
        }
    }

    /// Removes all domains from the whitelist.
    public func clearAllDomains() {
        userDefaults.set([String](), forKey: Self.whitelistedDomainsKey)
        logger.info(
            "WhitelistManager: Cleared all whitelisted domains",
            category: logCategory
        )
    }

    /// Sets the entire whitelist to the provided domains, replacing any existing entries.
    ///
    /// - Parameter domains: Array of domains to set as the whitelist.
    public func setDomains(_ domains: [String]) {
        let normalizedDomains = domains.compactMap { domain -> String? in
            let normalized = normalizeDomain(domain)
            return isValidDomain(normalized) ? normalized : nil
        }
        let uniqueDomains = Array(Set(normalizedDomains))
        userDefaults.set(uniqueDomains, forKey: Self.whitelistedDomainsKey)
        logger.info(
            "WhitelistManager: Set \(uniqueDomains.count) whitelisted domains",
            category: logCategory
        )
    }

    // MARK: - Private Helpers

    /// Normalizes a domain string by removing whitespace, converting to lowercase,
    /// and stripping common prefixes.
    ///
    /// - Parameter domain: The domain to normalize.
    /// - Returns: The normalized domain string.
    private func normalizeDomain(_ domain: String) -> String {
        var normalized = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Remove protocol prefixes if present
        if normalized.hasPrefix("https://") {
            normalized = String(normalized.dropFirst(8))
        } else if normalized.hasPrefix("http://") {
            normalized = String(normalized.dropFirst(7))
        }

        // Remove www. prefix
        if normalized.hasPrefix("www.") {
            normalized = String(normalized.dropFirst(4))
        }

        // Remove trailing slashes and paths
        if let slashIndex = normalized.firstIndex(of: "/") {
            normalized = String(normalized[..<slashIndex])
        }

        // Remove port if present
        if let colonIndex = normalized.firstIndex(of: ":") {
            normalized = String(normalized[..<colonIndex])
        }

        return normalized
    }

    /// Validates that a string is a properly formatted domain.
    ///
    /// - Parameter domain: The domain to validate.
    /// - Returns: True if the domain is valid, false otherwise.
    private func isValidDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty else { return false }

        // Basic domain validation regex
        // Matches: example.com, sub.example.com, example.co.uk, etc.
        let domainRegex = #"^(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"#

        return domain.range(of: domainRegex, options: .regularExpression) != nil
    }
}
