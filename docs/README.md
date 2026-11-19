# MotoCam documentation

This folder holds the developer documentation for MotoCam, a Flutter motorcycle dashcam: segmented video recording, GPS and accelerometer telemetry, incident detection, ride history with multi-segment playback and a route map, and SHA-256 integrity envelopes. Android is the supported platform. The project overview, quick start and tech stack are in the [root README](../README.md).

Every document describes the code as it is today, including behaviour that may not be intended. When the code changes, the documents change with it (see the [maintenance guide](#maintenance-guide)).

## Contents

- [Document index](#document-index)
- [Audit reports](#audit-reports)
- [Suggested reading order](#suggested-reading-order)
- [Documentation conventions](#documentation-conventions)
- [Maintenance guide](#maintenance-guide)

## Document index

| Document | What is inside | Who should read it |
|---|---|---|
| [architecture.md](architecture.md) | What the app is and its current recording limitations, the module map of every file in `lib/` and the two Kotlin files, provider wiring in `main.dart` and navigation, the services and method-channel summary, the startup sequence, the recording and review flows, the concurrency model (including the background-isolate jobs), error handling as practised, repository layout and a glossary | Everyone, first. Anyone deciding where new code belongs |
| [features.md](features.md) | Rider-facing behaviour and the code behind it: the camera-unavailable state, start flow and preflight checks, stop and recording faults, the live HUD, incident locks, blackout mode, PiP and screen-off recording, storage and retention, the rides list, playback and the route map, integrity statuses, the opt-in gallery export, a settings overview, permissions and a per-platform availability table | Everyone. Testers, reviewers and anyone answering "what happens when the rider does X" |
| [recording-pipeline.md](recording-pipeline.md) | `CameraProvider` in depth: public surface, camera initialization and fallback, the recording state machine, start, segment rollover and stop, storage layout and file naming, incident locks, retention and free-space checks, lifecycle handling and the foreground service, error handling and recovery, and current constraints | Anyone changing `CameraProvider`, `RecordingScreen` or retention |
| [telemetry.md](telemetry.md) | `TelemetryProvider` in depth: GPS and accelerometer sources and their start conditions, the provider lifecycle, the `TelemetryData` sample model, speed and distance filtering, incident thresholds and what an incident triggers, persistence, memory bounds and UI throttling, device status and test coverage | Anyone changing sensors, speed or distance, incident detection or the telemetry write path |
| [playback-and-history.md](playback-and-history.md) | Ride discovery and loading, the rides list and its actions, integrity verification on open, the multi-segment playback engine, effective timeline synthesis, missing segments and the seekbar track, telemetry sync, the route map (`RouteMapView`, `StaticMapViewer`, `MapSourceConfig`) and what each ride action does on disk | Anyone changing `RidesListScreen`, `RidePlaybackScreen`, `RideRecord`, the playback timeline or the map widgets |
| [data-formats.md](data-formats.md) | Every file the app writes: storage locations, directory layout and naming, the file inventory, the ride telemetry JSON schema, checkpoints and the final save, the integrity envelope, its verification procedure and its limits, path scope and quarantine, the atomic-write procedure and backward compatibility | Anyone reading or writing ride files, changing the JSON or envelope, or building test fixtures |
| [settings.md](settings.md) | `AppSettingsProvider`: every setting with its SharedPreferences key, default and normalization, where each setting takes effect, the settings sheet and save flow, legacy keys and migration, other persisted preferences, and how to add a new setting | Anyone adding or changing a setting |
| [platform-integration.md](platform-integration.md) | The seven Android method channels and their contracts (including the ride signing key, the old-folder access and the gallery copies), the foreground service, PiP, the battery-optimization exemption, media scanning, gallery export and the removal of gallery copies, battery and thermal status, the Android manifest permission matrix, the runtime permission flow, and how to add a new method channel | Anyone touching Kotlin, the manifest, permissions, or a method channel |
| [development.md](development.md) | Toolchain prerequisites with verified versions, setup, running on a device, project conventions, static analysis, formatting, testing, CI, debugging tips (logs, exercising features in a short session, pulling recordings, inspecting SharedPreferences), troubleshooting and the contribution workflow | New contributors, first. Anyone setting up a machine or debugging the build |
| [release.md](release.md) | The release checklist, versioning as practised (pubspec versus tags), signing of published APKs, Android signing setup and the release-build guard, the keystore script, the application ID, the release security precheck, building and checksumming artifacts, tagging and publishing, the release-notes template, and a changelog index | The maintainer cutting a release; anyone changing Gradle signing, the precheck or CI |

Related files outside this folder:

- [../README.md](../README.md): project overview, platform support and limitations, permissions, quick start, tech stack and development commands.
- [../release-notes/](../release-notes/): per-release notes, `v0.1.8.md` to `v0.1.13.md`. [release.md](release.md) indexes them.

## Audit reports

| Report | What is inside |
|---|---|
| [audits/2026-10-20-project-scan.md](audits/2026-10-20-project-scan.md) | A whole-project scan of commit `a33a583`: 154 verified findings across ten scan dimensions (recording-path correctness; history, playback and telemetry correctness; security and privacy; Android platform and Play policy; iOS platform and parity; performance and battery; docs versus code; maintainability, tests and CI; dependencies and toolchain; UX, accessibility and rider safety), each with its severity, evidence and recommendation, and a Status column (fixed, fixed (docs), partially fixed, deferred or owner decision) for the fixes in the working tree |

The report is generated and is a snapshot of that commit; do not edit it by hand. The documents above describe the current code.

## Suggested reading order

For a developer new to the project:

1. [development.md](development.md): get a machine set up and the app running on a device. The first Android build takes several minutes.
2. [architecture.md](architecture.md): learn the module map, the three providers and how `RecordingScreen` coordinates them.
3. [features.md](features.md): see what the rider experiences, with links into the code for each feature.
4. [recording-pipeline.md](recording-pipeline.md): the recording core.
5. [telemetry.md](telemetry.md): sensors, speed, incidents and the telemetry write path.
6. [playback-and-history.md](playback-and-history.md): the read side of a ride.
7. [data-formats.md](data-formats.md): the ride file format both sides depend on.
8. [settings.md](settings.md): the persisted settings.
9. [platform-integration.md](platform-integration.md): native Android code and permissions.
10. [release.md](release.md): only when you need to sign or publish a build.

Steps 4 to 9 are reference material. Read the one that matches the area you are about to change.

## Documentation conventions

The existing documents follow these rules. Keep to them when editing or adding a document.

- **Link files relatively, name symbols in code style.** Link to source files with relative paths from `docs/` (for example [camera_provider.dart](../lib/features/camera/providers/camera_provider.dart)) and to other documents by file name (for example [settings.md](settings.md#settings-table)). Refer to classes, methods, fields and keys in backticks: `CameraProvider.stopRecording`, `_rollSegmentIfNeeded`, `recording_fps`.
- **No line numbers.** Line numbers go stale with every edit. Point at a file plus a symbol name instead; a reader can search for the symbol.
- **Document current behaviour.** Describe what the code does today, not what it was meant to do or will do after a planned fix. Where behaviour looks unintended, say so plainly and factually (for example "the SnackBar appears whether or not the write succeeded"). Do not describe planned features as if they exist.
- **Verify before writing.** Every concrete fact (a default, a threshold, a key name, a version, a path, a command) should come from the source, `pubspec.lock`, the build files or a command you ran. When a fact depends on a toolchain version, name the version.
- **Use mermaid for flows.** Sequences and decision flows are drawn as fenced `mermaid` blocks (`flowchart` or `sequenceDiagram`), which GitHub renders. Every document except development.md and this index has at least one. Keep labels short and use the real symbol names.
- **Tables for reference data.** Settings, permissions, channels, thresholds, files and commands go in tables, so that a reader can scan them and a reviewer can check each row.
- **Platform scope.** MotoCam targets Android only (iOS was removed from scope on 2026-11-19 and the `ios/` folder deleted; it can be restored from git history).
- **Structure.** Each document starts with a level-1 title and a short paragraph saying what it covers, then a Contents list for longer documents, and ends with a Related documents section where it fits.
- **Plain text.** No emojis and no badges.

## Maintenance guide

Update documentation in the same pull request as the code change. Use this table to find the documents a change affects.

| Kind of code change | Update these documents |
|---|---|
| New, removed or changed setting (key, default, options, normalization) | [settings.md](settings.md) (settings table and where it takes effect), [features.md](features.md#settings-overview) |
| New or changed method channel, method or argument (Dart or Kotlin) | [platform-integration.md](platform-integration.md) (method-channel reference), [architecture.md](architecture.md#services-and-native-bridges) (services table) |
| New or changed Android permission, manifest entry, service or receiver | [platform-integration.md](platform-integration.md) (permission matrix and runtime permission flow), [features.md](features.md#permissions), the permissions table in the [root README](../README.md); [release.md](release.md) if the precheck must change |
| Change to the runtime permission audit (`AppPermissionService`) or the start preflight checks | [features.md](features.md#preflight-checks), [platform-integration.md](platform-integration.md#runtime-permission-flow), [development.md](development.md#troubleshooting) if a symptom changes |
| Telemetry JSON field, integrity envelope, file naming or storage location change | [data-formats.md](data-formats.md) (schema, envelope, backward compatibility); [playback-and-history.md](playback-and-history.md) if the read side changes; [telemetry.md](telemetry.md#persistence) if the write side changes |
| Segment rollover, stop flow, stall recovery, lifecycle or foreground-service behaviour | [recording-pipeline.md](recording-pipeline.md), [features.md](features.md#recording) |
| Retention, loop deletion, incident locks or gallery export | [recording-pipeline.md](recording-pipeline.md#incident-locks-and-retention), [features.md](features.md#storage-and-retention), [data-formats.md](data-formats.md) if files on disk change |
| GPS settings, speed or distance filtering, incident thresholds or sampling interval | [telemetry.md](telemetry.md), [features.md](features.md#incident-detection-and-segment-locking) |
| Rides list, playback engine, timeline, markers or route map | [playback-and-history.md](playback-and-history.md), [features.md](features.md#playback) |
| Map tile source, attribution or user agent (`MapSourceConfig`) | [playback-and-history.md](playback-and-history.md#route-map) |
| New, moved, renamed or deleted file under `lib/` | [architecture.md](architecture.md#module-map) (module map and dependency direction), the `lib/` tree in the [root README](../README.md), [development.md](development.md#folder-structure) if the folder layout changes, and every other document that names or links the file (search `docs/` for the file name) |
| New or changed provider, or a change to provider wiring in `main.dart` | [architecture.md](architecture.md#state-management) |
| New dependency, dependency upgrade or toolchain bump (Flutter, Dart, Gradle, AGP, Kotlin, NDK, SDK level) | Tech stack in the [root README](../README.md), [development.md](development.md#prerequisites) |
| Gradle build, signing, ProGuard or the release precheck script | [release.md](release.md), [development.md](development.md#troubleshooting) |
| CI workflow (`.github/workflows/ci.yml`), lint rules or formatting policy | [development.md](development.md) (static analysis, formatting, CI), [release.md](release.md) if the precheck invocation changes |
| Tests added or removed | [development.md](development.md#testing), the test counts in [architecture.md](architecture.md#repository-layout) and the [root README](../README.md) (project structure and development commands), plus the test coverage section of [telemetry.md](telemetry.md#test-coverage) for telemetry tests |
| Version bump, new tag or new release notes | [release.md](release.md) (versioning, tags table and changelog index), the release-notes range in this index and in [architecture.md](architecture.md#repository-layout), and the [root README](../README.md) (project structure and release notes) |
| New user-facing feature | [features.md](features.md), the deep-dive document for its area, key features in the [root README](../README.md) |
| New document in `docs/` | This index (document table, reading order, maintenance table) and the documentation table in the [root README](../README.md) |
| License chosen and LICENSE file added | License section of the [root README](../README.md), [development.md](development.md#contribution-workflow) |
