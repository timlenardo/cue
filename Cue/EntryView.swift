import SwiftUI

struct EntryView: View {
    @Environment(AppState.self) private var state
    @Environment(CueAPI.self) private var api

    @State private var url: String = ""
    @State private var showOrbDebug = false
    @FocusState private var urlFieldFocused: Bool

    private func detectPlatform(_ raw: String) -> String? {
        let u = raw.lowercased()
        if u.contains("spotify") { return "Spotify" }
        if u.contains("podcasts.apple") || u.contains("apple.com") { return "Apple Podcasts" }
        if u.hasPrefix("http") || u.contains("://") { return "RSS / Link" }
        return nil
    }

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
                Button { showOrbDebug = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(palette.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(palette.subtle))
                }
                .buttonStyle(.plain)
                Button { state.settingsOpen = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(palette.ink)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(palette.subtle))
                }
                .buttonStyle(.plain)
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
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    pasteCard
                    Text("Orbit resolves the link, transcribes the audio with Whisper, then plays it back. Today: Spotify, Apple Podcasts, RSS.")
                        .font(Fonts.sans(11))
                        .lineSpacing(3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(palette.inkFade)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, state.bottomDockHeight + 24)
            }
        }
        .padding(.top, Geo.statusBarReserve)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.bg.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture { urlFieldFocused = false }
        .sheet(isPresented: $showOrbDebug) {
            LiquidOrbDebugView()
        }
    }

    // MARK: - Paste card

    private var isLoading: Bool {
        switch state.loadPhase {
        case .resolving, .transcribing: return true
        case .idle, .error: return false
        }
    }

    @ViewBuilder
    private var pasteCard: some View {
        let palette = state.palette
        let platform = detectPlatform(url)
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        let canListen = !trimmed.isEmpty && !isLoading

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.bg)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(palette.ink))
                Text("PASTE A LINK")
                    .font(Fonts.sans(10.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(palette.inkMuted)
                Spacer()
            }
            .padding(.bottom, 8)

            Text("Listen to anything, instantly.")
                .font(Fonts.sans(17, weight: .semibold))
                .tracking(-0.2)
                .lineSpacing(3)
                .foregroundStyle(palette.ink)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if let platform {
                        Text(platform.uppercased())
                            .font(Fonts.sans(10.5, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(palette.accentSoft))
                    }
                    TextField(text: $url) {
                        Text("Paste a Spotify, Apple, or RSS link")
                            .foregroundStyle(palette.inkMuted)
                    }
                    .font(Fonts.sans(14))
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
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.inkMuted)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(palette.cardEdge, lineWidth: 0.5)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture {
                    guard !isLoading else { return }
                    urlFieldFocused = true
                }

                HStack {
                    Text("Spotify · Apple Podcasts · RSS")
                        .font(Fonts.sans(11))
                        .foregroundStyle(palette.inkMuted)
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if isLoading {
                                ProgressView()
                                    .tint(palette.bg)
                                    .scaleEffect(0.8)
                            }
                            Text(submitLabel)
                                .font(Fonts.sans(13, weight: .semibold))
                            if !isLoading {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .foregroundStyle(canListen || isLoading ? palette.bg : palette.inkMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(canListen || isLoading ? palette.ink : palette.subtleStrong))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canListen)
                }
            }
            .padding(.top, 10)

            if case .error(let msg) = state.loadPhase {
                Text(msg)
                    .font(Fonts.sans(12))
                    .foregroundStyle(.red)
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(palette.cardEdge, lineWidth: 0.5)
                )
        )
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
            state.loadPhase = .transcribing(stage: "downloading", progress: nil, chunkCount: nil)
            let transcribeStart = Date()
            Analytics.shared.track(
                "podcast_transcribe_started",
                properties: ["audio_duration_s": episode.durationSeconds]
            )

            var chunkCount: Int? = nil
            var transcript: TranscribeResponse? = nil
            let stream = api.transcribePodcastStream(
                audioUrl: episode.audioUrl,
                durationSeconds: episode.durationSeconds
            )
            for try await event in stream {
                switch event {
                case .status(let stage, let n, _, _):
                    if let n { chunkCount = n }
                    state.loadPhase = .transcribing(stage: stage, progress: nil, chunkCount: chunkCount)
                case .chunkDone(let idx, let n):
                    chunkCount = n
                    let done = Double(idx + 1)
                    let progress = done / Double(max(1, n))
                    state.loadPhase = .transcribing(stage: "transcribing", progress: progress, chunkCount: n)
                case .heartbeat:
                    break
                case .result(let r):
                    transcript = r
                case .error(let msg):
                    throw CueAPIError.server(status: 0, message: msg)
                }
            }

            guard let transcript else {
                throw CueAPIError.server(status: 0, message: "Transcription ended without a result.")
            }

            Analytics.shared.track(
                "podcast_transcribe_completed",
                properties: [
                    "ok": true,
                    "ms": Int(Date().timeIntervalSince(transcribeStart) * 1000),
                    "cached": transcript.cached,
                    "segment_count": transcript.segments.count,
                ]
            )

            // Add to library so the user can return without re-pasting. We do
            // this before loadLive so the player carries a serverEpisodeId and
            // can sync progress on the first tick.
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
                // Library save failing shouldn't block listening; we just won't
                // sync progress for this session.
                print("[Cue] library upsert failed: \(error)")
            }

            state.loadPhase = .idle
            state.loadLive(
                LiveEpisode(
                    show: resolved.show,
                    episode: episode,
                    transcript: transcript,
                    serverEpisodeId: serverEpisodeId
                )
            )
            // Refresh library so the just-added episode is in the list.
            await state.reloadLibrary()
        } catch {
            // Generic catch — covers resolve, transcribe, and unexpected
            // failures. We don't try to attribute the stage; the loadPhase
            // at the moment of throw tells us downstream.
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
