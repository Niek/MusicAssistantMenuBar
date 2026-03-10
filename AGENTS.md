# AGENTS

## Project Summary

Music Assistant Menu Bar is a Swift (SwiftPM) macOS 13+ menu bar app that controls a Music Assistant server over WebSocket.

Core scope today:
- Connect/authenticate to MA server (`ws://<host>:<port>/ws`)
- Auto-select active target player
- Play/Pause, Previous, Next
- Volume control (normal and group-aware)
- Now Playing display
- Global Play/Pause media key support (exclusive capture when permissions allow)

## Important Files

- `Package.swift`: SwiftPM config (`swift-tools-version: 6.1`)
- `Sources/MusicAssistantMenuBar/MusicAssistantMenuBarApp.swift`: app entry + menu UI
- `Sources/MusicAssistantMenuBar/PlayerStore.swift`: state, commands, UI-facing logic
- `Sources/MusicAssistantMenuBar/MAWebSocketClient.swift`: websocket transport/auth/reconnect
- `Sources/MusicAssistantMenuBar/MediaKeyMonitor.swift`: media-key capture/passive fallback
- `Sources/MusicAssistantMenuBar/AppConfig.swift`: host/port persistence + token keychain storage
- `build.sh`: package/sign/notarize helper
- `.github/workflows/build.yml`: CI build + tag release workflow

## Local Development

Run app:

```bash
swift run MusicAssistantMenuBar
```

Build:

```bash
swift build -c release --product MusicAssistantMenuBar
```

Package app bundle (and sign by default):

```bash
./build.sh
```

Unsigned CI/dev package:

```bash
SIGN_APP=0 ./build.sh
```

## Manual Test Checklist

1. Launch app from `swift run MusicAssistantMenuBar`.
2. Open settings panel and configure host/port/token.
3. Verify status transitions to `Connected` and target resolves.
4. Verify `Play/Pause` button text/icon reflects current playback state.
5. Verify `Previous`/`Next` buttons trigger track changes.
6. Verify volume slider updates volume and stays in sync with live updates.
7. Press hardware Play/Pause key:
   - With permissions granted: app captures key and Apple Music should not steal it.
   - Without permissions: warning appears.
8. In warning card, verify:
   - `Allow Access` opens permission flow
   - `Open Settings` opens privacy settings
   - `Retry` re-attempts exclusive capture
9. Restart Music Assistant server and verify reconnect + control recovery.

## CI / Release Notes

- Regular pushes/PRs: macOS build, unsigned `.app` + `.zip` uploaded as artifacts.
- `v*` tags: signed build + GitHub Release asset upload.
- Required release secrets are documented in `README.md`.

## Persistence / Security

- API host/port: `UserDefaults`
- API token: macOS Keychain (`MusicAssistantMenuBar` service)
- Do not hardcode personal tokens/hosts in source.

## Development Guidelines

- Keep dependencies native (no third-party packages unless necessary).
- Preserve menu bar-only behavior (`LSUIElement` / accessory policy).
- Keep UI compact and responsive in menu popover width.
- Prefer explicit command behavior over ambiguous toggles where possible.
