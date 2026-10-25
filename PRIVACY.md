# Privacy

Gestures processes hand landmarks locally with Apple Vision. It has no account,
analytics, network client, remote model, or microphone capture.

Camera capture begins only when you start it. Camera frames and demonstration
landmarks stay in memory. They are not written to disk or uploaded. Camera and
Mac control start off on every launch. Closing the window while control is on
keeps recognition running; the menu-bar controls can pause actions, stop the
camera, or quit the app.

The optional desktop ripple requires separate screen-recording permission.
It captures one display frame for the animation and uses it in memory. It does
not create screenshot files or recordings. Turn off Desktop ripple to stop
using that effect. macOS can revoke camera, screen, and event-posting permissions.

Gesture definitions are stored in the current user's Application Support
directory. They include gesture names, poses, key codes, modifiers, optional
Shortcut names, and optional app bundle identifiers. Appearance and consent
preferences are stored in UserDefaults. No machine serial number, account
credential, device fingerprint, or personal contact information is required.

Exports contain your configured definitions and names. Review them before
sharing. Camera frames, recorded landmark samples, camera device identifiers,
and local home-directory paths are not part of the export format.

If you assign an Apple Shortcut, that Shortcut may access files, use the network,
or perform other actions according to its own permissions. Review it in Apple's
Shortcuts app before assigning it. Stopping Gestures cannot undo work a Shortcut
has already performed.

Apple-signed downloads expose the certificate holder's developer identity as
part of Apple's signature. The source package contains no signing certificate,
private key, account credentials, personal email, or saved user library.

Volume control reads the default output's identity, volume, mute state, and writable
control availability through Core Audio. The identity is held only in memory to
stop a gesture when outputs change; it is not logged, exported, or saved. The app
does not record audio or query media content. Practice volume uses synthetic data
and never reads or writes an audio device.
