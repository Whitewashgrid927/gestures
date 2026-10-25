# Security

Security-sensitive reports should use the repository's private vulnerability
reporting feature when available. Do not include credentials, screen captures,
personal gesture exports, or other private data in public issues.

## Required properties

- Camera and Mac control start off. Practice never posts actions.
- Editing, including Ripple settings, pauses control. Closing settings does not resume it.
- Dispatch rechecks camera state, freshness, scope, Option clutch, secure input,
  and required macOS permission after an animation. Cancelled or rejected scroll
  starts cannot produce subsequent scroll events.
- Pause, tracking loss, sleep, permission changes, and cancellation must remain
  fail-closed. Pending synthetic key releases must always be completed.
- Imported libraries are bounded, validated, and disabled. Imports do not execute
  actions. Review displays derive from executable key codes and app bundle IDs;
  supplied display labels are not authoritative.
- Screen frames and camera frames stay in memory. Capture and animation deadlines,
  screen-size limits, reduced-motion behavior, and fixed shader edges must remain bounded.
- App switching requires an opening pinch, clear open-hand browsing, and a second
  deliberate, confidently tracked pinch. Tracking loss or a second hand leaves the
  picker visible but freezes selection and blocks activation until a clear open hand
  rearms input; returning with a pinch cannot confirm. A changed foreground app,
  timeout, Cancel, or paused control closes it. Practice never activates apps.
  The picker cannot take focus; only its Cancel control handles clicks. After the ripple,
  dispatch rechecks the saved rule, current app, permissions, and target process identity.
- Shortcut execution uses a fixed executable and argument array, never a shell.
  It remains single-flight with a timeout. Already-executed Shortcut work cannot be undone.
- Continuous scrolling accepts exactly one confident matching hand, preserves known
  hand identity across unknown observations, and stops on ambiguity, discontinuity,
  stale frames, foreground/Space changes, or released gates. Motion is bounded and
  never queued for later playback. The glass indicator is click-through and cannot
  take focus. Disabling its visibility does not disable any input checks. Practice
  may display scrolling feedback but cannot post scroll events.

- Fist recognition may use three confidently observed joints to establish a
  finger bend when its tip is occluded. All four non-thumb fingers still need
  positive curl evidence at the configured confidence; missing, degenerate, or
  straight joints cannot be assumed bent. Other pose confidence requirements
  remain unchanged. Recognition diagnostics store only current status text in
  memory, not images or landmark histories.
- Fist volume arms on at least three confident observations spanning 120 ms
  within a bounded 500 ms window. Uncertain observations never authorize movement
  or complete arming. During a session they emit zero movement for at most 350 ms
  since the last confident observation, and recovery resets the movement anchor. A confident opened
  finger, missing or second hand, lost continuity, or expired uncertainty stops
  the session. The watchdog also enforces the uncertainty deadline without frames.
- Partial fist evidence may suppress a competing app-switch pinch only while an
  enabled fist-volume rule is eligible for that hand, scope, and Option state.
  At least three confident bends and no confident opened finger are required.
  This is arbitration only: incomplete fists authorize no action.
- Continuous volume shares the single-hand, freshness, scope, Option, editing,
  secure-input, and cancellation gates. It starts from the observed output level;
  Practice never calls the audio device interface. Each write rechecks output
  identity, writable main scalar, mute, and current level. Muted outputs are never
  written, and outputs without a supported main control fail closed. No channel,
  balance, mute, media-key, or shell fallback is permitted. Changes are bounded by
  elapsed time, the configured ceiling, and a per-update limit. A raised starting
  level is not abruptly clamped. Readback precedes further writes; missing
  acknowledgment times out. Cancellation forgets all output state. Small hardware
  quantization is tolerated only around an outstanding request.

## Scope and limits

This is a user-authorized desktop automation app, outside App Sandbox. It has
no administrator helper. Camera, Accessibility/event-posting, and optional
Screen Recording permissions are enforced by macOS. Recognizing a gesture does
not prove the target app accepted the action. Hand recognition can make mistakes;
use Practice and app-specific scopes before enabling consequential actions.

Source changes should run `Scripts/test.sh` and a complete `Scripts/build.sh`.
Tests construct events without posting them and use synthetic images for GPU
checks. Live camera, permission-revocation, and application behavior also need
hands-on testing. Public downloads require Developer ID signing, notarization,
and Gatekeeper validation; a successful development build alone is insufficient.
