import Foundation
import UIKit
import os
import PostHog

private let log = Logger(subsystem: "com.toug.cue", category: "Analytics")

/// Thin wrapper around PostHog for product analytics.
///
/// Best-effort by design: a missing API key, a transient network failure,
/// or a bad property must never crash the calling code. This is the same
/// posture VoiceTelemetry takes for the Langfuse event stream.
///
/// Boundary with Langfuse:
///   - Langfuse owns the deep, per-session trace tree of one voice call.
///   - PostHog owns aggregate product facts across users (DAU, funnels,
///     retention). The two share `trace_id` as a property on voice events
///     so you can pivot from a PostHog row into the Langfuse trace.
///
/// PII rules enforced at call sites (not in this file):
///   - distinct ID is the integer `account.id`, never the phone number.
///   - never send transcripts, note text, or full episode URLs.
final class Analytics {
    static let shared = Analytics()

    private var configured = false
    private(set) var isEnabled = false

    private init() {}

    /// Read the project key from Info.plist and initialize the SDK. Safe to
    /// call multiple times — only the first call configures.
    func configure() {
        guard !configured else { return }
        configured = true

        guard
            let key = Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String,
            !key.isEmpty,
            !key.hasPrefix("$(")
        else {
            log.info("PostHogAPIKey missing from Info.plist; analytics disabled")
            return
        }
        let host = (Bundle.main.object(forInfoDictionaryKey: "PostHogHost") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "https://us.i.posthog.com"

        let config = PostHogConfig(apiKey: key, host: host)
        // Session replay off in v1. The five daily dashboards don't need it
        // and it would add a separate privacy review.
        config.sessionReplay = false
        // Default flush behavior is fine for our event volume (one voice
        // session emits ~10 client events). Don't drop the autocapture
        // setting — we explicitly want only the events we send, not every
        // tap and screen view inferred by PostHog.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false

        PostHogSDK.shared.setup(config)
        isEnabled = true
        log.info("PostHog configured (host=\(host, privacy: .public))")
    }

    /// Alias the anonymous distinct ID to the user's account on sign-in.
    /// Carries forward pre-auth events (app_opened, auth_code_submitted) so
    /// the activation funnel is computable.
    func identify(accountId: Int, traits: [String: Any] = [:]) {
        guard isEnabled else { return }
        var merged = traits
        merged["account_id"] = accountId
        merged["app_version"] =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        merged["ios_version"] = UIDevice.current.systemVersion
        merged["device_model"] = UIDevice.current.model
        PostHogSDK.shared.identify(String(accountId), userProperties: merged)
    }

    /// Clear the distinct ID so the next session starts as a fresh anonymous
    /// user. Called on sign-out.
    func reset() {
        guard isEnabled else { return }
        PostHogSDK.shared.reset()
    }

    /// Fire-and-forget event capture. Properties that are nil are stripped
    /// so we don't ship `null`s that complicate filtering in the UI.
    func track(_ event: String, properties: [String: Any?] = [:]) {
        guard isEnabled else { return }
        var clean: [String: Any] = [:]
        for (k, v) in properties {
            if let v = v { clean[k] = v }
        }
        PostHogSDK.shared.capture(event, properties: clean.isEmpty ? nil : clean)
    }

    /// Extract `url_host` for events that reference an external URL. Never
    /// send the full URL — paths often carry tracking tokens.
    static func urlHost(_ url: String?) -> String? {
        guard let url, let u = URL(string: url), let host = u.host else { return nil }
        return host
    }
}
