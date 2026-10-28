# MotoCam

MotoCam is a Flutter dashcam app for motorcycle riders. It records video in fixed-length segments with a rolling loop limit and takes one GPS and accelerometer telemetry sample per second during a ride. It detects crash-like acceleration and locks the surrounding segments so the loop does not delete them. While recording and at stop it writes a per-ride telemetry JSON file with a SHA-256 integrity check. Recorded rides can be reviewed in Ride History, where all of a ride's segments play as one timeline with synced telemetry, a speed graph and an optional OpenStreetMap route map. Android is the supported platform. Its native features (the foreground recording service, Picture-in-Picture, battery and thermal status, gallery export) are implemented in Kotlin.

## Contents

- [Platform support](#platform-support)
- [Key features](#key-features)
- [Permissions](#permissions)
- [Quick start](#quick-start)
- [Documentation](#documentation)
- [Project structure](#project-structure)
- [Tech stack](#tech-stack)
- [Development commands](#development-commands)
- [Release notes](#release-notes)
- [Contributing](#contributing)
- [License](#license)
- [Support](#support)

## Platform support

| Platform | Status |
|---|---|
| Android | Supported. All four native method channels are implemented in Kotlin. Builds target SDK 36 with `minSdk` from Flutter (`flutter.minSdkVersion`, 24, that is Android 7.0, with Flutter 3.41.2). The v0.1.11 and v0.1.12 release notes list the devices those releases were tested on: RMX1801 (Android 10) and I2011 (Android 11). No later release notes list test devices. |
| iOS | Builds, but the Android-native features are unavailable: there is no background recording service, notification Stop, Picture-in-Picture, device status or gallery export. Recording needs the app in the foreground with the screen on. No iOS build has been released. See [docs/platform-integration.md](docs/platform-integration.md#ios-current-state). |
| Web, desktop | Not targeted. The repository has no web or desktop platform folders. |

Current limitations:

- On Android, recording is designed to continue with the screen off or the app in the background while the recording notification shows, but this has not yet been confirmed on a device. The **Keep screen on while recording** setting (on by default) is the fallback. Swiping MotoCam away from Recents still ends the recording, because the activity and the Flutter engine are destroyed.
- On iOS, the idle timer is not disabled while recording, so Auto-Lock interrupts the capture.
- Each segment roll loses about a second of footage.

The UI is portrait-only and always dark (Material 3). There is no localization; the `intl` package is used only for date formatting in the rides list.

## Key features

- **Segmented loop recording.** Segment length from 5 s to 10 min (default 5 min) and a loop of 6 to 48 unlocked segments per ride (default 24). When the loop is full, the ride's oldest unlocked segment is deleted. Locked segments and earlier rides are never deleted automatically. Resolution 480p to 4K, 24/30/60 FPS, optional audio, with automatic fallback to a lower resolution if the camera refuses the chosen one. The bitrate setting has no effect on Android, where the camera plugin ignores it. Recording does not start when free storage is too low for another segment, and a running ride stops and is saved when storage runs low.
- **Start preflight.** Every START runs a permission audit and a checklist (permissions, location services, camera readiness, media write access, plus warnings for the Android notification permission and battery-optimization exemption, a missing motion sensor, battery level and temperature).
- **Live telemetry.** Speed, ride duration, distance, battery and temperature tiles on the recording screen (battery and temperature on Android only).
- **Incident detection and locking.** While recording, gravity-removed acceleration at or above a sensitivity-dependent threshold (Low 4.5 g, Medium 3.5 g, High 2.8 g), sustained for at least 40 ms, locks the two previous segments and the current one. A LOCK button does the same manually.
- **Background recording support (Android).** While recording, a foreground service with an ongoing notification, a Stop action and a wake lock runs, and the app enters Picture-in-Picture automatically when the rider leaves it. While that service runs, the camera is kept open when the screen turns off or the app leaves the foreground, so recording is designed to continue (not yet confirmed on a device). The screen is kept on while recording unless the rider turns that off (see the limitations above and [docs/features.md](docs/features.md#picture-in-picture-and-screen-off-recording)).
- **Crash-safe ride files.** Once the first segment is saved, the ride's telemetry JSON is written as a checkpoint whenever a segment or lock is added and every 30 s, so a ride survives a crash or kill before STOP. A failed save can be retried.
- **Blackout mode.** Hides the preview behind a black screen while recording continues; hold for 2 s to exit.
- **Ride history and playback.** Rides grouped into Locked Clips and All Rides, plus video-only entries for videos without a ride file. Rides can be unlocked and deleted after a confirmation. Playback runs all segments as one timeline, marks missing segments and gaps on the seekbar, and shows a telemetry overlay, a speed graph with incident and lock markers, and a collapsible OpenStreetMap route map that loads tiles only after a one-time consent.
- **Integrity checks.** Each ride's telemetry file carries an unkeyed SHA-256 integrity check over its payload and every segment file. It detects accidental corruption and naive edits; it is not tamper-proof, because anyone who can rewrite the files can recompute the hashes. The rides list checks the ride data only and shows one of `INTEGRITY WARNING`, `SIMULATED GPS` (fixes from a mock location provider), `DATA UNMODIFIED` or `UNVERIFIED`, plus `VIDEOS VERIFIED` or `VIDEO CHECK FAILED` once the ride's segments were checked. Separate badges mark segment paths outside the ride's folder, which are quarantined and not played (`QUARANTINED n`), missing segment files (`INCOMPLETE`) and rides kept only as a checkpoint (`RECOVERED (INCOMPLETE)`). Opening a ride hashes its segment files one at a time in the background, starting with the segment about to play; leaving the screen stops the check, and results are kept in a ride index cache (which also spares the list from re-reading unchanged ride files), so an unchanged segment is not hashed again. Segments that fail the check still play and are marked on the seekbar; "Check videos again" re-hashes them all.
- **Gallery export (Android, opt-in).** Off by default. When the rider turns it on, locked segments are copied to the device gallery (`Movies/MotoCam/Recordings`) when recording stops. MotoCam never removes these copies. There is no manual export button.

Each feature, with its exact behaviour and the code behind it, is described in [docs/features.md](docs/features.md).

## Permissions

| Permission | When it is needed |
|---|---|
| Camera | Always; recording is blocked without it. |
| Microphone | Only while audio recording is on; then it is required. |
| Location (while the app is in use) | Always; recording is blocked without it, and location services must be on. The app never asks for background location. |
| Notifications | Android 13 and later. Recommended, for the recording notification and its Stop action. |
| Storage | Android 9 and lower, and only when gallery export is on. |
| Battery-optimization exemption | Optional. Android only, offered once after a saved ride behind a dialog the rider can decline. |

On Android the foreground service declares the types camera, microphone and location. On Android 11 and later it starts with only the types whose permissions are granted. The manifest is [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml), and the runtime flow is described in [docs/platform-integration.md](docs/platform-integration.md#runtime-permission-flow).

## Quick start

Prerequisites (details and troubleshooting in [docs/development.md](docs/development.md)):

- Flutter 3.41.2 stable (Dart 3.11.0) is the verified version. `pubspec.yaml` requires at least Flutter 3.41 and Dart 3.11.
- JDK 17 to 24 (Gradle 8.14.4 does not run on JDK 25 or later).
- Android SDK platform 36 and NDK 28.2.13676358 (pinned by the app; the `jni` plugin that path_provider_android pulls in requires the same one). Gradle installs CMake 3.22.1 on the first build.
- A physical Android device is recommended. Recording needs camera and location permission (plus microphone permission while audio recording is on) and location services turned on.

```sh
git clone https://github.com/Sarthak195/MotoCam.git
cd MotoCam
flutter pub get
flutter doctor --android-licenses   # accept the Android SDK licences
flutter run                         # debug build on the connected device
```

The first Android build takes several minutes (about six on the maintainer machine). Debug builds need no signing set-up. In Android Studio, open the repository root (not `android/`) and use the Flutter run configuration for `lib/main.dart`.

## Documentation

The developer documentation lives in [docs/](docs/). Start with [docs/README.md](docs/README.md), which indexes the documents, suggests a reading order and lists which document to update for each kind of change.

| Document | Covers |
|---|---|
| [docs/README.md](docs/README.md) | Documentation index, reading order, conventions and maintenance guide |
| [docs/architecture.md](docs/architecture.md) | Module map, providers and navigation, services and native bridges, startup and core flows, concurrency, error handling, glossary |
| [docs/features.md](docs/features.md) | Rider-facing features and the code behind each one, permissions, platform availability |
| [docs/recording-pipeline.md](docs/recording-pipeline.md) | Camera setup, recording state machine, segment rollover, stop flow, storage, locks, retention and free-space checks, background behaviour |
| [docs/telemetry.md](docs/telemetry.md) | GPS and accelerometer collection, speed and distance, incident detection, telemetry persistence |
| [docs/playback-and-history.md](docs/playback-and-history.md) | Ride discovery, rides list, multi-segment playback, timeline synthesis, route map |
| [docs/data-formats.md](docs/data-formats.md) | Storage locations, file naming, telemetry JSON schema, checkpoints, integrity envelope, quarantine, atomic writes |
| [docs/settings.md](docs/settings.md) | Every setting, its key, default and effect; how to add a setting |
| [docs/platform-integration.md](docs/platform-integration.md) | Method channels, foreground service, PiP, manifest permissions, runtime permission flow, iOS project state |
| [docs/development.md](docs/development.md) | Toolchain, setup, conventions, analysis, formatting, tests, CI, debugging, troubleshooting |
| [docs/release.md](docs/release.md) | Versioning, signing, release precheck, building, checksums, tagging, release notes |
| [docs/audits/2026-10-20-project-scan.md](docs/audits/2026-10-20-project-scan.md) | Whole-project scan of commit `a33a583`: 154 verified findings, with a status column for the fixes in the working tree |

## Project structure

```
MotoCam/
├── .github/                   CI workflow (ci.yml) and Dependabot configuration
├── android/                   Gradle project, manifest, Kotlin MainActivity and BackgroundRecordingService
├── ios/                       Xcode Runner project and Podfile (no native channel handlers)
├── lib/                       Dart source (see below)
├── test/                      Unit and widget tests (361 tests in 27 files)
├── docs/                      Developer documentation and audit reports
├── release-notes/             Per-release notes, v0.1.8.md to v0.1.13.md
├── scripts/                   release-security-precheck.ps1, generate-keystore.ps1
├── .gitattributes             Line-ending policy
├── analysis_options.yaml      Lints: flutter_lints plus seven stricter rules
├── pubspec.yaml               Package manifest (version 1.0.1+13)
└── pubspec.lock               Resolved dependency versions
```

```
lib/
├── main.dart                                   Entry point, error hooks, root MultiProvider, MaterialApp
├── core/
│   ├── providers/
│   │   └── app_settings_provider.dart          AppSettingsProvider: settings in SharedPreferences
│   ├── services/
│   │   ├── app_permission_service.dart         Runtime permission audit
│   │   ├── background_recording_service.dart   Android foreground-service bridge
│   │   ├── device_status_service.dart          Battery, temperature and thermal status (Android)
│   │   └── pip_service.dart                    Picture-in-Picture bridge
│   ├── ride_file/
│   │   ├── ride_integrity.dart                 Ride integrity envelope: build, re-seal, check
│   │   └── ride_telemetry_codec.dart           The one codec for the ride telemetry JSON
│   └── utils/
│       ├── format_utils.dart                   Shared elapsed-time format
│       ├── integrity_utils.dart                SHA-256 hashing, per-path locks, atomic telemetry writes
│       └── path_utils.dart                     Path normalization and containment checks
└── features/
    ├── camera/providers/
    │   ├── camera_init_status.dart             Camera init state and failure reasons
    │   ├── camera_provider.dart                Camera lifecycle, segments, locks, retention, gallery export
    │   └── recording_retention.dart            Pure loop-retention, LOCKED badge and orphan-sidecar rules
    ├── history/
    │   ├── models/
    │   │   ├── ride_history_loader.dart        Loads rides (and video-only rides) off the UI isolate, through the ride index
    │   │   ├── ride_index.dart                 Ride index cache and its one writer
    │   │   ├── ride_record.dart                Ride model, integrity verification, quarantine, lock state
    │   │   └── segment_verifier.dart           Per-segment, cancellable video checks stored in the index
    │   ├── rides_list_screen.dart              Ride History list
    │   ├── ride_playback_screen.dart           Multi-segment playback with telemetry
    │   └── widgets/
    │       ├── playback_seekbar_track_shape.dart  Seekbar track with ranges and markers
    │       ├── playback_timeline.dart          Pure playback timeline logic
    │       └── route_map_view.dart             flutter_map route on OpenStreetMap tiles
    ├── map/
    │   ├── map_licence.dart                    OpenStreetMap notice for the licence page
    │   ├── map_source_config.dart              Tile URL, attribution, user agent and zoom constants
    │   ├── route_points.dart                   GPS-fix filter and route downsampling
    │   └── widgets/
    │       ├── osm_attribution.dart            Tappable OpenStreetMap attribution
    │       └── static_map_viewer.dart          Tile-free CustomPaint route fallback
    ├── recording/
    │   ├── recording_screen.dart               Home screen and session coordinator
    │   ├── recording_screen_logic.dart         Pure helpers: stall and checkpoint trackers, lock notices, camera failure panel, button colours
    │   ├── start_preflight_evaluator.dart      Pure start checklist rows
    │   └── widgets/
    │       ├── recording_settings_sheet.dart   Settings form
    │       └── start_preflight_sheet.dart      Start checklist sheet
    └── telemetry/
        ├── models/telemetry_data.dart          One telemetry sample
        └── providers/telemetry_provider.dart   GPS, accelerometer, incidents, telemetry JSON
```

[docs/architecture.md](docs/architecture.md#module-map) describes each file and the dependencies between them.

## Tech stack

Versions are the ones resolved in `pubspec.lock`, and the toolchain the maintainer verified for the current `main`.

| Component | Package or tool | Version |
|---|---|---|
| Framework | Flutter (stable) | 3.41.2 |
| Language | Dart | 3.11.0 |
| State management | `provider` | 6.1.5+1 |
| Camera | `camera` | 0.12.0+2 |
| Location | `geolocator` | 14.1.2 |
| Accelerometer | `sensors_plus` | 7.1.1 |
| File locations | `path_provider` | 2.1.6 |
| Permissions | `permission_handler` | 12.0.3 |
| Date formatting | `intl` | 0.20.3 |
| Settings storage | `shared_preferences` | 2.5.6 |
| SHA-256 hashing | `crypto` | 3.0.7 |
| Video playback | `video_player` | 2.11.1 |
| Maps | `flutter_map` | 8.3.2 |
| Coordinates | `latlong2` | 0.9.1 |
| Opening links | `url_launcher` | 6.3.3 |
| Lints (dev) | `flutter_lints` | 6.0.0 |
| Android build | Gradle / Android Gradle Plugin / Kotlin | 8.14.4 / 8.11.1 / 2.2.20 |
| Android SDK | compileSdk / targetSdk / NDK / JVM target | 36 / 36 / 28.2.13676358 / 17 |

Map tiles come from `tile.openstreetmap.org`, so the route map needs a network connection.

## Development commands

| Task | Command |
|---|---|
| Static analysis | `flutter analyze` |
| Run all tests | `flutter test` |
| Tests with coverage | `flutter test --coverage` |
| Check formatting | `dart format --output=none --set-exit-if-changed lib test` |
| Format files | `dart format lib test` |
| Release security precheck | `pwsh ./scripts/release-security-precheck.ps1` (CI runs it with `-SkipTests -SkipAnalyze`) |
| Debug APK | `flutter build apk --debug` |
| Release APK | `flutter build apk --release` |

- `flutter analyze` is clean, all 361 tests pass and the tree is `dart format`-clean.
- CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs on pushes to `main` and on pull requests with Flutter 3.41.2. It runs `flutter pub get --enforce-lockfile`, `flutter analyze`, the precheck, `flutter test --coverage`, a debug APK build and the format check, and builds the iOS app for the simulator in a second job.
- The precheck mostly checks Android: the release signing config in `build.gradle.kts`, the manifest (no background location or all-files access, backups off, the signature-protected internal broadcast permission), that no credential or keystore files are tracked and that the Android assets folder is empty. It also checks the iOS `Info.plist` keys and the `ios/Podfile` permission macros, then runs `flutter analyze` and `flutter test` unless skipped. It fails when any step fails. It reads no signing credentials.
- Release builds need four signing values. Gradle reads them from the environment variables `MOTOCAM_KEYSTORE_FILE`, `MOTOCAM_KEYSTORE_PASSWORD`, `MOTOCAM_KEY_ALIAS` and `MOTOCAM_KEY_PASSWORD`, or from `android/key.properties` (copied from `android/key.properties.template`). Each environment variable wins over its file value, and a relative keystore path is resolved against `android/app/`. Gradle stops with `Release signing config missing: ...` (naming the missing values) or `Release keystore not found ...` only when a task that packages or signs a release artifact is about to run. Release builds use R8 minification and resource shrinking. See [docs/release.md](docs/release.md#signing-setup-android).

More commands, debugging tips and troubleshooting are in [docs/development.md](docs/development.md).

## Release notes

Release notes are in [release-notes/](release-notes/) (`v0.1.8.md` to `v0.1.13.md`; earlier releases have none). The latest is [v0.1.13](release-notes/v0.1.13.md). Release tags use a `v0.1.x` scheme, while `pubspec.yaml` is at `1.0.1+13` (Android versionName 1.0.1, versionCode 13). [docs/release.md](docs/release.md) explains the versioning, the release checklist, signing, the precheck and the changelog index.

## Contributing

1. Create a branch from `main`.
2. Make your change, and update the affected documents in `docs/` in the same change ([docs/README.md](docs/README.md#maintenance-guide) lists which ones).
3. Before opening a pull request, run:

   ```sh
   flutter analyze
   flutter test
   dart format lib test
   flutter build apk --debug
   ```

   If you changed Gradle files, the Android manifest, `Info.plist` or the `Podfile`, also run `pwsh ./scripts/release-security-precheck.ps1 -SkipTests -SkipAnalyze`.
4. Push the branch and open a pull request against `main`.

Use a short conventional-commit subject (for example `fix(recording): ...`). Never commit `android/key.properties` or keystore files; the `.gitignore` files exclude them.

## License

No license has been chosen for this project yet, so the repository includes no LICENSE file. Until one is added, default copyright applies: the code is publicly visible, but no license is granted to use, copy, modify or distribute it beyond what GitHub's terms of service allow for public repositories.

## Support

For bugs, feature requests or questions, open an issue at [github.com/Sarthak195/MotoCam/issues](https://github.com/Sarthak195/MotoCam/issues).
