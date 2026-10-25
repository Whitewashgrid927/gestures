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
- App switching requires a deliberate, confidently tracked pinch release. Tracking loss,
  a second hand, changed foreground app, timeout, or pause cancels. Practice never
  activates apps. The picker cannot take focus or intercept clicks. After the ripple,
  dispatch rechecks the saved rule, current app, permissions, and target process identity.
- Shortcut execution uses a fixed executable and argument array, never a shell.
  It remains single-flight with a timeout. Already-executed Shortcut work cannot be undone.

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
