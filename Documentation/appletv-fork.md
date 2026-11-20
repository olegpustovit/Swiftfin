# Apple TV Fork: Scope, Plan, and Status

This fork of Swiftfin (`appletv-native` branch) focuses on making the tvOS app feel like a first-party Apple TV app.

## Scope

| # | Area | Problem | Plan | Status |
|---|------|---------|------|--------|
| 1 | Player | The custom SwiftUI overlay differs from the system player (transport bar, info panel, scrubbing, menus). | Host the system `AVPlayerViewController` on top of the existing `AVMediaPlayer` engine and `MediaSession` (`Swiftfin tvOS/Views/VideoPlayer/NativeVideoPlayer.swift`). AVPlayer is now the tvOS default; the native interface can be turned off in Settings → Video Player. | Done |
| 2 | Subtitles | System subtitle menus only see tracks inside the current stream; Jellyfin often needs a new stream (burn-in, HLS WebVTT, external files). | A Jellyfin-backed **Subtitles** transport bar menu lists every server track (forced/external/codec detail) and uses the same selection logic as the custom player, including server rebuilds. System subtitle UI is hidden to avoid duplicate menus. | Done |
| 3 | Audio | Same as subtitles for audio tracks. | Jellyfin-backed **Audio** menu; system Audio menu selections are synced back to the session. | Done |
| 4 | Quality | No way to change bitrate/version/resolution in the system UI. | **Quality** menu (version, bitrate, max resolution). | Done |
| 5 | Chapters | — | Native chapter markers (`navigationMarkerGroups`) with chapter thumbnails. | Done |
| 6 | Intros / credits | — | System contextual actions: **Skip Intro**, **Skip Credits**, **Next Episode** (last 30 s or credits). | Done |
| 7 | Info panel | — | Title, description (HTML-free), artwork; **Episodes** tab to jump within the season. | Done |
| 8 | Playback state | System UI drives `AVPlayer` directly, bypassing the session. | Forward play/pause, speed (`defaultRate`), and scrubbing to `MediaSession` so progress reporting, resume, and Now Playing stay correct. | Done |
| 9 | Autoplay | Next episode could start paused (end-of-item pause raced the queue advance). | `MediaSession.ended` resets the requested status to playing before advancing. | Done |
| 10 | Seasons (#2388) | Shows with > 20 seasons were truncated. | Season group page size 100. | Done |
| 11 | Overviews (#1537) | Raw HTML tags/entities in descriptions. | Lightweight HTML → `AttributedString` parser (bold/italic, entities, line breaks) without WebKit. | Done |
| 12 | mpv TrueHD (#2443) | Apple TV HD / 4K (1st gen) stall on TrueHD. | Do not advertise TrueHD to mpv on A8/A10X; the server transcodes instead. | Done |
| 13 | Performance | Large PNG encodes for system artwork. | JPEG artwork for `externalMetadata`. | Done |
| 14 | Signing | Upstream ships without a team. | `XcodeConfig/DevelopmentTeam.xcconfig` (git-ignored) sets the team and bundle ID; `Scripts/install-appletv.sh` builds, signs, installs, and launches on a paired Apple TV. | Done |

### Out of scope (follow-ups)

- Top Shelf extension (needs an App Group shared with the main app).
- Picture in Picture from the native player (disabled to keep the session lifecycle simple).
- Trickplay thumbnails while scrubbing in the native player (AVKit only uses HLS I-frame playlists, which Jellyfin does not produce).

## Testing

`Tools/Screenshots/Tests/NativePlaybackTests.swift` drives the app with the Siri Remote on the tvOS Simulator and uses the Jellyfin `/Sessions` API to check what is actually playing:

- start playback, play/pause from the remote
- switch subtitles (incl. server rebuild) and audio (Japanese 5.1 AC3 → server rebuild), keep position and other selection
- subtitles off
- leave with Menu: playback stops, resume position saved
- episodes: **Next Episode** contextual action advances the queue

Run against the local test server (`make setup` creates it in `.testserver/`):

```sh
make test
```

## Quick start (macOS)

```sh
git clone https://github.com/olegpustovit/Swiftfin.git && cd Swiftfin
make setup   # Xcode license/first launch, tvOS platform + Simulator, swiftformat/swiftlint, Jellyfin test server
make run     # start the test server, build, and launch the app in the Apple TV Simulator
```

Requires Xcode from the App Store. `make setup` downloads the tvOS platform (several GB) if it is missing,
and a portable Jellyfin server + jellyfin-ffmpeg into `.testserver/`, generates test media
(multi-audio/subtitle/chapter movie, HEVC movie, three-episode show), and creates libraries and users.

In the app, connect to `http://localhost:8096` and sign in as `demo` (no password). The admin account is `tester` / `tester`
(web UI at http://localhost:8096).

| Command | What it does |
|---|---|
| `make setup` | One-time toolchain, simulator, and test server setup (safe to re-run) |
| `make run` | Start the server, build Debug, install and launch in the "Swiftfin Apple TV" simulator |
| `make test` | Native player UI tests (`NativePlaybackTests`) |
| `make device` | Build Release, sign, install, and launch on a paired Apple TV |
| `make server` / `server-stop` / `server-status` / `server-reset` | Manage the test server |
| `make help` | List all commands |

## Installing on your Apple TV

1. Create `XcodeConfig/DevelopmentTeam.xcconfig` (git-ignored) with your team and a unique bundle ID:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   PRODUCT_BUNDLE_IDENTIFIER = com.example.swiftfin
   ```
2. On the Apple TV: Settings → Remotes and Devices → Remote App and Devices.
3. In Xcode: Window → Devices and Simulators → pair the Apple TV (enter the code shown on the TV).
4. Run `make device`.
