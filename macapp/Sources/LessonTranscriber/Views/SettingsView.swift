import SwiftUI
import LessonKit

/// Settings — teachers configure nothing; the only preference is how detailed
/// the AI summary should be (horizontal segmented control, Hex-style rows).
/// Google sign-in / sign-out lives here too.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var auth: GoogleAuthStore
    @EnvironmentObject var updater: AppUpdater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.largeTitle.bold())
                    Divider().padding(.top, 4)
                }
                .padding(.top, 8)
                .padding(.bottom, 8)

                SectionLabel("AI Summary")
                RowCard {
                    SettingRow(
                        title: "Summary length",
                        subtitle: settings.summaryLength.blurb,
                        showsDivider: false)
                    {
                        HexSegmentedPicker(
                            selection: $settings.summaryLength,
                            options: SummaryLength.allCases,
                            label: \.label)
                            .frame(width: 300)
                    }
                }

                SectionLabel("Google Account")
                RowCard {
                    SettingRow(
                        title: auth.isSignedIn ? (auth.email ?? "Signed in") : "Not signed in",
                        subtitle: auth.isSignedIn
                            ? "AI summaries and quiz forms are unlocked for this account."
                            : "AI summaries and quiz forms unlock after a one-time Google sign-in — you stay signed in until you log out.",
                        showsDivider: auth.lastError?.isEmpty == false)
                    {
                        HStack(spacing: 10) {
                            if auth.busy {
                                ProgressView().controlSize(.small)
                            }
                            if auth.isSignedIn {
                                Button("Log Out", role: .destructive) { auth.signOut() }
                                    .buttonStyle(HexButtonStyle())
                                    .disabled(auth.busy)
                            } else {
                                Button("Log In with Google…") {
                                    Task { try? await auth.signIn() }
                                }
                                .buttonStyle(HexPrimaryButtonStyle())
                                .disabled(auth.busy)
                            }
                        }
                    }

                    if let error = auth.lastError, !error.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                            Spacer()
                            // Second chance for a closed browser tab or a
                            // dismissed consent page.
                            Button("Try Again") {
                                Task { try? await auth.signIn() }
                            }
                            .buttonStyle(HexButtonStyle())
                            .disabled(auth.busy)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }

                SectionLabel("Updates")
                RowCard {
                    SettingRow(
                        title: updateTitle,
                        subtitle: updateSubtitle,
                        showsDivider: true)
                    {
                        updateControl
                    }

                    if case .available(let release) = updater.phase {
                        VStack(alignment: .leading, spacing: 8) {
                            MarkdownText(markdown: release.notes.isEmpty ? "No release notes." : release.notes)
                            Link("View on GitHub…", destination: release.pageURL)
                                .font(.footnote)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        Divider()
                    }

                    if case .failed(let message) = updater.phase {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        Divider()
                    }

                    SettingRow(
                        title: "Check automatically",
                        subtitle: "Look for a new release at launch and every 12 hours.",
                        showsDivider: false)
                    {
                        Toggle("", isOn: $updater.autoCheck)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background { Color.hexBackground.ignoresSafeArea() }
    }
}

extension SettingsView {
    /// Title of the version row: the running version, or the new one.
    private var updateTitle: String {
        if let version = updater.updateVersion {
            return "Version \(version) available"
        }
        return "Version \(updater.currentVersion)"
    }

    private var updateSubtitle: String {
        switch updater.phase {
        case .idle:
            return "Checks GitHub at launch and every 12 hours; install with one click."
        case .checking:
            return "Checking github.com for a new release…"
        case .upToDate:
            return "You're running the latest version."
        case .available(let release):
            return "Download and restart to update (installed: \(updater.currentVersion))."
                + (release.zipURL == nil ? " This release only ships a disk image — grab it from the release page." : "")
        case .downloading(let fraction):
            return "Downloading v\(updater.updateVersion ?? "")… \(Int((fraction * 100).rounded()))%"
        case .readyToInstall(let release):
            return "Downloaded — restart to install version \(release.version)."
        case .failed:
            return "Something went wrong — see below."
        }
    }

    /// Trailing control of the version row, per updater phase.
    @ViewBuilder private var updateControl: some View {
        switch updater.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.footnote).foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: fraction)
                    .frame(width: 140)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .available(let release):
            if release.zipURL != nil {
                Button("Download & Install") {
                    Task { await updater.downloadUpdate() }
                }
                .buttonStyle(HexPrimaryButtonStyle())
            } else {
                Button("Open Release Page…") {
                    updater.openReleasesPage()
                }
                .buttonStyle(HexButtonStyle())
            }
        case .readyToInstall:
            Button("Restart to Update") {
                updater.installAndRestart()
            }
            .buttonStyle(HexPrimaryButtonStyle())
        default:
            Button("Check for Updates") {
                Task { await updater.checkForUpdates(manual: true) }
            }
            .buttonStyle(HexButtonStyle())
        }
    }
}
