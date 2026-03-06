# Music Assistant Menu Bar (macOS)

Minimal menu bar controller for a Music Assistant server.

## Screenshot

![Music Assistant Menu Bar screenshot](screenshot.png)

## Features (v1)

- Menu bar-only app (no dock icon via accessory activation policy)
- WebSocket API client (`ws://<host>:<port>/ws`)
- Configurable API host + port
- Token input with permanent Keychain storage
- Bonjour auto-discovery (`_music-assistant._tcp` then `_home-assistant._tcp`)
- Auto target selection:
  - Prefer currently playing group player
  - Else currently playing non-synced coordinator
  - Else last successful target
- Play/Pause control
- Play/Pause button label reflects current state (`Play` when paused/idle, `Pause` when playing)
- Volume slider (0-100)
  - Group target: `players/cmd/group_volume`
  - Normal player: `players/cmd/volume_set`
- Now Playing line with marquee scrolling for long track text
- Global hardware Play/Pause media-key listener (native, no dependencies)
- Exclusive Play/Pause key capture via `CGEventTap` when permissions allow
- Automatic reconnect with backoff

## Run

```bash
swift run MusicAssistantMenuBar
```

## Build

```bash
swift build
```

## Signed Build Script

Use `build.sh` for a signed distributable `.app` and `.zip` (outside Mac App Store):

```bash
./build.sh
```

Optional environment variables:

- `SIGNING_IDENTITY` (optional; auto-detected when possible)
- `APP_NAME` (default: `MusicAssistantMenuBar`)
- `PRODUCT_NAME` (default: `MusicAssistantMenuBar`)
- `APP_ICON_PATH` (default: `Assets/AppIcon.icns`)
- `BUNDLE_ID` (default: `io.example.musicassistant.menubar`)
- `VERSION` (default: `1.0.0`)
- `BUILD_NUMBER` (default: `1`)
- `OUTPUT_DIR` (default: `dist`)
- `SIGNING_KEYCHAIN` (path to a specific keychain)
- `SIGNING_CERT_P12_BASE64` (optional; base64-encoded `.p12` for CI import)
- `SIGNING_CERT_PASSWORD` (required when `SIGNING_CERT_P12_BASE64` is set)
- `CI_KEYCHAIN_PASSWORD` (optional; temp keychain password)
- `NOTARIZE=1` to notarize
  - Use `NOTARY_PROFILE` (recommended), or
  - `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`

Artifacts are written to `dist/`.

### CI Example (GitHub Actions)

Self-contained step (imports signing cert from secrets):

```yaml
- name: Build and sign
  run: ./build.sh
  env:
    SIGNING_IDENTITY: ${{ secrets.SIGNING_IDENTITY }}
    SIGNING_CERT_P12_BASE64: ${{ secrets.SIGNING_CERT_P12_BASE64 }}
    SIGNING_CERT_PASSWORD: ${{ secrets.SIGNING_CERT_PASSWORD }}
    BUNDLE_ID: io.yourcompany.musicassistant.menubar
    VERSION: ${{ github.ref_name }}
    BUILD_NUMBER: ${{ github.run_number }}
```

## Notes

- Host/port are saved in `UserDefaults` and token is saved in Keychain.
- Use the gear button in the menu panel to configure host/port/token and connect.
- To fully block Apple Music from launching on Play/Pause, grant Accessibility/Input Monitoring permissions to the app process. Without permissions, the app falls back to passive key monitoring.
