import XCTest

/// Regression harness for the "transcript snaps to the left on initial
/// open, then shifts right when you scroll / playback advances" bug.
///
/// The original failure was caused by the 24pt horizontal inset living on
/// the same `LazyVStack` that participates in `scrollTargetLayout()`. During
/// the first programmatic `scrollPosition` settlement, SwiftUI could consume
/// that inset and place visible sentence text at x=0. This test launches a
/// large mid-episode transcript and measures the actual accessibility frames
/// before and after manual scrolling.
final class TranscriptLayoutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Loads a 60×-inflated sample transcript via the real `loadLive` flow
    /// at a mid-transcript resume position (so the scroll-to-activeIdx
    /// actually has to scroll), scrolls past the active sentence, and
    /// asserts every visible sentence is at minX ≈ 24pt (= the transcript
    /// row's leading inset).
    @MainActor
    func testTranscriptLeftPaddingPreserved() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CueUITestBypassAuth",
            "-CueUITestOpenSampleLive",
            "-CueUITestSkipMicPermission",
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

        let allMinXs = (Array(initialFrames.values) + Array(scrolledFrames.values)).map(\.minX)
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
