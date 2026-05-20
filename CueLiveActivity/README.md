# CueLiveActivity (Widget Extension)

This folder holds the Live Activity (Dynamic Island + lock-screen card) for
Cue. The Swift files are written; one manual step in Xcode wires them into a
new Widget Extension target.

## Add the target in Xcode (≈60 seconds)

1. With the Cue project open, **File → New → Target…**
2. Select **iOS → Widget Extension** → Next.
3. Set:
   - **Product Name:** `CueLiveActivity`
   - **Team:** same as Cue
   - **Bundle ID:** Xcode will suggest `com.toug.cue.CueLiveActivity`
   - **Include Live Activity:** ☑️ check this
   - **Include Configuration App Intent:** ☐ uncheck
   - **Embed in Application:** Cue
4. Click **Finish**. If Xcode asks to activate the new scheme, choose **Cancel**
   (we keep the Cue scheme active and the extension builds automatically as a
   dependency).
5. Xcode created stub files in `CueLiveActivity/` — **delete them**:
   - `CueLiveActivity.swift`
   - `CueLiveActivityAttributes.swift` (if present)
   - `CueLiveActivityBundle.swift` (Xcode's stub; we already have our own)
   - `Assets.xcassets` (we don't need it for the Live Activity)

   Keep the new `CueLiveActivity` group / folder in the project navigator.
6. Drag the files we wrote into the new target's folder, ensuring **Target
   Membership** is **only CueLiveActivity** (not Cue):
   - `CueNowPlayingActivity.swift`
   - `CueLiveActivityBundle.swift`
7. Add `CueActivityAttributes.swift` (which lives in the main `Cue/` folder)
   to the CueLiveActivity target as well. Click the file in the Project
   Navigator → File Inspector (right pane) → **Target Membership** → tick
   the **CueLiveActivity** box in addition to **Cue**.
8. Build (⌘B). If the extension's deployment target complains, set it to
   match the app (iOS 18.0).

That's it. Run on a physical device or the iPhone 16 Pro simulator (Dynamic
Island only renders on Pro models). Start playing an episode, then home-
button out — the Live Activity should appear on the lock screen and the
Dynamic Island.

## Files in this folder

- `CueLiveActivityBundle.swift` — `@main WidgetBundle`.
- `CueNowPlayingActivity.swift` — `ActivityConfiguration` with lock-screen,
  expanded island, compact island, and minimal island views.
- `Info.plist` — minimal extension plist declaring the widget extension
  point. Xcode's template generates this automatically when you add the
  target; ours is here as a reference.

The shared `CueActivityAttributes` type lives in `../Cue/CueActivityAttributes.swift`
because it must be visible to both the app (which starts/updates/ends the
activity) and the extension (which renders it).
