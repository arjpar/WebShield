import SwiftUI

extension Color {
    public static var sectionBackground: Color {
        #if os(macOS)
            Color(.controlBackgroundColor)
        #elseif os(iOS) || os(visionOS)
            Color(.secondarySystemGroupedBackground)
        #endif
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    header

                    VStack(alignment: .leading, spacing: 28) {
                        helpSection(
                            icon: "book.closed",
                            title: "Documentation",
                            content: "Learn about all features in our comprehensive documentation.",
                            link: (text: "Visit Wiki", url: URL(string: "https://github.com/arjpar/WebShield/wiki")!)
                        )

                        helpSection(
                            icon: "heart.fill",
                            title: "Support Development",
                            content:
                                "WebShield is and always will be free, with all core features available to everyone. As a self-funded project I maintain out-of-pocket, it stays independent from ad companies and their 'acceptable ads' programs. However, this model isn't sustainable long-term. Without community support, I'll eventually face the difficult choice between ending development rather than selling out to ad companies or implementing a paywall. Any contribution helps maintain WebShield's mission of providing free, uncompromised content filtering for everyone. If you find value in keeping the web clean and private, consider supporting WebShield's development:",
                            links: [
                                (
                                    text: "Ko-fi",
                                    url: URL(string: "https://ko-fi.com/imarjuna")!
                                ),
                                (
                                    text: "Buy Me a Coffee",
                                    url: URL(string: "https://buymeacoffee.com/imarjuna")!
                                ),
                                (
                                    text: "GitHub Sponsors",
                                    url: URL(string: "https://github.com/sponsors/arjpar")!
                                ),
                                (
                                    text: "Liberapay",
                                    url: URL(string: "https://liberapay.com/imarjuna/")!
                                ),
                            ]
                        )

                        helpSection(
                            icon: "questionmark.bubble",
                            title: "Questions & Support",
                            content: "Get help from our community through these channels:",
                            links: [
                                (
                                    text: "GitHub Discussions",
                                    url: URL(string: "https://github.com/arjpar/WebShield/discussions")!
                                ),
                                (text: "Discord Server", url: URL(string: "https://discord.gg/gQ4ygPKyur")!),
                            ]
                        )

                        helpSection(
                            icon: "ant",
                            title: "Report Issues",
                            content: "Report specific problems to the appropriate channels:",
                            links: [
                                (
                                    text: "Website Issues",
                                    url: URL(string: "https://github.com/AdguardTeam/AdguardFilters/issues")!
                                ),
                                (
                                    text: "Bug Reports",
                                    url: URL(string: "https://github.com/arjpar/WebShield/issues")!
                                ),
                                (text: "FAQ", url: URL(string: "https://github.com/arjpar/WebShield/wiki/FAQ")!),
                            ]
                        )

                        importantTipsSection
                    }
                    .padding(.horizontal)
                }
                .padding()
            }
            .navigationTitle("Help & Support")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(idealWidth: 520, idealHeight: 600)
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.blue)
                .symbolEffect(.pulse)

            Text("Help Resources")
                .font(.title2.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
    }

    private var importantTipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Important Tips", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("• Avoid using multiple non-WebShield ad blockers simultaneously")
                Text("• Keep your filter lists updated regularly")
                Text("• Use the built-in logger to diagnose issues")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        }
    }

    private func helpSection(icon: String, title: String, content: String, link: (text: String, url: URL)) -> some View
    {
        helpSection(icon: icon, title: title, content: content, links: [link])
    }

    private func helpSection(icon: String, title: String, content: String, links: [(text: String, url: URL)])
        -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(.primary)

            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(links, id: \.text) { link in
                    Button(action: { openURL(link.url) }) {
                        HStack {
                            Text(link.text)
                                .font(.subheadline)

                            Image(systemName: "arrow.up.forward.app")
                                .font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(Color.sectionBackground))
        }
    }
}
