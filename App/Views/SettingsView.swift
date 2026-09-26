import AppKit
import SwiftUI
import MilktoastCore

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            PlaybackSettings(model: model)
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            TrackSettings(preferences: model.preferences)
                .tabItem { Label("Tracks", systemImage: "square.stack.3d.up") }
            OutputSettings(model: model)
                .tabItem { Label("Output", systemImage: "internaldrive") }
        }
        .frame(width: 430)
    }
}

private struct PlaybackSettings: View {
    let model: AppModel
    @State private var customPlayerName: String?

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            Picker("When a movie is ready:", selection: playerSelection) {
                Text("Open it in QuickTime Player").tag("quicktime")
                Text("Open it in the default player").tag("default")
                Text(customLabel).tag("custom")
                Text("Just prepare it — I'll open it myself").tag("none")
            }
            .pickerStyle(.radioGroup)

            if case .custom = preferences.player {
                Button("Choose Application…") { chooseApplication() }
                    .controlSize(.small)
            }

            Divider()

            Toggle("Quit Milktoast once playback starts", isOn: binding(\.quitAfterHandoff))
                .disabled(!preferences.player.opensAPlayer)
            Text("Milktoast's work is finished the moment the movie opens. Leaving it running only adds a second Dock icon. In prepare-only mode the window stays up, since that is where you reach the result.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .padding(.vertical, 4)
    }

    private var customLabel: String {
        if case .custom = preferences.player {
            return "Another app: \(PlayerHandoff.displayName(for: preferences.player))"
        }
        return "Another app…"
    }

    private var playerSelection: Binding<String> {
        Binding(
            get: {
                switch preferences.player {
                case .quickTimePlayer: return "quicktime"
                case .systemDefault: return "default"
                case .prepareOnly: return "none"
                case .custom: return "custom"
                }
            },
            set: { value in
                switch value {
                case "default": preferences.player = .systemDefault
                case "none": preferences.player = .prepareOnly
                case "custom": chooseApplication()
                default: preferences.player = .quickTimePlayer
                }
            }
        )
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.message = "Choose the app that should play prepared movies."
        guard panel.runModal() == .OK,
              let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier
        else { return }
        preferences.player = .custom(bundleIdentifier: identifier)
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 }
        )
    }
}

private struct TrackSettings: View {
    let preferences: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Keep every audio track", isOn: binding(\.includeAllAudioTracks))
                Toggle("Convert text subtitles", isOn: binding(\.includeSubtitles))
                Toggle("Keep chapters", isOn: binding(\.includeChapters))
            } footer: {
                Text("Subtitles become QuickTime timed text. Image-based subtitles (Blu-ray PGS, DVD VobSub) have no .mov equivalent and are always skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio conversion") {
                Toggle("Keep lossless audio lossless (ALAC)", isOn: binding(\.preserveLosslessAudioAsALAC))
                Picker("Surround target:", selection: binding(\.surroundTarget)) {
                    ForEach(RemuxOptions.SurroundTarget.allCases, id: \.self) { target in
                        Text(target.displayName).tag(target)
                    }
                }
                Picker("Stereo bitrate:", selection: binding(\.stereoBitrateKbps)) {
                    ForEach([128, 192, 256, 320], id: \.self) { rate in
                        Text("\(rate) kbps").tag(rate)
                    }
                }
            }

            Section("Video fallback") {
                Toggle("Use hardware encoding when a re-encode is needed", isOn: binding(\.preferHardwareEncoding))
                Picker("Bitrate ceiling:", selection: binding(\.maxVideoBitrateMbps)) {
                    ForEach([8, 12, 20, 40, 80], id: \.self) { rate in
                        Text("\(rate) Mbps").tag(rate)
                    }
                }
                Text("Only used for codecs QuickTime cannot decode at all, such as VP9. HEVC, H.264, AV1, and ProRes are copied untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 }
        )
    }
}

private struct OutputSettings: View {
    let model: AppModel

    private var preferences: Preferences { model.preferences }

    var body: some View {
        Form {
            Section {
                Picker("Save prepared movies:", selection: binding(\.outputLocation)) {
                    Text("Next to the original file").tag(OutputLocation.besideSource)
                    Text("In Milktoast's cache folder").tag(OutputLocation.cache)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text(preferences.outputLocation == .besideSource
                     ? "Episode.mkv gets an Episode.mp4 beside it, ready to open any time — Milktoast never deletes it, and never overwrites a file it did not create. If the folder is read-only, the cache is used instead."
                     : "Prepared movies stay out of your movie folders and can be cleaned up on a budget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Cleanup is only meaningful while the cache is the destination.
            if preferences.outputLocation == .cache {
                Section("Cleanup") {
                    Toggle("Delete prepared movies automatically", isOn: binding(\.automaticCacheCleanup))
                    Picker("Keep at most:", selection: binding(\.cacheSizeGB)) {
                        ForEach([10, 20, 40, 80, 160], id: \.self) { size in
                            Text("\(size) GB").tag(size)
                        }
                    }
                    .disabled(!preferences.automaticCacheCleanup)
                    Picker("Discard after:", selection: binding(\.cacheMaxAgeDays)) {
                        ForEach([1, 3, 7, 14, 30], id: \.self) { days in
                            Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                        }
                    }
                    .disabled(!preferences.automaticCacheCleanup)
                    if !preferences.automaticCacheCleanup {
                        Text("Prepared movies are kept until you empty the cache yourself. Half-written leftovers are still removed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                LabeledContent(
                    preferences.outputLocation == .cache ? "Cache size:" : "Left over from cache mode:",
                    value: model.cacheSizeText
                )
                HStack {
                    Button("Reveal in Finder") { model.revealCache() }
                    Spacer()
                    Button("Empty Cache Now") { model.clearCache() }
                }
            } footer: {
                Text("The cache lives in ~/Library/Caches, is excluded from Time Machine, and may be reclaimed by macOS when the disk fills. Your original files are never touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshCacheSize() }
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 }
        )
    }
}
