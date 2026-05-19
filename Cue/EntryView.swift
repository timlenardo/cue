import SwiftUI

struct EntryView: View {
    @Environment(AppState.self) private var state
    @Environment(CueAPI.self) private var api

    @State private var url: String = ""
    @State private var showOrbDebug = false
    @State private var showWaveformDebug = false
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        let palette = state.palette

        VStack(alignment: .leading, spacing: 0) {
            // Brand row
            HStack(spacing: 10) {
                Text("Orbit")
                    .font(Fonts.serif(28, weight: .medium))
                    .tracking(-0.5)
                    .foregroundStyle(palette.ink)
                Spacer()
                if api.account?.isAdmin == true {
                    Button { showOrbDebug = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(palette.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(palette.subtle))
                    }
                    .buttonStyle(.plain)
                    Button { showWaveformDebug = true } label: {
                        Image(systemName: "waveform")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(palette.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(palette.subtle))
                    }
                    .buttonStyle(.plain)
                }
                if api.account?.isAdmin == true {
                    Button { state.settingsOpen = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(palette.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(palette.subtle))
                    }
                    .buttonStyle(.plain)
                }
                Button { state.profileOpen = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(palette.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(palette.subtle))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)

            // Hero
            VStack(alignment: .leading, spacing: 0) {
                Text("Listen to any podcast.")
                    .foregroundStyle(palette.ink)
                Text("Ask it anything.")
                    .foregroundStyle(palette.inkMuted)
            }
            .font(Fonts.serif(32))
            .tracking(-0.6)
            .lineSpacing(4)
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 16)

            // Main card
            VStack(spacing: 14) {
                pasteCard
                Text("Spotify, Apple Podcasts, and RSS supported.")
                    .font(Fonts.sans(11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.inkFade)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            Spacer(minLength: 0)
        }
        .padding(.top, Geo.statusBarReserve)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { urlFieldFocused = false }
        .sheet(isPresented: $showOrbDebug) {
            LiquidOrbDebugView()
        }
        .sheet(isPresented: $showWaveformDebug) {
            WaveformPlaygroundView()
        }
    }

    // MARK: - Paste card

    private var isLoading: Bool {
        switch state.loadPhase {
        case .resolving: return true
        case .idle, .transcribing, .error: return false
        }
    }

    @ViewBuilder
    private var pasteCard: some View {
        let palette = state.palette
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let canListen = !trimmed.isEmpty && !isLoading
        let inputActive = urlFieldFocused || !url.isEmpty

        // Fixed violet glow — independent of palette so it reads the same on
        // every theme. Keeps the dark container's halo subtle and consistent.
        let glow = Color(red: 0.55, green: 0.52, blue: 0.92)

        VStack(spacing: 10) {
            // Input row
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(palette.inkMuted)

                TextField(text: $url) {
                    Text("Paste a Spotify, Apple, or RSS link")
                        .foregroundStyle(palette.inkMuted)
                }
                .font(Fonts.sans(15))
                .foregroundStyle(palette.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($urlFieldFocused)
                .frame(maxWidth: .infinity)
                .disabled(isLoading)

                if !url.isEmpty {
                    Button {
                        url = ""
                        if case .error = state.loadPhase { state.loadPhase = .idle }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(palette.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(
                                inputActive ? Color.white.opacity(0.18) : Color.clear,
                                lineWidth: 1
                            )
                    )
            )
            // CTA glow on the input until the user has pasted something.
            .shadow(color: glow.opacity(canListen ? 0 : 0.75), radius: 18, x: 0, y: 0)
            .shadow(color: glow.opacity(canListen ? 0 : 0.45), radius: 36, x: 0, y: 4)
            .shadow(color: glow.opacity(canListen ? 0 : 0.20), radius: 64, x: 0, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .onTapGesture {
                guard !isLoading else { return }
                urlFieldFocused = true
            }
            .animation(.easeInOut(duration: 0.25), value: inputActive)
            .animation(.easeInOut(duration: 0.25), value: canListen)

            // Listen button
            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .tint(canListen || isLoading ? .black : palette.inkFade)
                            .scaleEffect(0.85)
                    }
                    Text(submitLabel)
                        .font(Fonts.sans(17, weight: .semibold))
                    if !isLoading {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(canListen || isLoading ? Color.black : palette.inkFade)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(canListen || isLoading ? Color.white : Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canListen)
            // CTA glow on the Listen button once the user has pasted something.
            .shadow(color: glow.opacity(canListen ? 0.32 : 0), radius: 20, x: 0, y: 0)
            .shadow(color: glow.opacity(canListen ? 0.15 : 0), radius: 40, x: 0, y: 6)
            .animation(.easeInOut(duration: 0.25), value: canListen)

            if case .error(let msg) = state.loadPhase {
                Text(msg)
                    .font(Fonts.sans(12))
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
        .shadow(color: glow.opacity(0.15), radius: 36, x: 0, y: 10)
    }

    private var submitLabel: String {
        switch state.loadPhase {
        case .idle: return "Listen"
        case .resolving: return "Finding episode\u{2026}"
        case .transcribing(let stage, let progress, _):
            switch stage {
            case "downloading":   return "Downloading\u{2026}"
            case "probing":       return "Inspecting audio\u{2026}"
            case "splitting":     return "Splitting audio\u{2026}"
            case "stitching":     return "Stitching\u{2026}"
            case "caching":       return "Almost done\u{2026}"
            case "cache_hit":     return "Loading\u{2026}"
            case "transcribing":
                if let progress {
                    return "Transcribing \(Int(progress * 100))%"
                }
                return "Transcribing\u{2026}"
            default:              return "Working\u{2026}"
            }
        case .error: return "Try again"
        }
    }

    // MARK: - Submit pipeline

    private func submit() async {
        let raw = url.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        Analytics.shared.track(
            "library_episode_pasted",
            properties: ["url_host": Analytics.urlHost(raw)]
        )
        let resolveStart = Date()
        state.loadPhase = .resolving
        do {
            let resolved = try await api.resolvePodcast(url: raw)
            Analytics.shared.track(
                "podcast_resolve_completed",
                properties: [
                    "ok": true,
                    "ms": Int(Date().timeIntervalSince(resolveStart) * 1000),
                    "source": resolved.source,
                    "url_host": Analytics.urlHost(raw),
                ]
            )
            guard let episode = resolved.episode else {
                throw CueAPIError.server(status: 0, message: "That link is for a show, not a single episode. Paste an episode link.")
            }

            // Add to library before transcription so playback can carry a
            // serverEpisodeId and sync progress immediately. A later
            // transcription failure should not block listening.
            var serverEpisodeId: Int? = nil
            do {
                let item = try await api.upsertLibrary(
                    episode: episode,
                    show: resolved.show,
                    source: resolved.source
                )
                serverEpisodeId = item.episode.id
                Analytics.shared.track(
                    "library_episode_added",
                    properties: ["episode_id": item.episode.id]
                )
            } catch {
                print("[Cue] library upsert failed: \(error)")
            }

            state.loadPhase = .transcribing(stage: "downloading", progress: nil, chunkCount: nil)
            state.loadLive(
                LiveEpisode(
                    show: resolved.show,
                    episode: episode,
                    transcript: AppState.emptyTranscript(durationSeconds: episode.durationSeconds),
                    serverEpisodeId: serverEpisodeId,
                    transcriptReadyForVoice: false
                )
            )
            state.loadPhase = .idle
            state.startTranscriptIndexing(
                audioUrl: episode.audioUrl,
                durationSeconds: episode.durationSeconds
            )
            await state.reloadLibrary()
        } catch {
            Analytics.shared.track(
                "library_paste_failed",
                properties: [
                    "ms": Int(Date().timeIntervalSince(resolveStart) * 1000),
                    "error_message": error.localizedDescription,
                    "url_host": Analytics.urlHost(raw),
                ]
            )
            state.loadPhase = .error(error.localizedDescription)
        }
    }
}
