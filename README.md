# Gestures

A native Mac prototype for defining your own camera-based hand gestures and assigning actions. Built with SwiftUI, native Liquid Glass, AVFoundation, and Apple Vision. No accounts, external packages, cloud inference, or downloaded models are required. The optional desktop ripple uses local ScreenCaptureKit and Metal.

**[Download Gestures for Mac](https://github.com/Whitewashgrid927/gestures/releases/download/v0.1.12/Gestures-0.1.12-macOS-arm64.zip)** — Apple silicon, macOS 26 or newer. Unzip the download and move **Gestures.app** to **Applications**. No build tools are needed. The app is Developer ID signed and notarized by Apple.

[Release notes and checksums](https://github.com/Whitewashgrid927/gestures/releases/latest) · [Privacy](PRIVACY.md) · [Safety and security](SECURITY.md)

## Requirements

- An Apple-silicon Mac running macOS 26 or newer.
- A camera for live recognition. Camera access is requested only when you choose **Start camera**.
- If you select a specific camera, it must be available when capture starts. Gestures asks you to reconnect it or choose another device instead of silently opening a different camera. **System default** remains available as an explicit choice.
- Accessibility permission for keyboard, Space-switching, and scrolling actions. Test mode does not need that permission.

This source builds version 0.2.1 with the pinch-and-slide app picker. The download link above currently points to the published 0.1.12 release. A locally built app uses ad-hoc signing unless you supply an identity.

## First use

1. Open **Gestures.app**. Camera capture and Mac control start off every time.
2. Select **Swipe left** and choose **Practice only**, then **Start camera** when you are ready to allow camera access.
3. Face an open palm toward the camera, hold it still briefly, then move left in the mirrored preview. The step indicators explain what is being recognized. A completed gesture shows **Would run: Next Space**. Test mode sends no actions.
4. When satisfied, allow Gestures in **System Settings → Privacy & Security → Accessibility**. The app’s **Camera & permissions** sheet opens those settings. If the app is absent, add this copy of Gestures.app with the + button. On newer macOS versions this control may be labelled **Device Control and Data Access**. Restart the app after granting access if the permission status has not refreshed.
5. Turn on **Mac control** in the main window. This exits practice mode. The banner must say **Mac control is on**; seeing a hand in the preview alone does not enable actions. Choose **Run in background** or close the window to keep live gestures working in other apps. The menu-bar hand provides **Pause Mac control**, **Resume Mac control**, **Stop camera**, **Open Gestures**, and **Quit Gestures**.

For Space switching, create at least two desktops in Mission Control and enable **Move left a space** / **Move right a space** under **Keyboard → Keyboard Shortcuts → Mission Control**. The defaults send Control–Right and Control–Left. If you use different bindings, choose the Keyboard shortcut action and record your actual combination. An action can be sent without changing anything when the system shortcut is disabled or you are already at the last Space.

## Using Gestures in the background

Start the camera and enable **Mac control**, then choose **Run in background** or close the window. The camera and gesture engine remain active while you use other apps. Global gestures work across apps; app-specific gestures still require their configured app to be in front. Switching apps clears incomplete gestures and stops continuous scrolling while preserving the cooldown and lower-your-hand requirement after an action.

Use the hand icon in the macOS menu bar to pause or resume Mac control, stop the camera, reopen the configuration window, or quit. The menu also shows the latest completed gesture/action when available. Pausing stops actions while retaining the camera; **Stop camera** stops both. Quitting releases any pending synthetic keys and stops the camera.

Closing the window during preview or practice, with Mac control off, still stops the camera. Background operation does not start capture on launch or bypass sleep, screen-lock, protected-input, camera-health, or permission checks. Live control holds a process-activity token so the app can keep recognizing gestures with its window closed; that token allows normal idle system sleep and ends when control stops.

## Pinch & slide to switch apps

Choose **Pinch & slide** in the sidebar to add or select the disabled preset. Start
the camera and use **Practice only** first. Pinch your thumb and index finger to
open the native Liquid Glass app picker. Keep pinching and slide
left or right to highlight an app. Open the pinch for a brief, confidently tracked
release to choose it. Lowering the hand, losing tracking, showing a second hand,
or leaving the current app cancels instead. Releasing without browsing also cancels.

**Edit gesture → Action** sets travel per app, reverse direction, a 3–10 second
timeout, and an optional list of included apps. Only running apps appear; the list
is frozen during each interaction, limited to 20, and excludes Gestures itself.
The **Gesture** tab configures the starting sequence and hand. The final pose must
be pinched; a separate Release step is not needed. The new **Slide sideways** step
accepts deliberate horizontal motion in either direction. Give other enabled pinch
gestures a distinct starting pose, hand, or app scope to avoid competing mappings.

**Preview picker** shows synthetic app names without camera access or app activation.
Practice can show the real running-app picker, but only reports what it would switch
to. To use it for real, enable **Use gesture** in the editor, then **Mac control**.
The picker never takes keyboard focus or intercepts clicks. Reduced Motion disables
its selection animation, and the glass follows macOS accessibility settings.

On release, the picker disappears, the optional desktop ripple runs, and only then
does Gestures request app activation. The final gate rechecks the current app,
unchanged rule, permissions, Option clutch, secure input, current camera frame,
and the selected process identity. The existing 350 ms frame and 650 ms completed
gesture deadlines apply to that final release. App activation is reported as
confirmed only after macOS actually makes the target app active. Pausing, editing,
sleep, stale input, or cancellation clears both picker and pending activation.
No app list, process identifiers, icons, or activation history are written to disk;
only explicitly configured app bundle IDs are saved with the rule.

## Desktop ripple

A propagating ripple travels across the working display in the configured swipe direction before the interaction sends its action. Its Metal wave is adapted from Apple's [WWDC24 Ripple.metal sample](https://developer.apple.com/documentation/swiftui/creating-visual-effects-with-swiftui): a distance-dependent arrival delay followed by an exponentially decaying sine wave. Directional gestures launch from the opposite display edge; nondirectional gestures launch from the center. The default peak bend is approximately 32 screen points, adjustable from 8 to 48 points. Duration controls playback speed independently. This is a custom Metal effect over one in-memory screen frame; the app's controls use Apple's native Liquid Glass. The Apple sample license is included in both source and app resources.

The display border stays fixed and transparent. Refraction and coverage rise smoothly beyond that border, with the ramp scaled to strength so texture samples remain inside the captured image. This removes the stretched edge strips produced by the previous unrestricted distortion. Pixels ahead of the wave remain still, the return wave is weaker, and the content settles back before the action. The sample's brightness highlight is omitted to preserve desktop brightness.

Open **Ripple** at the bottom of the main window for a sample preview with the same timing and relative strength as the actual effect. Use **Strength** to tune the bend from Soft to Extra strong. It starts at Strong and remembers your choice separately from your gesture definitions. Adjusting the slider replays the preview when you release it; it changes the bend, not the duration or action delay. The preview is a synthetic desktop drawn in memory and needs no camera or screen access. **Replay preview** repeats it three times. No Mac action is sent from the sample.

Use **Duration** to set how long the ripple takes: drag the slider from **150 to 500 milliseconds**, or type an exact value in the **ms** field and press Return. The **Fast** (220 ms), **Medium** (320 ms), and **Slow** (400 ms) buttons remain as shortcuts. Longer duration slows the same wave; it does not add a separate pause. Slider release, a committed number, or a preset replays the sample. The setting persists independently of strength and gesture definitions. Existing speed preferences keep their old duration until a custom value is chosen. Invalid typed input keeps the current value, and numeric values are bounded to the supported range.

Each interaction snapshots its selected duration. If capture or first presentation takes longer, the animation timeline may shorten to fit the original safety deadline; its target never exceeds the selected duration. Presenting the last frame can add a few display refresh intervals, covered by the existing presentation reserve. The watchdog uses the resulting duration. Every duration retains the same final freshness checks and pre-action ordering, including the 650 ms total gesture-age limit. A 500 ms setting is a target, not a promise to delay an action past that limit.

The real desktop effect requires macOS **Screen & System Audio Recording** permission. Choose **Allow desktop ripple…** only if you want that access. Gestures reads one frame of the display containing the pointer per eligible interaction, never captures audio, never writes screen images or recording files, and never uploads frames. The captured buffer and GPU mapping are retained until their rendering commands finish, then released; protected content may be excluded by macOS. The feature requires both an explicit local opt-in and the macOS permission.

The effect starts and ends completely transparent, refracts only the passing wave, and adds no brightness highlight. Capture, texture, and output use matching Display P3 color. The fade premultiplies encoded color so transparency cannot brighten the desktop. At Slow, the effect lasts up to about 400 milliseconds, giving the wave more time to travel across the screen; at every speed, its final transparent frame must reach the display before the window clears and the configured action is sent. Capture preparation is limited to at most 250 milliseconds and must leave room for the selected wave up to the Fast preset duration. When the first frame reaches the display, longer speeds fit into the remaining time, reserving 60 milliseconds for final presentation. The action is cancelled if the total age of its recognized gesture exceeds 650 milliseconds, or if the latest camera frame is over 350 milliseconds old. Unavailable capture or capture past that allowance falls back to the normal action. Late captures cannot flash after the action. Only one capture is in flight at a time, and exceptionally large displays are skipped rather than allocating unbounded textures.

The overlay ignores mouse clicks and cannot become the key/main window. Pausing, stopping the camera, app changes during the prelude, editing, sleep/lock, display changes, or changing the selected rule cancels a pending effect and its action. The final dispatch rechecks the latest camera frame's unchanged 350-millisecond freshness limit, the 650-millisecond gesture deadline, live camera/control, app scope, and protected input. No gesture gates, neutral-hand rearming, cooldowns, or key-release handling have been weakened.

**Desktop ripple** remembers its on/off setting separately from your gesture definitions. **Reduce Motion** or **Reduce Transparency** skips the effect and preserves normal actions. Practice mode never reads the screen or sends actions. Continuous scrolling starts after its initial ripple and does not capture a frame per scroll tick. A pre-action ripple indicates a recognized interaction; it does not prove that the subsequent command succeeded. The existing Space-change check continues to report what macOS actually observed.

The runtime captures a CMSampleBuffer and maps its BGRA IOSurface directly into a Metal texture. It does not convert the screen through CGImage, redraw it on the CPU, or copy it into a new texture. The empty effect window is prepared in advance and reused; WindowServer prepares its transparent layer while capture runs. Rendering uses two drawables to limit queued frames. Any cancelled layer is replaced while hidden; completed drawables and captured images are released. Synthetic previews use a separate image-loading path.

Rendering follows the display refresh rate up to 120 Hz. Diagnostics report capture time, mapping time, first presentation, total pre-action time, frame count, and the largest presentation gap. They contain no pixels, window titles, gesture names, or screen contents.

### Checking a Space action

With the camera and Mac control on, select a Space gesture and choose **Switch Space now** to send its configured shortcut once without making a hand gesture. This check uses the same permission, scope, frame-freshness, and protected-input gates as gesture dispatch. It does not run in practice mode.

During live recognition, the feedback separates **gesture completed** from **shortcut sent**. A Space action then waits up to 2.5 seconds for a macOS Space-change notification. **Space change observed** means a notification arrived after the command; it cannot prove that the command caused it if you also change desktops manually. **Space switched** additionally means the app saw its own window leave the active desktop. **No Space change observed** is not a recognition failure. Check the shortcut binding, whether there is another Space in that direction, and whether macOS paused control.

**Practice only** is available while Mac control is off. It is hidden during live control so practicing cannot accidentally pause a running setup. Stopping practice leaves control off until you explicitly enable it. Protected input and screen lock also pause control; finish the protected task, then enable Mac control when ready.

## Define your own gesture

Choose **New gesture** or **Edit gesture**. The editor has three tabs:

- **Gesture:** choose either hand or a specific hand. Start with a pose, then combine up to ten steps: poses, holds, movement in eight directions, and an optional final release. A Custom pose lets you set each finger to Straight, Bent, or Any, plus a thumb/index pinch condition. Movement distance, deadline, and hold time are editable. Hold is optional: for a simpler swipe, use Open palm followed directly by Move left or Move right. Even without a Hold step, the starting pose must remain stable for 120 milliseconds, and the movement-distance, direction, confidence, cooldown, and neutral-hand checks still apply. Multiple Move steps create a path, such as left then up.
- **Action:** select Next/Previous Space, Mission Control, App windows, a recorded keyboard shortcut, a named macOS Shortcut, or continuous horizontal/vertical scrolling. The keyboard recorder listens only while its field is focused. It does not install a global keyboard recorder.
- **Where:** use the gesture in all apps or only when a chosen app is in front. App-specific rules win when multiple rules finish together; one discrete action fires. Scope does not create a separate active profile switch—the sidebar filters which rules you see.

**Use gesture** controls whether that definition participates in live control. New gestures start disabled. Main-window **Mac control** controls the entire engine. Test mode always tests the selected definition, including disabled rules and rules scoped to another app.

**Fine-tune** adjusts required tracking confidence, cooldown, neutral-hand rearming, and an optional hold-Option clutch. Starting another gesture requires lowering your hand by default. A hold that drifts too far restarts its timer; a movement that goes the wrong way, takes too long, or loses tracking resets the sequence.

**Demonstrate a swipe** captures five seconds of hand landmarks in memory and proposes a pose, direction, and distance. Make one swipe, then keep your hand at the end position. Review the disabled suggestion and test it before use. This is a convenience for defining a swipe, not a model that learns arbitrary motion from one example.

For continuous scrolling, complete the sequence and keep its final pose while moving. Releasing that pose, losing the hand, a large tracking jump, releasing an enabled Option clutch, or changing the active app stops scrolling. Scroll deltas and speed are bounded.

## Save and share definitions

Definitions are saved locally in `~/Library/Application Support/Gestures/Library.gestures`. Export/import is available in the sidebar menu and the Gestures menu. Imported rules receive new IDs and are always disabled for review. Imports are validated, limited to 2 MB and 100 total rules, and cannot run an action by being opened. Undo/Redo reverses gesture edits in the current session.

Edits, deletions, imports, and undo/redo take effect only after their save succeeds. If storage is unavailable, the library, selection, and undo/redo history stay unchanged, Mac control pauses, and the app reports the failure. Restore access and retry the operation; a successful retry clears the earlier save error.

Exports contain names, poses, action bindings, Shortcut names, and chosen app bundle IDs/names. Review these before sharing because you choose those values. They do not contain camera frames, hand recordings, camera device IDs, credentials, or local home-directory paths.

## Privacy and control

Camera frames stay in memory and pass directly to Vision and the live preview. There is no video/photo recording, microphone capture, analytics, network client, hidden upload, or frame archive. Demonstration landmarks are discarded after producing a suggestion or cancelling. The library stores gesture definitions, not biometric identity profiles.

Mac control is off on launch. Editing, imports, undo/redo, camera stop/failure, stale frames, sleep/session deactivation/display sleep, protected input, and loss of required Accessibility access pause or block dispatch. A camera generation token discards frames and status updates from older sessions. The final action gate independently checks test mode, camera state, editing, scope, Option clutch, and frame freshness. Opening Ripple settings pauses control; closing them does not resume it. Continuous scrolling starts only after its initial action is accepted.

System navigation sends the complete Control-key press, arrow press/release, and Control release. The transitions are spaced by 20/45/20 milliseconds. If Control is already physically held, Gestures leaves that physical key held. Pausing, stopping the camera, and quitting release only pending synthetic keys. Ordinary custom keyboard shortcuts use a 45-millisecond key-down/up pair and retain a private event source. Navigation uses a HID source with native arrow-key Fn/numeric-pad metadata. The app requires no administrator helper or root access. It is intentionally not App Sandbox enabled because global automation is its purpose; macOS Camera and Accessibility permissions still apply. Signed builds use hardened runtime and the camera entitlement.

A configured macOS Shortcut can access data, use the network, or change files according to that Shortcut’s own permissions and actions. The app runs the named Shortcut with an argument array, without a shell; option-like names are rejected. Only one can run at a time and its launcher is terminated after 30 seconds or when control pauses. Stopping the launcher cannot undo actions already performed and may not stop work the Shortcuts service has already accepted.

## Current limits

Recognition uses 2D hand landmarks and deterministic pose/movement rules. It does not recognize full-body gestures, simultaneous two-hand choreography, depth, arbitrary drawing shapes, or learned arbitrary gestures. Finger classification works best with one entire hand visible, palm toward the camera, in even lighting. Confidence, occlusion, fast movement, physical hand differences, and camera angle affect recognition. Continuous scrolling is relative hand motion, not pointer control.

The automated checks cover recognition, dispatch gates, persistence, import review, and synthetic GPU rendering. They do not post input events or start a camera. Live hand recognition, permission revocation, Shortcuts, scrolling, and target-app behavior need hands-on testing on each supported configuration.

## Build and test

Use Xcode with the macOS 26+ SDK selected. No package installation is required.

```sh
./Scripts/build.sh
./Scripts/test.sh
```

The build lands in `.build/Gestures.app`. The script signs ad hoc by default; for a persistent locally signed build, set `SIGNING_IDENTITY` to an existing Apple Development or appropriate distribution identity in your Keychain. No signing keys or identity names are stored in this source tree.

```sh
SIGNING_IDENTITY="YOUR_SIGNING_IDENTITY" ./Scripts/build.sh /path/to/output
```

The test executable never requests the camera or posts system events. Passing an optional local image path also runs a Vision smoke test expecting a visible hand:

```sh
./Scripts/test.sh /path/to/synthetic-hand.png
```

The source is split into Models (validated definitions), VisionTracking (landmarks and geometry), Recognition (deterministic state machines), Camera (serialized capture), Actions (gated dispatch), LibraryIO (persistence/import), Store (app state), DesktopRipple (bounded screen capture and Metal refraction), GlassFeedback (appearance preview), and native SwiftUI views. Tests also construct keyboard events without posting them and exercise control-mode and Space-notification timing. Tests cover gesture sequences and rejection, release and loss of tracking, scope arbitration, cooldown/rearming, continuous scrolling, action permission gates, import validation, persistence, undo/redo, safe relaunch, and swipe suggestions.

## Sharing and releases

Imported shortcuts are displayed from their executable key codes using the local
keyboard layout. App scopes display their exact bundle identifiers (or **All apps**).
Labels carried in a library are retained for file compatibility but cannot override
those identities. Imports remain disabled until you review and enable them.

`Scripts/package.py --app /path/to/Gestures.app --output /path/to/release` creates
a source ZIP and app ZIP, plus SHA-256 checksums. Source selection uses an allowlist.
Archives omit filesystem ownership, extended attributes, local timestamps, build
products, personal libraries, and signing material. Publish only the verified release
files, not a development workspace or personal export.

Distribution signing and notarization require your own Apple Developer account.
Keep account settings and credentials in Xcode/Keychain, outside this repository.
Never commit signing keys or use your personal email for public Git commits if you
want it private; configure the repository to use your GitHub noreply address.

The full automation app is not App Sandbox enabled. Mac App Store submission would
require a separate feasibility and policy review; a GitHub build does not establish
App Store eligibility.

## License and privacy

Gestures is MIT licensed; see [LICENSE](LICENSE). The adapted Apple ripple sample
retains its separate notice in [AppleRipple-LICENSE.txt](Resources/AppleRipple-LICENSE.txt).
See [PRIVACY.md](PRIVACY.md) for data handling and [SECURITY.md](SECURITY.md) for safety
properties and reporting guidance.
