import XCTest

/// Investigation harness for the "transcript snaps to the left on initial
/// open, then shifts right when you scroll / playback advances" bug. See
/// the PR description for the user-visible symptom and what's been ruled
/// out so far.
///
/// IMPORTANT — these tests do NOT currently reproduce the bug. The bug is
/// visible on the user's real device (iPhone, see screenshots in the PR)
/// but not on the iPhone 16 Pro / iOS 18.3.1 simulator with any of the
/// repro paths tried so far:
///   - Sample player only (live = nil, 12-sentence sample)
///   - Sample LiveEpisode via real `loadLive` (12 sentences)
///   - 60× inflated sample (~720 sentences ≈ a real podcast)
///   - resumeAt: 0 (top of content, no real scroll on open)
///   - resumeAt: 600 (mid-transcript, real downward scroll on open)
///   - Pre-/post-scroll measurements
///
/// The tests + accessibility identifiers + `UITestFlag` infrastructure are
/// preserved so the next person can pick up where this left off — most
/// likely by running them on the actual reproducing device, or by adding
/// device-side logging from `TranscriptScrollView.body` and reading via
/// Console.app while reproducing manually.
final class TranscriptLayoutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Loads a 60×-inflated sample transcript via the real `loadLive` flow
    /// at a mid-transcript resume position (so the scroll-to-activeIdx
    /// actually has to scroll), scrolls past the active sentence, and
    /// asserts every visible sentence is at minX ≈ 24pt (= LazyVStack's
    /// leading padding).
    ///
    /// Currently passes on simulator. If you can run this against a build
    /// installed on the device that reproduces the bug, the assertion
    /// should fail with minX ≈ 2pt — and the frame-dump attachment will
    /// show the exact offsets for every sentence.
    @MainActor
    func testTranscriptLeftPaddingPreserved() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CueUITestBypassAuth",
            "-CueUITestOpenSampleLive",
        ]
        app.launch()

        let anySentence = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH 'transcriptSentence_'")
        ).firstMatch
        XCTAssertTrue(
            anySentence.waitForExistence(timeout: 5),
            "no transcript sentence appeared"
        )

        attach(app.screenshot(), name: "1-initial-open")
        let initialFrames = readSentenceFrames(app: app)

        // PlayerView's onAppear delays didInitialScroll = true by 0.4s and
        // .onScrollPhaseChange only flips followsActive = false after that.
        // Scrolling before then is effectively ignored.
        sleep(1)

        let scrollView = app.scrollViews["transcriptScroll"]
        XCTAssertTrue(scrollView.exists, "transcript ScrollView not found")
        let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        start.press(forDuration: 0.2, thenDragTo: end)
        sleep(1)
        start.press(forDuration: 0.2, thenDragTo: end)
        sleep(1)

        attach(app.screenshot(), name: "2-after-scroll")
        let scrolledFrames = readSentenceFrames(app: app)

        var dump = "INITIAL frames:\n"
        for (id, f) in initialFrames.sorted(by: { $0.key < $1.key }) {
            dump += "  sentence_\(id) minX=\(f.minX) maxX=\(f.maxX) width=\(f.width)\n"
        }
        dump += "AFTER SCROLL frames:\n"
        for (id, f) in scrolledFrames.sorted(by: { $0.key < $1.key }) {
            dump += "  sentence_\(id) minX=\(f.minX) maxX=\(f.maxX) width=\(f.width)\n"
        }
        let frameDump = XCTAttachment(string: dump)
        frameDump.name = "frame-dump"
        frameDump.lifetime = .keepAlways
        add(frameDump)

        let allMinXs = (initialFrames.values + scrolledFrames.values).map(\.minX)
        guard let smallest = allMinXs.min() else {
            XCTFail("no sentence frames captured")
            return
        }
        XCTAssertGreaterThan(
            smallest, 18,
            "transcript shifted left — minX=\(smallest), should be ~24. Bug repro!"
        )
    }

    // MARK: - Helpers

    private func readSentenceFrames(app: XCUIApplication) -> [Int: CGRect] {
        var out: [Int: CGRect] = [:]
        for txt in app.staticTexts.allElementsBoundByIndex {
            let identifier = txt.identifier
            guard identifier.hasPrefix("transcriptSentence_"),
                  let id = Int(identifier.dropFirst("transcriptSentence_".count))
            else { continue }
            out[id] = txt.frame
        }
        return out
    }

    private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
