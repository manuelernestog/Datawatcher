import SwiftUI
import AppKit
import DatawatcherCore

struct AboutView: View {
    @EnvironmentObject var l10n: LanguageManager

    private static let developerName = "Manuel Ernesto Garcia"
    private static let websiteURL = URL(string: "https://manuelernestog.github.io/")!
    private static let repositoryURL = URL(string: "https://github.com/manuelernestog/Datawatcher")!

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return (short?.isEmpty == false ? short : nil) ?? "1.0.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            appIconView
                .padding(.top, 6)

            VStack(spacing: 4) {
                Text(l10n.text(.appName))
                    .font(.title2.weight(.bold))

                Text("\(l10n.text(.aboutVersionPrefix)) \(appVersion)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())

                Text(l10n.text(.aboutSubtitle))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            VStack(spacing: 0) {
                infoRow(
                    icon: "person.crop.circle",
                    label: l10n.text(.aboutDeveloperLabel),
                    value: Self.developerName
                )

                Divider().opacity(0.5)

                linkRow(
                    icon: "globe",
                    label: l10n.text(.aboutWebsiteLabel),
                    displayText: "manuelernestog.github.io",
                    url: Self.websiteURL
                )

                Divider().opacity(0.5)

                linkRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    label: l10n.text(.aboutRepositoryLabel),
                    displayText: "github.com/manuelernestog/Datawatcher",
                    url: Self.repositoryURL
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
            )

            Text("© 2026 \(Self.developerName)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 390)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var appIconView: some View {
        if let appIcon = NSApp.applicationIconImage, appIcon.isValid {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
        }
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func linkRow(icon: String, label: String, displayText: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)

                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()

                HStack(spacing: 4) {
                    Text(displayText)
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
