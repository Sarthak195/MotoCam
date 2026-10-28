# Development guide

This guide covers setting up a machine, running and debugging MotoCam, and the checks the project uses today. It is for developers joining or maintaining the project. It describes the repository as it currently is, including the places where the tooling is incomplete.

## Contents

- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Running the app](#running-the-app)
- [Project conventions](#project-conventions)
- [Static analysis](#static-analysis)
- [Formatting](#formatting)
- [Testing](#testing)
- [Continuous integration](#continuous-integration)
- [Debugging tips](#debugging-tips)
- [Troubleshooting](#troubleshooting)
- [Contribution workflow](#contribution-workflow)
- [Related documents](#related-documents)

## Prerequisites

The versions below are the toolchain the maintainer uses to build, analyze and test `main`.

| Tool | Version | Notes |
|---|---|---|
| Flutter | 3.41.2 (stable) | Ships Dart 3.11.0. [pubspec.yaml](../pubspec.yaml) sets `sdk: ^3.11.0` and `flutter: ">=3.41.0"`, the same floor as the `sdks:` block of `pubspec.lock`. CI pins 3.41.2. |
| Java (JDK) | 17 to 24 | [build.gradle.kts](../android/app/build.gradle.kts) compiles Java and Kotlin for target 17, and CI uses Temurin 17. Gradle 8.14.4 runs only on JVMs up to 24; its compatibility page says 25 and later are not yet supported. |
| Android SDK | Platform 36 | `compileSdk = 36`, `targetSdk = 36`. `minSdk` is `flutter.minSdkVersion`, which is 24 (Android 7.0) in Flutter 3.41.2. |
| Android NDK | 28.2.13676358 | The app pins it with `ndkVersion` in build.gradle.kts, the same as Flutter 3.41.2's default. The `jni` plugin, a dependency of path_provider_android 2.3, requires this NDK, so the pin and the plugin agree and the build prints no NDK mismatch warning. |
| CMake | 3.22.1 | Gradle installs it automatically on the first build. |
| Gradle / AGP / Kotlin | 8.14.4 / 8.11.1 / 2.2.20 | Gradle comes from the wrapper ([gradle-wrapper.properties](../android/gradle/wrapper/gradle-wrapper.properties)); the Android Gradle plugin and the Kotlin Gradle plugin are set in [settings.gradle](../android/settings.gradle). No separate install is needed. |
| Xcode (iOS only) | 14 or newer | macOS only. Flutter 3.41.2 requires Xcode 14 and recommends 15; the project's deployment target is iOS 13.0. [ios/Podfile](../ios/Podfile) sets the `permission_handler` macros. The iOS app has no native method-channel handlers, so the Android-native features are missing; read [platform-integration.md](platform-integration.md) before working on iOS. |
| PowerShell (`pwsh`) | Any | Optional locally. Needed to run the two scripts in [scripts/](../scripts/). CI runs only the precheck script. |

The Gradle daemon is configured with an 8 GB heap (`org.gradle.jvmargs=-Xmx8G ...` in [gradle.properties](../android/gradle.properties)). Machines with less memory may need to lower it locally.

## Setup

```sh
git clone https://github.com/Sarthak195/MotoCam.git
cd MotoCam
flutter pub get --enforce-lockfile  # what CI runs; fails if pubspec.lock does not match pubspec.yaml
flutter doctor --android-licenses   # accept every SDK licence
flutter doctor                      # confirm Android toolchain and a device
```

- `flutter pub get` resolves the graph pinned in `pubspec.lock`: the 14 direct dependencies listed in [pubspec.yaml](../pubspec.yaml) (13 packages plus the Flutter SDK), 2 dev dependencies and 109 transitive packages. Dependabot proposes updates weekly (see [Continuous integration](#continuous-integration)).
- The Flutter tool writes the ignored file `android/local.properties`: `flutter pub get` sets `flutter.sdk` (and `sdk.dir` when it finds an Android SDK), and each Android build or run adds `flutter.versionName` and `flutter.versionCode` from pubspec. Gradle reads the version values from it; see [release.md](release.md).
- Install SDK platform 36 and NDK 28.2.13676358 with Android Studio's SDK Manager, or with `sdkmanager "platforms;android-36" "ndk;28.2.13676358"`.
- Debug and profile builds, debug app bundles and `flutter run` need no signing set-up. Any Gradle invocation that packages or signs a release artifact does, including a plain `assemble` or `build` (see [Troubleshooting](#troubleshooting)). Release signing is described in [release.md](release.md).
- [.gitattributes](../.gitattributes) sets `* text=auto eol=lf`: Git stores text files with LF line endings and checks them out with LF on every platform, including Windows, whatever `core.autocrlf` says. Only `.bat` and `.cmd` files use CRLF. Configure your editor to keep LF.

## Running the app

```sh
flutter devices          # list connected devices and emulators
flutter run              # debug build on the selected device
flutter run -d <id>      # pick a device explicitly
```

- The first `flutter build apk --debug` on the maintainer machine took about six minutes (348 s in the Gradle step), and Gradle installed CMake 3.22.1 automatically during it. On a clean machine the first build also downloads the Gradle distribution and the plugins' dependencies.
- **Built APKs.** [android/build.gradle](../android/build.gradle) sets `layout.buildDirectory` so that Gradle output goes to `<repo>/build/` (git-ignored) instead of `android/build/`. `flutter build apk --debug` writes `build/app/outputs/flutter-apk/app-debug.apk`. The debug APK is large, mostly because of the debug native libraries for three ABIs (arm64-v8a, armeabi-v7a and x86_64). Install a built APK with `flutter install --debug` (plain `flutter install` installs the release APK) or `adb install -r build/app/outputs/flutter-apk/app-debug.apk`. Release outputs are listed in [release.md](release.md#building-release-artifacts).
- **Android Studio:** open the repository root (not `android/`) with the Flutter and Dart plugins installed, then use the normal Run configuration for `lib/main.dart`. Open `android/` as a separate project only when you want Kotlin code assistance for [MainActivity.kt](../android/app/src/main/kotlin/com/example/motocam/MainActivity.kt) and [BackgroundRecordingService.kt](../android/app/src/main/kotlin/com/example/motocam/BackgroundRecordingService.kt).
- **Use a real device for most work.** Recording will not start without camera and location permission (and microphone permission when audio is on), or while system location services are off. Incident detection reads the linear-acceleration sensor (`userAccelerometerEventStream`) and falls back to the raw accelerometer (`accelerometerEventStream`) on devices without one; recording does not require either. An Android emulator works only if you configure a virtual or webcam-backed camera and feed it locations (Extended controls > Location, or `adb emu geo fix <longitude> <latitude>`). Accelerometer-driven incident detection is hard to exercise on an emulator.
- **Android-only features:** the foreground service, Picture-in-Picture, battery/thermal status, free-space checks, media scanning and gallery export are implemented only in Kotlin. On iOS the Dart wrappers are gated off or fail quietly. See [platform-integration.md](platform-integration.md).
- `flutter run --release` triggers the release signing gate (see [Troubleshooting](#troubleshooting)). Use `--profile` for performance work without signing material.

## Project conventions

### Folder structure

```
lib/
  main.dart                    entry point, root MultiProvider, MaterialApp
  core/
    providers/                 app-wide settings (AppSettingsProvider)
    services/                  wrappers around plugins and method channels
    ride_file/                 ride-file codec (ride_telemetry_codec, ride_integrity)
    utils/                     stateless helpers (path_utils, integrity_utils, format_utils)
  features/
    camera/                    providers/camera_provider.dart, providers/recording_retention.dart, providers/recordings_migration.dart
    history/                   models/ (ride_record.dart, ride_history_loader.dart, ride_index.dart,
                               segment_verifier.dart), *_screen.dart,
                               widgets/ (ride_playback_body and its playback_* parts, speed_graph_painter, route_map_view/route_map_panel, playback_timeline)
    map/                       map_source_config.dart, route_points.dart, widgets/
    recording/                 recording_screen.dart, recording_screen_logic.dart, widgets/
    telemetry/                 models/telemetry_data.dart, providers/
test/                          mostly mirrors lib/ paths (test/core/..., test/features/...)
android/app/src/main/kotlin/com/example/motocam/
                               MainActivity.kt, BackgroundRecordingService.kt
```

Pure logic sits in its own files so tests can reach it without widgets or plugins: segment retention and the LOCKED badge rule in `recording_retention.dart`, camera init failure reasons in `camera_init_status.dart`, the start checklist rows in `start_preflight_evaluator.dart`, the playback timeline in `playback_timeline.dart`, recording-screen helpers in `recording_screen_logic.dart`, and GPS-fix filtering in `route_points.dart`. [architecture.md](architecture.md) has the full module map and explains how the pieces interact.

### Providers versus services

- **Providers** are `ChangeNotifier`s that hold app state and are registered once in the `MultiProvider` in [main.dart](../lib/main.dart): `AppSettingsProvider`, `CameraProvider` and `TelemetryProvider`. Widgets read them with `package:provider`.
- **Services** in `lib/core/services` are plain classes with no `ChangeNotifier`. They wrap a plugin or a method channel. Instantiation is not uniform:
  - `BackgroundRecordingService.instance` and `PipService.instance` are singletons with private constructors.
  - `AppPermissionService` and `DeviceStatusService` have `const` constructors. The recording screen state in [recording_screen.dart](../lib/features/recording/recording_screen.dart) holds one of each as a field.
  - `TelemetryProvider` calls `Geolocator` directly, and so does the recording screen for its location-services check; there is no separate location service.
- **Utilities** in `lib/core/utils` are top-level functions. `path_utils` and `integrity_utils` are imported with a library prefix (`import '.../path_utils.dart' as path_utils;`, `as integrity_utils`), and so is the ride-file codec in `lib/core/ride_file` (`as ride_codec`); `format_utils` (`formatElapsed`) is imported without one.
- **Method channels** are named `com.example.motocam/<area>` and declared as `static const` fields on the class that uses them. The full list is in [platform-integration.md](platform-integration.md).

### Naming

- Files use `snake_case.dart`; screens end in `_screen.dart`, providers in `_provider.dart`, services in `_service.dart`.
- Private state classes follow the Flutter pattern `_XxxState`. Small private helper models stay in the screen file (for example `_PendingSeek` in [ride_playback_screen.dart](../lib/features/history/ride_playback_screen.dart)); painters and the widgets of a screen's body live in `widgets/` (for example `speed_graph_painter.dart`) so they can be tested.
- SharedPreferences keys are `static const` snake_case strings named `_xxxKey`. Thirteen are on `AppSettingsProvider`. The others are the two playback keys `_showRouteMapPrefKey` and `_onlineMapConsentPrefKey` in [ride_playback_screen.dart](../lib/features/history/ride_playback_screen.dart) and the public `BackgroundRecordingService.batteryOptimizationOfferedKey`. See [settings.md](settings.md).
- Test-only entry points are marked `@visibleForTesting`: `TelemetryProvider.updateLocationForTesting`, `updateAccelerometerForTesting`, `updateRawAccelerometerForTesting` feed inputs through the production handlers, and `TelemetryProvider.clearHistory` resets the ride statistics. Getters that only tests read (for example `TelemetryProvider.activeRideSamples`, `incidentCount`, `lastIncidentGForce`, `hasPendingPersist` and `mockLocationDetected`, `RideIntegrityReport.isVerified` and `contrastRatio`) are marked the same way. The static helper `TelemetryProvider.shouldAccumulateDistance`, and `CameraProvider.nearestSupportedFps` and `CameraProvider.galleryExportSummary`, are exposed for tests.

### Comments and dartdoc

- Every file under `lib/` has `///` dartdoc, including the screens and widgets. Coverage of individual members varies; the providers, `RideRecord`, `TelemetryData` and the utilities are the most fully documented.
- Eight files start with a `// lib/<path>.dart` header comment (for example [main.dart](../lib/main.dart) and [camera_provider.dart](../lib/features/camera/providers/camera_provider.dart)); the others do not. Neither form is required.
- New public classes and methods should follow the existing dartdoc style.

## Static analysis

```sh
flutter analyze
```

- [analysis_options.yaml](../analysis_options.yaml) includes `package:flutter_lints/flutter.yaml` (flutter_lints 6.0.0) and enables seven more rules under `linter.rules`: `cancel_subscriptions`, `close_sinks`, `unawaited_futures`, `discarded_futures`, `avoid_dynamic_calls`, `prefer_final_locals` and `always_declare_return_types`. `use_build_context_synchronously` is already part of flutter_lints.
- `avoid_slow_async_io` is deliberately not enabled. It asks for `existsSync`/`statSync`, which would move file IO back onto the UI isolate.
- With `unawaited_futures` and `discarded_futures` on, an intended fire-and-forget call is wrapped in `unawaited(...)` from `dart:async`.
- There is no `analyzer:` section, so there are no strict modes, excludes or severity overrides.
- `flutter analyze` reports "No issues found!", and CI runs it on every pull request and every push to `main`.
- Suppress a lint locally with `// ignore: <rule>` rather than editing the shared rule set.

## Formatting

```sh
dart format lib test                                        # rewrite files
dart format --output=none --set-exit-if-changed lib test    # check only (what CI runs)
```

- The tree is `dart format`-clean, and CI fails when the check reports a file that needs changes.
- The pubspec Dart SDK lower bound (`^3.11.0`) sets the package language version to 3.11, so `dart format` uses the "tall" style introduced in Dart 3.7. In that style the formatter adds and removes trailing commas itself.
- Run `dart format lib test` before committing.

## Testing

```sh
flutter test                                                         # all tests
flutter test test/features/telemetry/providers/telemetry_provider_test.dart
flutter test --plain-name "incident"                                 # by name substring
flutter test --coverage                                              # writes coverage/lcov.info
```

There are 569 tests in 43 files, and all pass. The table groups them by area.

| Area | Files | Tests | What it covers |
|---|---|---|---|
| Settings | [test/core/providers/](../test/core/providers/) | 21 | `AppSettingsProvider` loading defaults and stored values, legacy-key migration, clamping, preset ids, updates, the gallery-export opt-in and the storage budget (persisted, unknown values read as off). |
| Services | [test/core/services/](../test/core/services/) | 57 | `AppPermissionService` (required versus recommended permissions, no background location, legacy storage only with gallery export, iOS skips), `BackgroundRecordingService` (the one-time battery-exemption offer, START errors, notification Stop), `DeviceStatusService`, `PipService` and `RideSigningService` (replies, `MissingPluginException`, `PlatformException`, malformed replies, the timeout, the session key), with their method channels mocked; `SignedRideRegistry` (per-key ids, removal, a new key, a corrupt value) and `loadRideSignerContext`; `LegacyRecordingsAccess` over a mocked `legacy_recordings` channel (listing, a cancelled and a failed copy, deletes); `GalleryCopies` over a mocked `gallery` channel (per-URI statuses, unknown statuses, errors and a missing handler as failures, `existingUris`). |
| Utilities | [test/core/utils/](../test/core/utils/) | 18 | Canonical JSON hashing, the integrity envelope, atomic telemetry writes and per-path locking, temp-file pruning, path normalization and containment, `formatElapsed`. |
| Ride-file codec | [test/core/ride_file/](../test/core/ride_file/) | 40 | The pinned legacy public folder, the segment-list, span and summary rules, declared-path resolution (a sibling wins over an existing path elsewhere, a missing path in a same-named directory becomes a missing sibling, and stays one when a file is placed at the declared path, a path in the legacy public folder always maps to its sibling, other outside paths stay quarantined), and a writer-to-reader round trip (final save and restricted checkpoint) through the codec's writer path with real segment files. Envelope version 3 with a pointycastle P-256 key standing in for the phone's key ([test/support/test_signing_key.dart](../test/support/test_signing_key.dart)): what the payload hash covers, a valid and a high-S signature, a tampered payload (with and without a recomputed hash), a tampered or swapped signature, a wrong keyId, a missing signature, an unknown algorithm, version 4, malformed base64, DER and keys, the signer context (this phone, another key, key unknown, the downgrade check) and `sealAndSignRidePayload` falling back to version 2. |
| Camera | [test/features/camera/providers/](../test/features/camera/providers/) | 113 | `CameraProvider` resolution mapping, idle state (including releasing migration holds), FPS fallback and the gallery-export summary; `gallery_export.dart` with temporary directories and a fake native exporter (a queue written before a kill drained by a new store exactly once, no segment queued or copied twice, the same file name in two rides, relocation by file name from the queued path to the recordings root and the legacy roots, a gone file dropped, three attempts, the storage permission asked once per drain and never by the launch retry, a pause keeping the rest queued, draining only given keys, a source gone during the copy, forgetting links whose copy is gone, the Save to gallery summary); `recording_retention.dart` segment eviction (locked segments never evicted), pending-segment tracking, the LOCKED badge rule and orphan-sidecar detection (including the reader's `videoPath` and legacy-name fallbacks, top level only); `camera_init_status.dart` permission-to-failure mapping, including plugin exception codes; `recordings_migration.dart` with temporary directories (a signed, locked ride moved from each legacy root reads identically, lone videos and ignored files, an unlocked ride without videos kept, collisions of the same and another size, the free-space stop, a ride checked as a whole when its first rename fails, renames from other roots continuing after a low-storage stop (also after a kill later in that run) and a later run waiting for room, the one-shot snapshot (a file placed after a completed run or after a low-storage stop is not moved, a fresh install is done at once), a moved ride reading the same with a file placed at its old path, an oversized ride JSON moved undecoded, a ride split by a failed copy hidden and finished by the next run, a pause while planning, pause mid-copy and resume, a kill at each fault point on the rename and copy paths, a truncated copy never deleting the source, the sweepers and the history scan run at every fault point, the controller); `storage_budget.dart` selection (off, oldest first, whole rides, locked and quarantined rides excluded, the current session excluded by id and by its segment paths, files written since the session started, orphan videos and unreadable files counted, legacy-root and nested files ignored, an unattainable budget), the notice text and the recordings-root scan; plus the migration banner in [test/features/history/recordings_migration_banner_test.dart](../test/features/history/recordings_migration_banner_test.dart). |
| History models | [test/features/history/models/](../test/features/history/models/) | 104 | Golden tests over the fixtures in [test/fixtures/ride_files/](../test/fixtures/ride_files/) (payload hashes, read results, integrity reports and lock-state rewrites recorded before the codec existed; never regenerate them), also with three fixtures' bare names rewritten to existing absolute paths, and those three moved byte for byte to a same-named directory while the declared files still exist; `RideRecord.fromTelemetryFile` integrity results, quarantine of untrusted paths, relocation of stale absolute paths, lock-state changes, incidents, sample interpolation and sample-less records (`loadSamples: false`, `loadSamples`, also through `Isolate.run`); `ride_history_loader.dart` loading on a background isolate and finding orphan videos; the ride index (hit without reading the file, miss, stale size, modification or change time through an injected stat source, a vanished segment or ride file, corrupt and other-format files, the JSON round trip, a populated index sent into an isolate, the loader never writing, the one writer with concurrent updates, adoption, temp-file pruning and segment-hash pruning); `SegmentVerifier` (check order, cancellation after the segment in flight, persisted results reused after a restart and re-hashed when the stamp or expected hash changes, `ignoreCache`, missing and unreadable files, with a counting fake hasher), the history video-check state and text, and `setLockState` reusing stored results while still refusing a changed segment. Signed rides in history: who signed derived for decoded and cached rides (also with the key unknown and after a new key), the format 2 index, `signature-removed` for a stripped or re-signed registered ride, playback's re-read keeping the context, `setLockState` re-signing, refusing (file untouched) and re-sealing foreign rides as version 2 with a fake signer, and the signature notices. |
| History services | [test/features/history/services/](../test/features/history/services/) | 31 | `deleteRideFiles` (trusted files deleted with the JSON last, the index entry and the registration dropped, quarantined and out-of-root paths kept, a copy with another ride's id leaving it registered, video-only rides, the deleted ride's gallery links and queued exports dropped and another ride's kept); the gallery-link store (keys, a round trip through a new store, corrupt, foreign and missing files read as empty, malformed entries skipped and entries re-keyed, `galleryKeysOfRide` never listing the JSON or a quarantined path); `removeGalleryCopies` with fake channel calls (deleted and missing count as removed, consent asked in one prompt, a declined prompt keeping the links, Android 9 with the storage permission granted and denied, a newer link of the same segment kept) and its summary; `LegacyRideImporter` against a fake document source backed by a temporary "public" folder (rides and lone videos imported with the JSON last and byte for byte, an imported ride reading the same with and without its originals and with the real public path, collisions by name and size and by JSON bytes, a size mismatch, a failed copy, a gallery copy already in private storage, an unlocked ride without videos, a pause mid-copy and roll-forward, the free-space stop, deleting originals JSON first, the controller). |
| Playback | [test/features/history/playback/](../test/features/history/playback/) | 52 | The playback timeline (effective timeline, missing and uncovered ranges, segment lookup, markers, clamping, nearest sample, speed-graph gestures and pages, integrity descriptions), `PlaybackPosition` and its sample listenable, the seekbar track shape, `RouteMapView` keeping its layers while the marker moves, and `RidePlaybackBody` pumped with a `ValueNotifier` position (rebuild scope, speed-graph curve and cursor, collapsed map, fullscreen, callbacks). These files test code in `lib/features/history/widgets/`. |
| Map | [test/features/map/](../test/features/map/) | 8 | GPS-fix filtering and downsampling in `route_points.dart`, the `StaticMapViewer` "No GPS fix" state and the OpenStreetMap attribution layer. |
| Recording | [test/features/recording/](../test/features/recording/) | 78 | `recording_screen_logic.dart`: the background-stall tracker, the ride-checkpoint tracker, lock notices, elapsed-time formatting, button contrast and the initial FPS choice, the preview mode and the camera failure panel text; `startPreflightNeedsSheet` from `start_preflight_sheet.dart`; every row of `StartPreflightEvaluator`. |
| Telemetry | [test/features/telemetry/](../test/features/telemetry/) | 45 | `TelemetryData` JSON (UTC timestamps, lazy timestamp parsing also across an isolate, lenient parsing, fix flags) and `TelemetryProvider` (ride start, fix tracking, distance gating, mock-location flags, incident detection on both accelerometer paths, sealed saves, checkpoints, a checkpoint followed by a longer final save read back verified, a signed final save (checkpoints unsigned, ride registered) and a failed signature saved as version 2, and failed-save retry). |
| App | [test/widget_test.dart](../test/widget_test.dart) | 1 | Builds `MotoCamApp` and checks the dark Material 3 theme, the recording screen and that stored settings are loaded. |

- Tests that touch method channels mock them with `setMockMethodCallHandler` on the test binding's `defaultBinaryMessenger`. Tests that write files use temporary directories.
- The screens are not tested beyond the single app-level widget test (the playback body widgets are, see the Playback row), and there are no tests for the Kotlin code (the ride signing key in `RideSigner.kt` included; its Dart side is tested against a mocked channel). The iOS `RunnerTests` target contains only an empty `testExample`, and nothing runs it.
- CI runs `flutter test --coverage`, but the report is not uploaded and there is no coverage threshold. `/coverage/` is ignored by the root [.gitignore](../.gitignore).

## Continuous integration

[.github/workflows/ci.yml](../.github/workflows/ci.yml) defines one workflow, `CI`, with two jobs, `validate` and `ios`.

| Setting | Value |
|---|---|
| Triggers | `push` to `main`, and every `pull_request`. A pull request therefore runs once, not once for the push and once for the PR. |
| Permissions | `contents: read` for the workflow token. |
| Concurrency | Group `ci-<workflow>-<ref>` with `cancel-in-progress: true`, so a new push to the same branch or PR cancels the run still in progress. |
| Flutter version | `env.FLUTTER_VERSION: 3.41.2`, passed to `subosito/flutter-action@v2` as `flutter-version` (channel `stable`, `cache: true`) in both jobs. |
| Timeouts | 45 minutes per job. |

The `validate` job runs on `ubuntu-latest`:

| Step | What it runs |
|---|---|
| Checkout | `actions/checkout@v5` |
| Set up Java | `actions/setup-java@v5`, Temurin 17 |
| Set up Flutter | `subosito/flutter-action@v2` with Flutter 3.41.2 |
| Install dependencies | `flutter pub get --enforce-lockfile` |
| Run analyzer | `flutter analyze` |
| Run release security precheck | `./scripts/release-security-precheck.ps1 -SkipTests -SkipAnalyze` under `pwsh`. With both skip flags it runs only the file checks on the Gradle script, the manifest, the backup rules, tracked credential files, Android assets, `Info.plist` and the Podfile; see [release.md](release.md#release-security-precheck). |
| Run tests | `flutter test --coverage` |
| Build Android debug APK | `flutter build apk --debug`. This compiles the Kotlin code and the Gradle scripts and needs no signing secrets. |
| Check formatting | `dart format --output=none --set-exit-if-changed lib test`. It runs last, so a formatting failure does not hide analyzer, test or build results. |

The `ios` job runs on `macos-latest`: checkout, Flutter 3.41.2, `flutter pub get --enforce-lockfile`, then `flutter build ios --simulator --no-codesign`.

CI does **not** build a release or signed APK or app bundle, run Gradle or Android lint, run the `RunnerTests` target, enforce a coverage threshold or run anything on a device.

[.github/dependabot.yml](../.github/dependabot.yml) opens weekly update pull requests for the `pub` packages (at most five open at a time) and for the GitHub Actions used by the workflow. CI validates each one like any other pull request.

## Debugging tips

### Logs

- Dart logging uses `debugPrint`, which appears in logcat under the tag `flutter`. In release builds [main.dart](../lib/main.dart) replaces `debugPrint` with a no-op, so only messages printed with `debugPrintSynchronously` reach the log there.
- `CameraProvider._log` prefixes its messages with `[MotoCam]` and prints only when `enableDebugLogging` is true. main.dart sets it to `kDebugMode`, so these verbose logs appear in debug builds only. `CameraProvider._logError` also uses the `[MotoCam]` prefix but prints in every build mode.
- `FlutterError.onError` keeps Flutter's default reporting in debug and profile builds; in release builds it logs the error and stack itself and skips errors marked as silent. `PlatformDispatcher.instance.onError` logs uncaught asynchronous errors in every build mode and keeps the app running.
- The Kotlin code logs only start failures, with `android.util.Log.e`, under the tags `MotoCamRecordingService` and `MotoCam`.

```sh
flutter logs                                  # Dart output from the running app
adb logcat -s flutter                         # same, via adb
adb logcat -s flutter | grep "\[MotoCam\]"    # camera pipeline only
adb logcat | grep -i motocam                  # include system and native messages about the package
```

### Exercising features quickly

- In the settings sheet, pick **Segment length** "5 sec per segment" and **Loop buffer size** "6 segments" to see segment rollover, per-session loop deletion (from the seventh finalized unlocked segment, after roughly 35 s of recording) and multi-segment playback in a short session. Locked segments do not count against the loop and are never deleted automatically.
- The **LOCK** button makes the same `CameraProvider.markIncident` call as an automatically detected incident (reason `manual-emergency` instead of `auto-crash`). Use it to exercise locking, the Locked Clips section, unlocking and, on Android with **Copy locked clips to gallery** turned on in settings (off by default), gallery export, without producing a real incident. The detection logic itself is easiest to drive from a test through `TelemetryProvider.updateAccelerometerForTesting`, as [telemetry_provider_test.dart](../test/features/telemetry/providers/telemetry_provider_test.dart) does.

### Pulling recordings and telemetry off a device (Android)

On Android, `CameraProvider._setupRecordingsDirectory` uses a `MotoCam Recordings` folder in the app's private files directory (`getApplicationSupportDirectory()`, `/data/user/0/com.example.motocam/files`) and writes a `.nomedia` marker into it. Finished segments are renamed into it (copied only when a rename is not possible; logcat says `Moved segment into persistent directory` or `Copied segment into persistent directory` in debug builds) and keep the camera plugin's file name (`REC<digits>.mp4` on Android). `TelemetryProvider` writes each ride's `ride_<rideSessionId>.telemetry.json` into the ride's storage directory, normally the same flat folder. The folder is private, so only `run-as` on a debug build can read it. [data-formats.md](data-formats.md) documents the naming rules, the legacy roots and their migration (journal in `files/ride_migration/`), the import from the old public folder (journal in `files/ride_import/`), and the export folder.

```sh
adb shell run-as com.example.motocam ls -l "files/MotoCam Recordings/"
adb exec-out run-as com.example.motocam cat "files/MotoCam Recordings/ride_<id>.telemetry.json" > ride.json
adb exec-out run-as com.example.motocam cat "files/MotoCam Recordings/REC<digits>.mp4" > segment.mp4
adb exec-out run-as com.example.motocam cat files/ride_migration/migration_journal.json

# Rides of earlier builds, until the migration has moved them:
adb shell ls "/sdcard/Android/data/com.example.motocam/files/MotoCam Recordings/"
```

The manifest sets `android:allowBackup="false"`, so `adb backup` does not capture app data. Its backup and data-extraction rule files also exclude the `root`, `file` and `external` domains (the settings, the recordings, the migration journal, the ride index and the legacy root) from backup and device transfer.

### Inspecting SharedPreferences (Android, debug builds)

`shared_preferences` stores values in `shared_prefs/FlutterSharedPreferences.xml` inside the app's private data directory, with every key prefixed `flutter.` (for example `flutter.recording_fps`).

```sh
adb shell run-as com.example.motocam cat shared_prefs/FlutterSharedPreferences.xml
adb shell pm clear com.example.motocam        # reset all app data, including settings
```

[settings.md](settings.md) lists every key, its type and its default.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `flutter doctor` reports unaccepted Android licences, or Gradle stops with a licence error | Run `flutter doctor --android-licenses` and accept all. |
| Gradle cannot find NDK 28.2.13676358 or SDK platform 36 | Install them in the SDK Manager, or with `sdkmanager "ndk;28.2.13676358" "platforms;android-36"`. Do not change `ndkVersion` in build.gradle.kts to work around it. |
| `flutter.sdk not set in local.properties` | [settings.gradle](../android/settings.gradle) asserts on this key. Run `flutter pub get` from the repository root (not from `android/`) so the Flutter tool writes `android/local.properties`, then build again. |
| `Release signing config missing: <values>. Provide them in android/key.properties or through the environment variables MOTOCAM_KEYSTORE_FILE, MOTOCAM_KEYSTORE_PASSWORD, MOTOCAM_KEY_ALIAS and MOTOCAM_KEY_PASSWORD.` | build.gradle.kts throws this when the task graph contains a task of `:app` that packages or signs a release artifact (`packageRelease`, `validateSigningRelease`, `signReleaseBundle`, `packageReleaseUniversalApk`, or the same with a flavor name) and one of the four signing values is missing. The message names the missing values. This includes `flutter run --release`, `flutter build apk --release`, `flutter build appbundle --release`, and plain `./gradlew assemble` or `build`. Debug and profile builds, `flutter build appbundle --debug`, `lintRelease` and `testReleaseUnitTest` are not gated. Use a debug or profile build, or set up signing as described in [release.md](release.md#signing-setup-android). |
| `Release keystore not found at <path>. A relative storeFile/MOTOCAM_KEYSTORE_FILE path is resolved against android/app/.` | The four values are set, but the keystore file does not exist. A relative path is resolved against `android/app/`, so the template's default `../release.keystore` means `android/release.keystore`, where [generate-keystore.ps1](../scripts/generate-keystore.ps1) writes it. Use a path relative to `android/app/` or an absolute path. |
| Camera preview stays black, or recording refuses to start | Check permissions in system Settings > Apps > MotoCam. Camera initialization in `CameraProvider` stops if camera permission is denied, or microphone permission while audio is enabled; the screen then shows a camera-unavailable panel that names the reason, with Retry and Open Settings. Before recording, `AppPermissionService.ensureRequiredPermissions` requires camera, location (while in use) and, when audio is enabled, microphone. On Android it also asks for notifications, and on Android 9 and lower for storage when gallery export is turned on; these are recommended, not required. The app never requests background location. It does not request the battery-optimization exemption automatically; the recording screen offers it once, behind a dialog the rider can decline. Recording also refuses to start while system location services are off. A permanently denied permission can only be re-enabled from system settings. For testing, `adb shell pm revoke com.example.motocam android.permission.CAMERA` (or another permission) revokes one grant, and `adb shell pm clear com.example.motocam` resets all app data and permissions. |
| Recording stops when the screen locks or times out, or when you leave the app (Android) | Screen-off capture relies on the camera lifecycle hold, which is engaged only when the foreground service started (check for the recording notification and for the "Background protection unavailable" SnackBar at START). It has not yet been confirmed on a device. Keep **Keep screen on while recording** on (the default) as the fallback. Swiping the app away from Recents always ends the recording. See [platform-integration.md](platform-integration.md#camera-lifecycle-hold). |
| Recording stops when the screen locks (iOS) | Known limitation. The app does not disable the idle timer while recording, so iOS Auto-Lock interrupts the capture session. |
| Permission prompts never appear on iOS | `permission_handler` compiles out every permission whose macro is not set, and then reports it as permanently denied. [ios/Podfile](../ios/Podfile) sets `PERMISSION_CAMERA=1`, `PERMISSION_MICROPHONE=1` and `PERMISSION_LOCATION_WHENINUSE=1` in its `post_install` hook. Run `pod install` (or a Flutter iOS build) again after changing it. See [platform-integration.md](platform-integration.md). |
| CI fails while it passes locally | CI uses Flutter 3.41.2 and Temurin 17, runs `flutter pub get --enforce-lockfile` (which fails when `pubspec.lock` does not match `pubspec.yaml`), builds a debug APK and checks formatting. Compare `flutter --version` and `java -version` in the CI log with your local versions, commit an updated `pubspec.lock` with any pubspec change, and run `dart format lib test`. |

## Contribution workflow

This section describes how work has actually been done in the repository's history; there is no written contribution policy.

- **Branches.** The remote has `main` and two personal branches, `Sarthak` and `samaksh`. All twelve GitHub pull requests (#1 to #12) were merged with merge commits. Up to v0.1.5, most work reached `main` through PRs from `Sarthak`. PRs #2, #8 and #11 went the other way, from `main` into a personal branch, to bring it up to date. Since then, almost everything has been committed directly to `main` without a PR, including the tagged commits for v0.1.6 to v0.1.12 and the commits cd39097, 8efaf72 and a33a583. The only later PR that added new commits is #10 (app icons and dependencies from `samaksh`). In total, 20 of the 37 non-merge commits on `main` up to a33a583 were committed to it directly. Both personal branches are behind `main`; `samaksh` also carries one app-icon commit that is not on `main`.
- **Commit messages.** The style is mixed. Many commits use conventional-commit prefixes, for example `feat(playback): ...`, `fix(recording): ...`, `docs(release): ...`, `chore(release): ...`, `refactor: ...` and `release: v0.1.9 ...`. Others use a version prefix (`v0.1.12: ...`), and several commits, such as 8efaf72, have pasted `git status` output as their message. For new work, use a short conventional-commit subject that says what changed.
- **Before opening a PR**, run what CI's `validate` job runs:

  ```sh
  flutter analyze
  flutter test
  flutter build apk --debug
  dart format --output=none --set-exit-if-changed lib test
  pwsh ./scripts/release-security-precheck.ps1 -SkipTests -SkipAnalyze   # if you touched Gradle, the manifest, Info.plist or the Podfile
  ```

- **Versions and tags.** `pubspec.yaml` is at `1.0.1+13`, while tags follow a separate `v0.1.x` scheme (the first three are uppercase `V0.1.0` to `V0.1.2`). Tagging and release notes are covered in [release.md](release.md).
- **License.** The repository has no LICENSE file and no license has been chosen yet. Keep this in mind before reusing code from or contributing code to the project.
- **Documentation.** If a change alters behaviour described in `docs/`, update the relevant document in the same PR. [docs/README.md](README.md) explains how the documentation set is organized.

## Related documents

- [architecture.md](architecture.md): module map, state management and core flows
- [platform-integration.md](platform-integration.md): method channels, Android manifest and the iOS project
- [release.md](release.md): signing, release builds, the precheck script and release notes
- [settings.md](settings.md): every SharedPreferences key
- [data-formats.md](data-formats.md): storage locations and file formats
- [recording-pipeline.md](recording-pipeline.md), [telemetry.md](telemetry.md), [playback-and-history.md](playback-and-history.md): subsystem deep dives
