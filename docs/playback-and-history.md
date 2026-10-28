# Ride History and playback

This document covers how MotoCam finds recorded rides on disk, lists them in Ride History, and plays a ride's video segments as one continuous timeline with telemetry and a route map. It describes the code as it is today. For the JSON and integrity envelope these screens read, see [data-formats.md](data-formats.md).

## Contents

- [Ride discovery and loading](#ride-discovery-and-loading)
- [Rides list UI and actions](#rides-list-ui-and-actions)
- [Opening a ride and integrity verification](#opening-a-ride-and-integrity-verification)
- [Playback engine](#playback-engine)
- [Effective timeline synthesis](#effective-timeline-synthesis)
- [Missing segments and the seekbar track](#missing-segments-and-the-seekbar-track)
- [Telemetry sync during playback](#telemetry-sync-during-playback)
- [Screen structure and rebuild scope](#screen-structure-and-rebuild-scope)
- [Route map](#route-map)
- [Ride actions and their effect on disk](#ride-actions-and-their-effect-on-disk)

Key files:

| File | Main symbols |
|---|---|
| [rides_list_screen.dart](../lib/features/history/rides_list_screen.dart) | `RidesListScreen` |
| [ride_history_loader.dart](../lib/features/history/models/ride_history_loader.dart) | `loadRideHistoryIndexed`, `RideHistoryLoad`, `loadRideHistory`, `findOrphanVideoPaths` |
| [ride_index.dart](../lib/features/history/models/ride_index.dart) | `RideIndex`, `RideIndexEntry`, `SegmentHashEntry`, `RideFileStamp`, `RideIndexStore` |
| [segment_verifier.dart](../lib/features/history/models/segment_verifier.dart) | `SegmentVerifier`, `SegmentCheckToken`, `orderSegmentsForCheck`, `RideVideoCheck`, `videoCheckFromIndex`, `describeVideoCheck` |
| [ride_record.dart](../lib/features/history/models/ride_record.dart) | `RideRecord`, `RideIntegrityStatus`, `RideIntegrityReport`, `RideIncident`, `RideSegmentTimelineEntry` |
| [ride_playback_screen.dart](../lib/features/history/ride_playback_screen.dart) | `RidePlaybackScreen` (orchestration only: the controller lifecycle, segment loading, seeking, scrubbing and the video-check wiring live in the private `_RidePlaybackScreenState`, whose `build()` is a `Scaffold` around `RidePlaybackBody`) |
| [playback_timeline.dart](../lib/features/history/widgets/playback_timeline.dart) | Pure timeline functions (`buildEffectiveTimeline`, `locateSegment`, `uncoveredRanges`, `clampDuration`, `globalPlaybackPosition`, `timelineMarkers`, `nearestSampleIndex`, `speedGraphPageIndex`, `noPlayableVideoMessage`, marker and integrity helpers), `PlaybackRange`, `PlaybackMarker`, `PlaybackTimelineMarks`, `SegmentSeekTarget` |
| [playback_position.dart](../lib/features/history/widgets/playback_position.dart) | `PlaybackPosition` (the immutable position and playing flag the screen publishes) and `PlaybackSampleListenable` (the telemetry sample at that position) |
| [ride_playback_body.dart](../lib/features/history/widgets/ride_playback_body.dart) | `RidePlaybackBody`: the whole playback body, built from values, callbacks and a `ValueListenable<PlaybackPosition>` |
| [playback_video_area.dart](../lib/features/history/widgets/playback_video_area.dart) | `PlaybackVideoSurface` (the only widget that holds the `VideoPlayerController`), `PlaybackVideoArea` (video, overlay, graph, fullscreen button) and `PlaybackErrorView` |
| [playback_telemetry_overlay.dart](../lib/features/history/widgets/playback_telemetry_overlay.dart) | `PlaybackTelemetryOverlay` |
| [playback_speed_graph.dart](../lib/features/history/widgets/playback_speed_graph.dart) | `PlaybackSpeedGraph` (gestures, the curve page and the cursor layer) |
| [speed_graph_painter.dart](../lib/features/history/widgets/speed_graph_painter.dart) | `SpeedGraphPagePainter` (the curve) and `SpeedGraphCursorPainter` (the focus dot) |
| [playback_seek_bar.dart](../lib/features/history/widgets/playback_seek_bar.dart) | `PlaybackSeekBar` (slider and time labels) |
| [playback_legend.dart](../lib/features/history/widgets/playback_legend.dart) | `PlaybackLegend` |
| [playback_controls.dart](../lib/features/history/widgets/playback_controls.dart) | `PlaybackControls` (transport buttons and the segment label) |
| [route_map_panel.dart](../lib/features/history/widgets/route_map_panel.dart) | `RouteMapPanel` (the Route Map card) |
| [playback_seekbar_track_shape.dart](../lib/features/history/widgets/playback_seekbar_track_shape.dart) | `PlaybackSeekbarTrackShape` and the seekbar colour constants |
| [route_map_view.dart](../lib/features/history/widgets/route_map_view.dart) | `RouteMapView` |
| [route_points.dart](../lib/features/map/route_points.dart) | `latLngFromSample`, `samplesWithGpsFix`, `routePointsFromSamples`, `downsampleRoute` |
| [static_map_viewer.dart](../lib/features/map/widgets/static_map_viewer.dart) | `StaticMapViewer`, `MapPainter` |
| [map_source_config.dart](../lib/features/map/map_source_config.dart) | `MapSourceConfig` |

## Ride discovery and loading

A ride is one start-to-stop recording session, persisted as one `*.telemetry.json` file. `TelemetryProvider.stopRideSessionAndPersist` writes the completed file at STOP, and `TelemetryProvider.checkpointRideSession` writes checkpoints (`sessionComplete: false`) during the ride. Every write is sealed with an integrity envelope; a checkpoint lists only the segments whose hash is already known (see [telemetry.md](telemetry.md)). Ride History is opened from the recording screen's HISTORY button by `_RecordingScreenState._openRideHistory` in [recording_screen.dart](../lib/features/recording/recording_screen.dart). While recording, the button reads MINIMISE and tries picture-in-picture instead, and `_openRideHistory` itself returns early. Otherwise it releases the idle camera, calls `TelemetryProvider.pauseTracking()` (GPS and sensors stop while history is open), pushes `RidesListScreen`, and re-initializes the camera when the user returns.

`_RidesListScreenState._loadRides` builds the list:

1. `CameraProvider.getRecordings()` ([camera_provider.dart](../lib/features/camera/providers/camera_provider.dart)) recursively lists every file under the recordings directory and, on Android, under the legacy roots that still exist (`MotoCam Recordings` under app-specific external storage, the app documents and the app cache directories; see [data-formats.md](data-formats.md#legacy-roots-and-their-migration)). Paths are de-duplicated by normalized path. Errors are swallowed: with no recordings directory it returns an empty list, and an unreadable directory is skipped. The files of a ride the migration is moving (or paused in the middle of), `RecordingsMigrationController.inFlightPaths`, and of the ride an import is copying, `LegacyRideImportController.inFlightPaths`, are left out.
2. The paths go to `loadRideHistoryIndexed` ([ride_history_loader.dart](../lib/features/history/models/ride_history_loader.dart)), run on a background isolate with `Isolate.run`. If the isolate fails, it runs on the UI isolate instead. The screen first resolves the [ride index](data-formats.md#ride-index-cache) with `RideIndexStore.shared()` (path_provider, on the UI isolate) and passes the index file's path, or the store's in-memory index when it already holds one, into the isolate.
3. Files whose lower-cased path ends with `.telemetry.json` are taken one at a time. A file that is gone is skipped. When the index has an entry with the same normalised path, listed path, size, modification time and change time, and the ride's segments exist exactly as the entry says, the entry's sample-less `RideRecord` is used and the file is not read (one stat for the file and one per segment). Otherwise the file is decoded with `RideRecord.fromTelemetryFile(file, loadSamples: false)` (`verifySegments: false`). A `null` result or an exception skips that file. The video check state of each ride is computed from the stored segment hashes (`videoCheckFromIndex`); nothing is hashed.
4. `findOrphanVideoPaths` returns the video files (`.mp4`, `.mov`, `.mkv`, `.avi`) that no loaded ride references as its `videoPath`, a segment path or a quarantined path, for example segments of an interrupted ride that no checkpoint lists. Each one goes through `RideRecord.fromVideoFile`: if a `<base>.telemetry.json` next to the video (the video's name without its extension) references it, the ride is loaded from that file; otherwise a video-only ride is built (`telemetryPath` `null`, no samples, integrity `unknown`, `createdAt` from the file's modification time).
5. Rides are sorted by `createdAt`, newest first. For a telemetry ride `createdAt` is the parsed `startedAt` field converted to local time, or the telemetry file's modification time if it cannot be parsed.
6. Back on the UI isolate, `RideIndexStore` (the index's only writer) replaces the index's ride entries with the fresh ones, which drops the entries of vanished files, removes stored segment hashes that no remaining ride lists, and writes the file atomically.

The rides in the list are sample-less (`samplesLoaded: false`): they carry `sampleCount` and the last sample's `elapsedMs` (for the duration), but no samples. Samples are parsed only when a ride is opened.

What `RideRecord.fromTelemetryFile` produces (details of each field are in [data-formats.md](data-formats.md)):

- Path resolution: each declared path (the `segmentPaths` list, or `[videoPath]` if it is empty, trimmed and de-duplicated) is resolved against the telemetry file's directory. A plain file name is taken from that directory. An existing path inside that directory is kept. Otherwise a file with the same name in that directory is used, even when the declared path still exists elsewhere (after the iOS data-container path changed, or after a ride was moved to the private root while its source copy still exists). A path directly in the v0.1.11/v0.1.12 public folder always becomes the same name in the telemetry file's directory, existing or not, so an imported ride reads the same whether or not its originals are still there. A missing path in a same-named directory elsewhere becomes the missing sibling (a segment already gone before a move). Anything else is kept as declared. The exact rules are in [data-formats.md](data-formats.md#path-scope-and-quarantine).
- Trusted root: only the directory the telemetry file was found in, subdirectories included. Fields of the JSON being checked, such as `storageDirectory` or `videoPath`, are never trusted. Resolved paths outside that directory go to `quarantinedSegmentPaths`.
- `segmentPaths`: the trusted resolved paths. They are not filtered by existence; paths whose file no longer exists are also listed in `missingSegmentPaths`. If no trusted path is left, a video named like the telemetry file (`<base>.mp4`, `.mov`, `.mkv` or `.avi`) is used when it exists.
- `videoPath`: the resolved JSON `videoPath` if trusted, otherwise the last existing segment, otherwise the last trusted one. It is appended to `segmentPaths` if missing from it. If no path is left at all, the ride is dropped (`null`).
- `segmentTimeline`: entries whose resolved `path` is one of the segment paths, first entry per path, negative `startMs` clamped to 0, `endMs` raised to at least `startMs`, sorted by `startMs`.
- `lockedSegmentPaths`: resolved entries that are one of the segment paths.
- `samples`: the `samples` array in file order, only with `loadSamples: true` (the default; playback). A malformed sample is skipped; the ride is kept. A sample's ISO timestamp is parsed when it is first read. With `loadSamples: false` only the count and the last `elapsedMs` are read.
- `expectedSegmentHashes`: the hash the envelope records for each trusted segment, keyed by resolved path (`expectedSegmentHashesFor`, the same lookup as the integrity check).
- `incidents`: the optional top-level `incidents` list as `RideIncident` objects (entries without a usable non-negative `elapsedMs` are skipped), sorted by `elapsedMs`. It is `null` when the key is absent.
- `mockLocationDetected` (default `false`) and `isSessionComplete` (from `sessionComplete`, default `true`).
- `integrity`: a payload-level check (see [below](#opening-a-ride-and-integrity-verification)).

## Rides list UI and actions

The screen has the app bar "Ride History" with, on Android, a menu holding "Import rides from an older version" (see [Ride actions](#ride-actions-and-their-effect-on-disk)), and, on Android while rides move into private storage, the migration banner (`RecordingsMigrationBanner`, [recordings_migration_banner.dart](../lib/features/history/widgets/recordings_migration_banner.dart)) above the list: "Moving N rides to private storage (x of N)" with a progress bar, then the run's summary (for example "Moved 3 rides to private storage; 1 ride left in the old folder (a different file with the same name is already in private storage).") with a close button until the rider dismisses it. The recording screen shows the same banner below its profile bar while not recording. While an import runs, a line "Importing rides from the old folder (x of N)" ("Reading the old folder" while it plans) with a progress bar follows. Below the banner come a spinner while loading, "Failed to load rides: ..." on error, and "No rides found yet. Record a ride to see it here." when empty. Otherwise it shows a "Locked Clips" section (rides where `isLocked`, that is `lockedSegmentPaths` is non-empty) followed by an "All Rides" section that contains only the unlocked rides. Both keep the newest-first order.

Each card shows:

| Element | Content or condition |
|---|---|
| Title | `createdAt` as `dd MMM yyyy, hh:mm a` |
| File name | `RideRecord.fileName` (last component of `videoPath`), one line |
| `VIDEO ONLY (RECOVERED)` badge | `telemetryPath == null` |
| Integrity badge | The first that applies: `INTEGRITY WARNING` (`integrity.status == modified`), `SIMULATED GPS` (`mockLocationDetected`), `SIGNED ON THIS PHONE` (`verified` and `integrity.signedBy == thisDevice`), `DATA UNMODIFIED` (`verified`), `UNVERIFIED` (`unknown` with a telemetry file) |
| Video check badge | Only for a `verified` ride with recorded segment hashes: `VIDEO CHECK FAILED` when a stored result for a segment differs from its recorded hash, `VIDEOS VERIFIED` when every existing segment has a stored, still-valid, matching result |
| `QUARANTINED n` badge | `quarantinedSegmentPaths` non-empty |
| `INCOMPLETE` badge | `missingSegmentPaths` non-empty |
| `RECOVERED (INCOMPLETE)` badge | A telemetry file with `sessionComplete: false` (a checkpoint: the app stopped before the ride was saved normally) |
| `LOCKED` badge | `isLocked` |
| Subtitle lines | Distance (2 dp), duration (`HH:MM:SS` from the last sample's `elapsedMs`), "Video: X of Y kept" when the stored timeline leaves spans of 2 s or more without video, max and average speed (1 dp), "Segments: n" or "Segments: a of n available", sample count (`sampleCount`), the integrity line, the video check line (below; red when a segment failed), "Quarantined paths: n" when present, "Telemetry: Available" or "Telemetry: Not available" |
| Unlock button | Locked rides only. Enabled when the status is not `modified`, there are no quarantined paths and no stored video check failed; otherwise disabled with the tooltip "Integrity warning: lock state changes disabled". While the unlock runs a progress ring replaces it (tooltip "Checking the videos before unlocking"): indeterminate until the first segment is checked, then the share of segments checked |
| Delete button | Every ride. Tooltip "Delete ride", or "Unlock the ride to delete it" for a locked ride that can be unlocked. A spinner replaces it while the files are deleted |

The badges wrap onto further lines instead of squeezing the file name. `SIGNED ON THIS PHONE` and `DATA UNMODIFIED` cover the ride JSON only; segment files are hashed when the ride is opened (or unlocked), and the list shows what was stored then. The list is a `ListView.builder` (section headers and cards), so only visible cards are built.

The integrity line is one of:

| Status | Text |
|---|---|
| `verified`, signed by this phone | "Integrity: ride data unmodified and signed by this phone's MotoCam key (it shows no edit by anyone without that key; it does not prove the footage is genuine)" |
| `verified`, signed by another key | "Integrity: ride data unmodified; signed by another phone or an earlier install of MotoCam" |
| `verified`, signed, this phone's key unknown | "Integrity: ride data unmodified; signed, but this phone's key could not be read to check by whom" |
| `verified`, unsigned | "Integrity: ride data unmodified since recording" |
| `modified`, `signature-removed` | "Integrity: check failed (this phone signed this ride, but the signature was removed or replaced)" |
| `modified`, otherwise | "Integrity: check failed" |
| `unknown`, video-only ride | "Integrity: not available" |
| `unknown`, otherwise | "Integrity: not available (recorded by an older version)" |
| `unknown`, `sessionComplete: false` | "Integrity: not available (ride was not saved completely)" |

When `mockLocationDetected` is set, ". GPS came from a simulated (mock) location provider." is appended.

The video check line (`describeVideoCheck`) appears only for a `verified` ride with at least one existing segment that has a recorded hash (n such segments). A stored result counts only while the segment file keeps the stamp and the envelope keeps the hash it was computed for:

| Stored results | Text |
|---|---|
| f of them failed | "Videos: f of n segment(s) failed the check" |
| All n checked, none failed | "Videos verified: unmodified since recording" |
| None | "Videos not checked yet (open the ride to check)" |
| k of n, none failed | "Videos: k of n segments checked, no failure so far (open the ride to finish)" |

Behaviour:

- Each load first reads this phone's signing key (once per session) and the signed-ride registry on the UI isolate (`loadRideSignerContext`) and passes them into the loader isolate, which derives who signed each ride; see [data-formats.md](data-formats.md#who-signed-a-ride). On iOS, in tests or after a Keystore error the key is unknown: no ride shows `SIGNED ON THIS PHONE` and no ride is flagged `signature-removed`.
- Tapping a card pushes `RidePlaybackScreen(ride: ride)` with the sample-less ride. An `_isOpeningRide` flag ignores further taps until the route is popped. The list is not reloaded on return; only that ride's video check state is re-read from the index (`_refreshVideoCheck`, a few stats, no hashing). The screen also listens to the `RideIndexStore` and re-reads the state of the ride last opened on every index update, so a segment that was still being hashed when playback closed shows once its result is stored; a refresh that finishes after a newer one is dropped.
- Pull to refresh reloads everything (the list is replaced by the spinner while it runs). It is only available when the list is non-empty.
- While a migration run moves files (`RecordingsMigrationController.isRunning`), tapping a card, Unlock and Delete only show "Rides are being moved to private storage. Try again when the move finishes." (3 s), checked again after each confirmation dialog. The same holds, with "Rides are being imported from the old folder. Try again when the import finishes.", while an import runs, and, with "Old rides are being deleted for the storage budget. Try again in a moment.", while a storage budget run deletes rides (`CameraProvider.isStorageBudgetRunning`; it runs only while recording, so only when history was opened another way). Opening a ride, unlocking and deleting also hold the migration off while they run (`CameraProvider.holdRecordingsMigration`), so a run that was paused (for example by a recording) does not resume and move that ride's files underneath them; it resumes when the hold is released. Files of a ride the migration left split between the old folder and private storage are left out of the list until a later run finishes it. The list reloads when the run ends, since moved rides have new paths; their video check results (keyed by path) are computed again when they are opened.
- Unlock and delete are described under [Ride actions](#ride-actions-and-their-effect-on-disk). The screen has no lock, export, share or search action.

## Opening a ride and integrity verification

`_RidePlaybackScreenState.initState` runs, in order:

1. Records whether the app is in the foreground and registers the lifecycle observer.
2. `_loadPlaybackPreferences()` (not awaited): reads the route-map panel preference and the online-map consent.
3. `_start()` (not awaited), which runs in order:
   1. For a sample-less ride, `RideRecord.loadSamples` in `Isolate.run` (on the UI isolate if that fails) re-reads the ride with its samples and applies the list's signer context again; the result replaces the screen's `_ride`. A ride that cannot be re-read (the result is still sample-less) plays without telemetry from the saved summary, and the load-time notice adds "The ride file could not be read again: showing the saved summary without telemetry, and its videos were not checked." The segment check is then skipped, because the recorded hashes no longer come from a file on disk, and 'Check videos again' shows the same message instead of hashing. The spinner shows meanwhile.
   2. Computes the ride's maximum sample speed for the speed graph.
   3. `_showInitialIntegrityWarning()`: shows the load-time notices after the next frame, and marks segments that have no recorded hash (`missing-segment-hash` issues are known before any hashing).
   4. `_initializePlayback()`: builds the playlist and loads the first segment ([Playback engine](#playback-engine)).
   5. `_verifySegmentsAsync()` (not awaited): the segment check, described below.

`dispose` cancels segment loads and the segment check (after the segment being hashed).

The two verification levels differ (the envelope format and the issue codes are in [data-formats.md](data-formats.md)):

| | Ride History load | Playback screen |
|---|---|---|
| Call | `fromTelemetryFile(file, loadSamples: false)` with `verifySegments: false`, or the ride index entry | The report of `loadSamples` (the same payload-level checks, on the re-read file) plus `SegmentVerifier` for the segments |
| Checks | Envelope presence and format, `algo`, `envelopeVersion`, `payloadHash`, the version 3 signature, a recorded hash for every existing segment, orphan keys in `segmentHashes`, quarantine, then the signer context (`signedBy`, `signature-removed`) | The same, plus a SHA-256 of every existing trusted segment file with a recorded hash (`segment-hash-mismatch`, `unreadable-segment-file`), reused from the ride index while still valid |
| Result | Card badges, the video check state from stored results | Seekbar ranges, the integrity notice, stored segment results |

Verification fails closed. A completed ride whose `schemaVersion` is 3 or later and that has no envelope is `modified` (`missing-integrity`), and so is an envelope that is not an object (`invalid-integrity`). A ride without an envelope is `unknown` only when its `schemaVersion` is below 3 or it is marked `sessionComplete: false`. A segment file that is missing is not an integrity issue: it makes the ride incomplete (`missingSegmentPaths`, the `INCOMPLETE` badge and the red seekbar ranges) without counting as modification.

The segment check (`_verifySegmentsAsync`) uses `SegmentVerifier` ([segment_verifier.dart](../lib/features/history/models/segment_verifier.dart)):

- **Order** (`orderSegmentsForCheck`): the segment about to play (the active playlist entry) first, then the others in timeline order, then any other segment with a recorded hash. Segments without a recorded hash (already flagged at load) and missing files are skipped.
- **One segment at a time.** Each segment is hashed with its own `Isolate.run` call (on the UI isolate if that fails). A `SegmentCheckToken` is checked before each segment; `dispose` and 'Check videos again' cancel it, so the work stops after the segment in flight, whose result is still stored.
- **Stored results.** Before hashing, the verifier stats the segment; a result in the [ride index](data-formats.md#ride-index-cache) with the same normalised path, size, modification time, change time and expected hash is reused, so re-opening an unchanged ride (also after an app restart) hashes nothing. A change that keeps the size and both times is therefore not seen until 'Check videos again'. Every new hash is written to the index by `RideIndexStore`. Results are never carried across paths.
- **Failures.** A mismatch or an unreadable file adds a `segment-hash-mismatch` or `unreadable-segment-file` issue; the segment is painted purple on the seekbar as soon as it is found. At the end the notice below is shown if there is something new to say.
- **'Check videos again'.** An app bar action (shown when the ride has recorded hashes; a small spinner while a check runs, disabled while the first segment loads). It cancels the running check, resets the purple marks to the load-time ones, shows "Checking the videos again...", hashes every segment while ignoring stored results, and then always reports: the integrity notice, or "Videos checked: all N segment(s) match the recording." A ride without recorded hashes says "This ride has no recorded video hashes to check."

What the playback screen shows:

| When | Playback screen |
|---|---|
| Load-time issues or quarantined paths | SnackBar (5 s) with the text from `describeIntegrityIssues` (below) |
| Status `unknown` with a telemetry file | "This ride has no integrity record, so its files cannot be checked." in the same SnackBar |
| `mockLocationDetected` | "GPS in this ride came from a simulated (mock) location provider." in the same SnackBar |
| The segment check finds issues | Segments that failed are painted purple on the seekbar as they are found, and at the end a SnackBar (6 s) with the `describeIntegrityIssues` text (load-time issues plus the new ones), unless it is the notice already shown |

`describeIntegrityIssues` builds "Integrity check: ..." from up to five parts, joined with "; ": "this phone signed this ride, but its signature was removed or replaced, so the ride data may have changed since recording" (`signature-removed`), "the ride's signature does not match its data" (`signature-invalid`, `signature-key-mismatch`, `missing-signature`, `unsupported-signature-alg:`), "the ride data may have changed since recording" (any other issue except a segment or quarantine issue), "N segment(s) could not be confirmed unmodified since recording (marked purple on the seekbar)" (`segment-hash-mismatch`, `missing-segment-hash` or `unreadable-segment-file`, counted once per segment), and "N segment path(s) outside the recordings folder was/were skipped".

The status never blocks playback or seeking. Quarantined paths are not in the playlist. A segment that fails the check is still played; its span is marked purple.

## Playback engine

All of the following is in `_RidePlaybackScreenState`, using the pure functions in [playback_timeline.dart](../lib/features/history/widgets/playback_timeline.dart). The screen uses the `video_player` plugin with one `VideoPlayerController.file` per segment, created without `VideoPlayerOptions`. It has no platform gating and uses no app method channel.

### Initialization

```mermaid
flowchart TD
    A["Declared list D: ride.segmentPaths then ride.videoPath, trimmed, de-duplicated"] --> B["For each path in D: missing file? stored timeline entry of 1000 ms or more? otherwise probe its duration"]
    B --> E["buildEffectiveTimeline: timeline E"]
    E --> F["Playlist: entries of E that are not missing or unreadable; offsets = entry starts; total T"]
    F --> G["Missing, failed-check and no-video ranges; lock and incident markers"]
    G --> H["_loadSegment on each playlist index until one loads, autoPlay false"]
    H --> C{"A segment loaded?"}
    C -- no --> W["_playbackError: error view with Back and Retry"]
    C -- yes --> I["_isLoading = false, availability SnackBar if needed"]
```

- Durations come from the stored timeline. A path is probed only when it has no stored entry of at least 1000 ms (rides recorded before the timeline existed, or an entry saved without an end). A missing file counts as missing and is not probed.
- Probing (`_probeSegmentDuration`): the file is opened with a throwaway controller, `initialize()` is awaited, `value.duration` is read and the controller is disposed. Only for the last declared path, a failed probe is retried once after 300 ms. A duration of zero or an error counts as unreadable.
- The playlist lists `_segmentPaths`, `_segmentDurations` and `_segmentOffsets` run in parallel, in timeline order. Offsets are the timeline entry starts and do not change. A segment's duration starts as its timeline length and is replaced by the controller's real duration when the segment loads.
- A segment whose duration came from the timeline is checked for readability only when it loads. A failed load marks it as failed (red on the seekbar) and counts it as unreadable.
- If no segment loads, `_playbackError` is set and the screen shows an icon, the message and two buttons, Back and Retry. The message is "No playable video for this ride (N missing, M unreadable)." (each count only when non-zero), or "This ride has no video segments." when D is empty. Retry (`_retryPlayback`) disposes the current controller and runs the whole initialization again.

### Loading a segment (`_loadSegment`)

1. Return `cancelled` if disposing, `failed` if the index is out of range. Take a new load generation (`_loadGeneration`).
2. `_initializeSegmentController` creates and initializes a controller. For the last playlist segment it retries once after 300 ms. Failure returns `failed`.
3. `setLooping(false)`; seek to the clamped `initialPosition` if it is above zero.
4. If a later load, `_retryPlayback` or `dispose` has taken a newer generation, dispose this controller and return `cancelled`.
5. Remove the listener from the controller being replaced, add `_onControllerTick` to the new one, then `setState` to install it, set `_activeSegmentIndex`, store its real duration and update `_lastKnownGlobalPosition`.
6. Dispose the replaced controller (not awaited). If `autoPlay`, and the app is in the foreground and the user is not scrubbing, `play()`.

Only one controller is active. The next segment is not preloaded.

### Position model and auto-advance

- Global position: `globalPlaybackPosition`, `clamp(offset[active] + controller.value.position, 0, T)`. When there is no initialized controller, `_lastKnownGlobalPosition` is used.
- `_onControllerTick` runs on every `VideoPlayerValue` notification (the plugin updates the position every 100 ms while playing). It first calls `_publishPosition()` (see [Screen structure and rebuild scope](#screen-structure-and-rebuild-scope)).
- When the value reports an error (`hasError`), `_handleRuntimeError` marks the segment as failed (red on the seekbar) and shows "Segment N could not be played. Skipping to the next segment." (4 s), then advances. If no playable segment follows, it shows "Playback ended: segment N could not be played." instead. It handles each controller once.
- When `isCompleted` is true, a next playable segment exists and no segment load is running, the position is set to the end of the active segment and `_advanceToNextSegment()` runs.
- `_advanceToNextSegment` sets `_isSwitchingSegment`, tries `_loadSegment(autoPlay: true)` on each following segment that has not failed, and returns on the first success. Segments that fail to load are marked failed and skipped. If nothing loads, playback is paused and "Playback ended: the remaining segments could not be opened." is shown.
- At the end of the last segment the controller simply completes. Pressing play then restarts that segment from 0 (the plugin seeks to 0 when position equals duration).
- `didChangeAppLifecycleState` pauses on every state other than `resumed` and records that the app is in the background. While it is, a segment that finishes loading (for example an auto-advance in flight) does not start playing, and seeks do not resume playback. Nothing resumes playback when the app returns.

### Seeking across segments

`locateSegment(offsets, durations, pos)` walks the playlist with `start = offset[i]` and `end = start + duration[i]`:

- `pos <= start`: segment `i`, local 0.
- `pos < end`, or `i` is the last segment: segment `i`, local `pos - start`.

So a position in a gap or a missing range lands at the start of the next playable segment, and a position past the last segment is clamped to that segment's end (by the plugin's `seekTo` within the current segment, or by `_loadSegment` when it switches segments).

`_seekGlobal(target, shouldResume)` clamps to `[0, T]` and locates the target. For the active segment (unless it has failed) it seeks the current controller and, with `shouldResume`, plays it if that controller is still the active one. Otherwise it sets `_isSeekingAcrossSegments` and calls `_loadSegment(autoPlay: false, initialPosition)` on the target, skipping failed segments and falling forward to later segments at position 0 if a load fails. If nothing loads it shows "No playable video at HH:MM:SS or later." With `shouldResume` it then calls `play()`.

Segment loads are serialized. A seek requested while an auto-advance or a cross-segment seek is loading is stored in `_pendingSeek` instead of starting; a newer request replaces it, and `_drainPendingSeek` runs it when the load finishes. A seek queued during an auto-advance resumes playback.

| Input | Action |
|---|---|
| Slider drag | `onChangeStart` → `_beginScrub` (pauses, enters scrub mode); `onChanged` → `_updateScrubPreview` (publishes the preview position, no `setState`); `onChangeEnd` → `_commitSeekbarValue` → `_commitScrub` → `_seekGlobal` (resumes if it was playing) |
| Slider release near a marker | `_commitSeekbarValue` snaps to the nearest incident or lock marker within 18 px, so a marker tap issues one seek, and shows "Jumped to incident/locked marker at HH:MM:SS" (1200 ms) |
| Speed graph tap | On tap-up (`_seekFromGraph`), seeks to `position + ((dx - w/2) / w) * W` (`speedGraphTapTarget`; W is the graph window, see below) |
| Speed graph horizontal drag | The position and finger x at drag start are the anchor; the target is `anchor + ((dx - startDx) / w) * W`, clamped to `[0, T]` (`speedGraphDragTarget`). Scrubs like the slider |
| Replay 10 / Forward 10 | `_seekBy`: `_seekGlobal(displayed position ∓ 10 s)` |
| Play / pause | `_togglePlay`: `controller.play()` / `pause()` on the active controller |
| Tap on the video or the top-right button | Toggles fullscreen: only the video, the button and the hint "Tap video to show controls" remain |

A scrub may start while a segment loads; the seek it commits is queued by `_seekGlobal`. Below the controls, "Segment i/n" shows the active playlist position.

## Effective timeline synthesis

`buildEffectiveTimeline` merges the stored `segmentTimeline` with the declared paths D. Notation: `A[p]` is the probed duration of path `p` in ms (only paths without a usable stored entry are probed); `F` is the fallback duration.

**Fallback duration F**: the upper median (`sorted[len ~/ 2]`) of the positive lengths of the stored entries (after the adjustment below) and the probed durations, or 1000 ms when there are none.

**Stored entries.** The stored timeline already follows the file rule (see [data-formats.md](data-formats.md#ride-file-codec)). For each stored entry, first entry per path, the codec's `normalizeTimelineSpan` gives `s = max(startMs, 0)` and `max(endMs, s)`, and playback then requires at least 1 ms: `e = max(endMs, s + 1)`. An entry shorter than 1000 ms (for example one saved without an end) takes its probed length when one exists: `e = s + A[p]`.

**Declared paths without a stored entry.** `c = max(e)` over the stored entries (0 without any). For each such `p` in D: `dur = max(A[p] ?? F, 1000)`, add `(p, c, c + dur)`, `c += dur`. Paths missing from the stored timeline are therefore appended after its end. Without a stored timeline this makes a sequential, gap-free timeline from 0 in declared order.

**Normalization.** Sort by start; `cursor = 0`; for each entry `s' = max(s, cursor)`, `e' = max(e, s' + 1)`, `cursor = e'`. Gaps between stored entries are kept; an overlapping entry is pushed to start at the previous end.

**Offsets and total.** The playlist offset of each playable segment is its entry's start. The total is `T = max(samples.last.elapsedMs (0 without samples), max end in E)`, and the slider runs from 0 to `T` ms.

**Worked example.** Stored entries A `[0, 300400]`, B `[300400, 600900]` and C `[600900, 600900]` (an entry with no length, for example one saved without an `endMs`, which the reader sets to `startMs`; see [data-formats.md](data-formats.md#segmenttimeline-entries)); B is missing on disk. A has a usable stored entry and is not probed; C's entry is shorter than 1000 ms, so C is probed and gives 299 600 ms. E is A `[0, 300400]`, B `[300400, 600900]`, C `[600900, 900500]`. The missing range is `[300400, 600900]`, offsets are A 0 and C 600 900, and `T` is 900 500 (assuming the last sample is not later). When A loads, its real duration (say 299 800 ms) replaces its stored length. A seek to 450 000, or to 300 000 (inside A's entry but past its real end), maps to C at local 0. Auto-advance at the end of A moves the position from 299 800 straight to 600 900.

The model assumes that segment local time 0 equals its timeline `startMs`, that video time maps 1:1 to timeline time, and that the timeline and telemetry `elapsedMs` share the same zero.

## Missing segments and the seekbar track

`rangesForPaths` turns a set of paths into the merged spans of their timeline entries, and `mergeRanges` sorts ranges and merges overlapping or touching ones. The screen keeps three range lists:

| Range list | Source | Colour | Legend |
|---|---|---|---|
| No video | `uncoveredRanges`: spans of `[0, T)` that no timeline entry covers, at least 2 000 ms long (for example footage that loop recording deleted during the ride) | `noVideoColor` (`0xFF78909C`, blue-grey) | "No video" |
| Missing | Declared segments that are missing or unreadable at initialization, plus segments that fail to load or fail during playback | `missingFootageColor` (`Colors.red`) | "Missing segment" |
| Failed check | Segments listed by `segmentPathsFailingIntegrity` from the load-time issues, then from the full check | `failedCheckColor` (`Colors.purpleAccent`) | "Failed integrity check" |

`PlaybackSeekbarTrackShape` ([playback_seekbar_track_shape.dart](../lib/features/history/widgets/playback_seekbar_track_shape.dart), a `SliderTrackShape` with `BaseSliderTrackShape`) replaces the slider track. It paints the inactive track as a rounded rect and the active part up to the thumb. It then paints the no-video, missing and failed-check ranges, in that order, at alpha 0.86, mapped linearly across the track width and clipped to the rounded rect. Last it draws the event markers as 2 px vertical ticks that extend a few pixels above and below the track: lock markers in `lockMarkerColor` (`Colors.orangeAccent`) and incident markers in `incidentMarkerColor` (`Colors.redAccent`). Theme colours are used for the track, with fallbacks only if the theme leaves them null. Because ranges and markers are positioned from the slider's own track rectangle, they line up with the positions the slider reports.

When any segment is missing or unreadable at initialization, a SnackBar (4 s) says "Some ride segments are unavailable (N missing, M unreadable). They are marked red on the seekbar and skipped." (each count only when non-zero), with " The last segment was retried once." appended when the last declared path failed its probe. A legend row under the time labels shows a dot for each range list and marker type that is present: "No video", "Missing segment", "Failed integrity check", "Incident" and "Locked".

Quarantined paths are not shown: they are neither in the playlist nor in the timeline.

## Telemetry sync during playback

On every position change, `PlaybackSampleListenable` takes the published position (the scrub preview while scrubbing, otherwise the global position) and calls `_ride.sampleForPosition(position)`; the stats overlay and the route map's marker listen to it, so the sample is looked up once per change:

- No samples: `TelemetryData.empty()`. Before the first or after the last sample: that sample.
- Otherwise a binary search on `elapsedMs`, then linear interpolation of latitude, longitude, speed, bearing, accelerationG and distanceKm between the two neighbours. Bearing is interpolated along the shortest arc (`RideRecord.interpolateBearing`), so 350° to 10° passes through 0°.
- Position is never interpolated across a sample without a GPS fix: when one neighbour has `hasFix == false`, the neighbour with a fix supplies latitude, longitude, speed and bearing; when neither has a fix, the nearer sample is returned.

The interpolated sample feeds three views, all shown only when the ride has samples and the screen is not fullscreen:

| View | Details |
|---|---|
| Stats overlay | `Speed` (km/h, 1 dp), `Dist` (km, 2 dp), `G` (2 dp), `GPS` (5 dp) |
| Speed graph | 56 px strip; window `W = max(10 000, min(T, 60 000))` ms (`speedGraphWindowMs`) centred on the current time; cyan line and dots, orange focus dot on the sample nearest the centre (`nearestSampleIndex`), short orange (lock) and red (incident) ticks. Drawn as a static curve page plus a cursor, see below |
| Route map | Current-position marker, see [Route map](#route-map) |

Timeline markers are computed at initialization:

- Incident markers: when the ride JSON has an `incidents` list (the incidents detected while recording; see [telemetry.md](telemetry.md)), each incident's `elapsedMs`, clamped to `[0, T]`, de-duplicated and sorted (`recordedIncidentOffsetsMs`). Files without the key fall back to `incidentMarkerOffsetsMs`: samples with `accelerationG >= 3.2`, at least 5 000 ms after the previous accepted marker. The incident-sensitivity setting ([settings.md](settings.md)) affects only detection while recording.
- Lock markers (`lockMarkerOffsetsMs`): the start offset of each playlist segment listed in `lockedSegmentPaths`.

The seekbar is a 34 px `Slider` whose track shape paints the ranges and markers (see [above](#missing-segments-and-the-seekbar-track)). Markers appear on the seekbar, as speed-graph ticks and in the legend row.

## Screen structure and rebuild scope

`_RidePlaybackScreenState` is orchestration: it owns the `VideoPlayerController` lifecycle, the playlist, segment loading, seeking, scrubbing and the video-check wiring, and its `build()` is a `Scaffold` whose body is the spinner, a `PlaybackErrorView`, or a `RidePlaybackBody`. Everything on screen below that is a widget under `lib/features/history/widgets/` that takes explicit values, callbacks and a `ValueListenable<PlaybackPosition>`, never the controller or the `State`. Only `PlaybackVideoSurface` (which draws `VideoPlayer` at the controller's aspect ratio) holds the controller; the screen passes it to `RidePlaybackBody` as a ready-made `video` widget.

**Publishing the position.** The screen owns a `ValueNotifier<PlaybackPosition>` (position and `isPlaying`). `_publishPosition()` sets it to the scrub preview while the rider drags and the global position otherwise, and is called from `_onControllerTick` (every plugin notification), `_beginScrub`, `_updateScrubPreview`, `_commitScrub`, after a segment load swaps the controller, and when initialization finishes. A value equal to the last one notifies nobody, so a paused video with no scrub costs nothing. The earlier `ValueListenableBuilder<VideoPlayerValue>` over the whole body, and the `setState` on every scrub move, are gone; `setState` is left for changes of structure (loading, a failed segment, new ranges, the fullscreen and map toggles, a new segment).

**What listens to the position** (each in its own `ValueListenableBuilder`, with a repaint boundary where it paints):

| Widget | Rebuilds per position change |
|---|---|
| `PlaybackSeekBar` | The `Slider` (value) and the elapsed-time label. The track shape, total time and ranges are built with the widget |
| `PlaybackTelemetryOverlay` | The four stats (through `PlaybackSampleListenable`) |
| `PlaybackSpeedGraph` | The cursor layer (`SpeedGraphCursorPainter`) and the offset of the curve page; the curve itself only on a page change |
| `RouteMapView` | Only its current-position `MarkerLayer`, through `currentSampleListenable` |
| `PlaybackControls` | The play/pause button (the `isPlaying` flag); the Back and Forward buttons and the segment label do not listen |

`RidePlaybackBody`, `RouteMapPanel`, `PlaybackLegend` and `RouteMapView.build` do not rerun on a tick.

**Speed graph.** The strip shows a window centred on the position, so its curve scrolls. To keep that from repainting the curve per tick, `PlaybackSpeedGraph` paints the curve once for a page three windows wide (`SpeedGraphPagePainter`, from `(i - 1) * W` for page `i = speedGraphPageIndex(position, W)`, so the window around any position in page `i` lies inside it) behind a `RepaintBoundary`, and slides it with a `Transform.translate` by `w/2 - (position - pageStart) * w / W` so the current time stays at the centre. The cached page is the same widget instance until the position enters another page, or the samples, markers, speed scale, window or strip width change. The orange focus dot is a second painter (`SpeedGraphCursorPainter`) in its own repaint boundary, so a tick repaints only that dot. The page includes one sample either side of its range so the line runs to the strip's edges, which also means the line now continues to the strip edge where it used to stop at the last sample inside the window.

**Route map.** `RouteMapPanel` builds the map only while expanded (an `AnimatedSize` holding either the map or an empty box), so a collapsed map is neither built nor laid out and fetches no tiles. Its `mapBuilder` (default `RouteMapView`) is replaceable for tests.

**Pure logic** stays in [playback_timeline.dart](../lib/features/history/widgets/playback_timeline.dart): the timeline, offsets, missing ranges, `locateSegment`, markers (`timelineMarkers`), the clamp and global-position rules, the no-playable-video message, the nearest-sample and speed-graph page rules. They are covered by `test/features/history/playback/playback_timeline_test.dart`. `ride_playback_body_test.dart` pumps `RidePlaybackBody` with a `ValueNotifier` position and checks the rebuild scope with test-visible paint counters (`SpeedGraphPagePainter.paintCount`, `SpeedGraphCursorPainter.paintCount`), a counting map stub and widget-instance identity.

## Route map

The "Route Map" card sits below the video when the ride has samples and the screen is not fullscreen. Its header is a 48 dp button (with `Semantics` that report the expanded state). Tapping it toggles the map inside an `AnimatedSize` (180 ms) and stores the choice in SharedPreferences as bool `ride_playback_show_route_map` (default `false`). The map is built only while expanded; collapsed, the card holds an empty box, so no tiles are fetched.

The first time the rider expands the map, a dialog "Show online map?" explains that the map downloads tiles from OpenStreetMap (`tile.openstreetmap.org`), which sends the ride's area and the device's IP address to the OpenStreetMap Foundation, and that tiles are cached on the device. "Not now" leaves the map collapsed. "Show map" stores bool `ride_playback_online_map_consent` and expands the map. A stored `ride_playback_show_route_map` is honoured only once consent is stored.

The map height is `clamp(0.14 × screen height, 90, 130)`. `RouteMapPanel` hands `RouteMapView` the ride's samples and the sample at the playback position as a `ValueListenable` (`currentSampleListenable`).

### Tile source (`MapSourceConfig`)

| Constant | Value |
|---|---|
| `tileUrlTemplate` | `https://tile.openstreetmap.org/{z}/{x}/{y}.png` |
| `tileHost` | `tile.openstreetmap.org` (named in the consent dialog) |
| `attributionText` | `OpenStreetMap contributors` (the attribution layer prepends the ©) |
| `copyrightUrl` | `https://www.openstreetmap.org/copyright` |
| `licenceSummary` | ODbL notice listed on the licence page (registered by `registerMapLicence`) |
| `userAgentPackageName` | `com.example.motocam` |
| `contactUrl` | `https://github.com/Sarthak195/MotoCam` |
| `userAgent` | `MotoCam (com.example.motocam; +https://github.com/Sarthak195/MotoCam) flutter_map`, sent as the `User-Agent` header of every tile request |
| `maxZoom` / `maxNativeZoom` | 19 / 19 |
| `maxTileCacheBytes` | 25 000 000 (25 MB) |

`RouteMapView` and the consent dialog in the playback screen are the only users of these constants. They are compile-time `const`, so changing the provider needs a new build. There is no fallback tile source.

### `RouteMapView`

`RouteMapView` is a `StatefulWidget`. It computes the route once per `telemetryData` list, and the current-position marker follows `currentSampleListenable` (or the fixed `currentSample` when none is given) through its own `ValueListenableBuilder`, so a playback tick rebuilds that one marker layer and not the map:

1. `routePointsFromSamples` ([route_points.dart](../lib/features/map/route_points.dart)) keeps the samples that carry a real GPS fix: `hasFix` is true, the position is not exactly `(0, 0)`, and the coordinates are inside the WGS 84 range.
2. `downsampleRoute` keeps every `ceil(n / 1800)`-th point above 1 800 points, always keeping the last point.
3. With fewer than 2 points left, it returns `StaticMapViewer` instead.
4. Otherwise it builds a `FlutterMap` (flutter_map 8.3.2) whose initial camera fits the route's bounds (`CameraFit.bounds`, 20 px padding, zoom at most 16). The camera zoom is capped at `MapSourceConfig.maxZoom` (19). No `MapController` is used, so the map does not follow the current position and has no recentre control.

Layers: the OSM `TileLayer`; one `Polyline` (width 4, `lightBlueAccent`); a marker layer for start (green, play icon) and end (red, stop icon), created once; and a second marker layer for the current position (cyan dot, hidden when the current sample has no GPS fix), which is the only layer that changes on a tick. Gestures: pinch zoom, drag, double-tap zoom, fling and scroll-wheel zoom; no rotation. The map background is dark grey, so missing tiles do not show as light blocks.

The `TileLayer`, the `PolylineLayer` and the start and end marker layer are created once per map and reused on every rebuild; the `TileLayer` disposes the provider when the map is removed. The provider sends `MapSourceConfig.userAgent` and caches tiles through flutter_map's `BuiltInMapCachingProvider` (`fm_cache` under the platform cache directory) with a 25 MB limit. flutter_map applies that limit when the cache is first opened in the process, so the cache can grow past it while the app runs. The app does not clear the tile cache, and deleting rides does not clear it.

Overlays: "GPS fixes: N" (fixes before downsampling) top left; "Map tiles unavailable (offline?)" bottom left once any tile fails to load (`errorTileCallback`); and the attribution bottom right. The attribution is `OsmAttribution` ([osm_attribution.dart](../lib/features/map/widgets/osm_attribution.dart)), the last child of the `FlutterMap`: flutter_map's `RichAttributionWidget` with an info button that opens a box with a `TextSourceAttribution` "© OpenStreetMap contributors" (plus the flutter_map credit, `showFlutterMapAttribution` left at its default). Tapping the OpenStreetMap line launches `copyrightUrl` in the external browser through `url_launcher` (`launchUrl`, `LaunchMode.externalApplication`); when that fails or no browser handles it, a SnackBar says "Could not open the link. Visit openstreetmap.org/copyright in a browser." The manifest has a `<queries>` entry for https `VIEW` intents so the lookup works on Android 11 and later. `StaticMapViewer` draws no tiles and needs no attribution. The licence page is reached from the recording settings sheet ("About and licences").

### `StaticMapViewer` fallback

Used only from `RouteMapView` when fewer than 2 GPS fixes remain, for example a ride recorded without a GPS fix. It draws without tiles, network or gestures, using only the samples that carry a fix (`samplesWithGpsFix`, the same filter as the online map):

- No fix: a grey box with "No GPS fix recorded for this ride" ("No location data available" for an empty sample list, which the playback screen never passes).
- Otherwise: a 40 px grid, the route coloured green → yellow → orange → red by speed relative to the fastest fix, green and red circles at the first and last fixes (a single fix is one green dot in the centre), and an info box with "GPS fixes: N" and the start and end coordinates (4 dp).

`MapPainter` projects equirectangularly from the min/max bounds padded by 10 %, with one scale for both axes.

## Ride actions and their effect on disk

These actions in Ride History and playback write app data:

| Action | Where | Effect on disk |
|---|---|---|
| Unlock | Ride History, locked rides | After the dialog "Unlock this clip?" ("Unlocking only removes the lock marker. MotoCam never deletes past rides automatically; the ride moves from Locked Clips to All Rides.", or, with the storage budget on, "Unlocking removes the lock marker; the ride moves from Locked Clips to All Rides. With the storage budget on, an unlocked ride can be deleted automatically once it is among the oldest."), `RideRecord.changeLockState(false)` runs. It refuses if the in-memory status is `modified`, paths are quarantined or the ride has no telemetry file. Otherwise, under a per-file lock, it re-reads the JSON and re-verifies it in full, including every segment hash (a still-valid result stored in the ride index is reused instead of hashing; the button shows a progress ring), and refuses if that check fails (who signed the ride is decided again from the file just read). It then sets `lockedSegmentPaths` to `[]` and rewrites the file with `writeTelemetryAtomically`. A verified ride keeps its `segmentHashes` and gets a new `payloadHash` (`resealIntegrityEnvelope`). A ride signed by this phone is signed again through the `integrity` channel and stays `SIGNED ON THIS PHONE`; if signing fails the unlock is refused and the file is untouched. A ride signed by another key is re-sealed unsigned (version 2: its foreign signature is dropped), and a ride without an envelope is written without one, so it stays unverified (details in [data-formats.md](data-formats.md#re-signing-on-lock-change)). On success the list reloads and shows "Clip unlocked."; otherwise (3 s) "Could not unlock this clip: its files failed the integrity check or could not be read." (refused), "Could not sign this ride again on this phone. The ride is unchanged; try again." (re-signing failed) or "Could not unlock this clip: the change could not be saved." (write failed) |
| Delete | Ride History, any ride | See below |
| Import from an older version | Ride History menu, Android | Copies rides from the v0.1.11/v0.1.12 public folder into the recordings directory, and optionally deletes the imported originals; see below |
| Route Map toggle | Playback | SharedPreferences bool `ride_playback_show_route_map` |
| Online map consent | Playback, first map expansion | SharedPreferences bool `ride_playback_online_map_consent` |
| Segment check | Playback, and Unlock | Each newly computed segment hash is stored in the [ride index](data-formats.md#ride-index-cache) (outside the recordings directory) |
| Everything else in playback | Playback | Reads only (telemetry JSON, segment hashing, decoder probes). The only other disk writes are the map tiles flutter_map caches under `fm_cache` (see [Route map](#route-map)) |

The re-verification in `changeLockState` hashes through `SegmentVerifier.lockHasher`: a segment with a still-valid stored result (for example one checked when the ride was played) is not hashed again, and the others are hashed one per `Isolate.run` call and stored. Reading the JSON and computing its payload hash still run on the UI isolate. After a successful unlock the ride's index entry is removed (the JSON changed) and the reload decodes it again. The unlock button cannot be pressed twice: `_lockUpdatesInFlight` replaces it with the progress ring and makes a second call return at once, and `changeLockState` itself runs under `runExclusiveForPath` for the file.

**Delete.** Each card has a delete button:

- A locked ride that can be unlocked is not deleted: "This ride has locked clips. Unlock it first to delete it." (3 s).
- A locked ride whose lock cannot be removed (status `modified` or quarantined paths) can be deleted after a warning, so it never becomes impossible to remove in-app. Automatic deletion never removes locked footage.
- The dialog "Delete this ride?" says "This permanently deletes the ride's N video segment(s) and its telemetry from this device. Copies already exported to the gallery are not affected.", prefixed for a stuck lock with "This ride has locked clips and failed the integrity check, so it cannot be unlocked."
- On confirmation, `deleteRideFiles` ([ride_deletion.dart](../lib/features/history/services/ride_deletion.dart), shared with the storage budget) deletes the ride's files as `filesOfRide` lists them: its trusted segment files and `videoPath`, then its telemetry JSON last. Quarantined paths and anything outside the ride's own directory (the telemetry JSON's directory, or the video's for a video-only ride) are never deleted. The ride's ride index entry is dropped, with the segment hashes no remaining entry lists. Once the telemetry JSON is gone, the ride's `rideSessionId` and its segment file names are removed from the signed-ride registry, but only when the deleted file has the ride's own name (`ride_<id>.telemetry.json`); deleting a copy that carries another ride's id leaves that ride registered. The list reloads and shows "Ride deleted." or "Ride deleted, but N file(s) could not be removed." (3 s).

**Import from an older version.** Android only (the menu is not built elsewhere). `_importFromOlderVersion`:

1. Refuses with `CameraProvider.legacyImportBlockedReason` when a recording starts, runs or stops, rides are being moved, the storage budget runs or an import runs.
2. Explains the folder in a dialog ("Import rides from an older version": the old versions saved rides in Movies/MotoCam/Recordings, other apps can read them including each ride's GPS route, they stay after uninstall; tap "Use this folder" and allow access; nothing in the folder is changed), with Cancel and Choose folder.
3. Opens the system folder picker (`LegacyRecordingsAccess.pickRecordingsTree`, starting in that folder on Android 8 and later). Cancelling ends the flow; a missing picker shows "Could not open the folder picker on this phone.".
4. Runs `CameraProvider.importLegacyRides` with the picked tree, reloads the list and shows the summary (6 s), for example "Imported 3 rides. 1 ride had been imported before. 1 ride skipped: a different file with the same name is already in private storage." A paused run says that recording started and to import again; a low-storage stop names the rides left.
5. After a completed run with files that have a verified private copy (never a lone video that was already there, which is most likely a gallery copy), asks "Delete the originals?" (the imported rides are now private; the N original files in Movies/MotoCam/Recordings can still be read by other apps, GPS routes included, and stay after uninstall; files that were not imported are left alone). "Keep originals" is the default (autofocused; dismissing the dialog keeps them too). "Delete originals" calls `deleteImportedOriginals` for exactly the imported documents, ride JSONs first, and reports "Deleted N original files from Movies/MotoCam/Recordings." or "Deleted a of N original files. k could not be deleted (for example <name>); remove them with a file manager." (8 s).

Imported files are byte for byte, so a ride keeps its badges and locks; v0.1.11/v0.1.12 rides have no integrity envelope and show `UNVERIFIED` ("recorded by an older version"), as they did. Their declared paths point at the public folder and are read through the public-folder rule of path resolution (above), so a ride reads the same before and after its originals are deleted. The import rules are in [data-formats.md](data-formats.md#import-from-the-old-public-folder).

`setLockState(true)` exists (it locks every trusted segment), but the app never calls it. Related actions that happen elsewhere:

| Action | Where it happens |
|---|---|
| Lock | During recording only, via `CameraProvider.markIncident`; the locked paths are persisted with the ride ([recording-pipeline.md](recording-pipeline.md)) |
| Export to gallery | Android only, and only when the rider turned on the gallery-export setting (`exportLockedClipsToGallery`, default off): at stop, locked segments of the session are queued for export to the public gallery through the `com.example.motocam/media` channel ([platform-integration.md](platform-integration.md)) |
| Automatic deletion | Recording-side code only. Loop roll-over deletes the oldest unlocked segments of the current session (`selectSegmentsToEvict`). About 2 s after a stop, `_pruneOrphanTelemetryFiles` deletes telemetry files with no segment paths or no remaining segment files, skipping any file with locked paths. When the rider turned on the storage budget (off by default), whole unlocked past rides are deleted oldest first while recording, through the same `deleteRideFiles` as the Delete action ([recording-pipeline.md](recording-pipeline.md#storage-budget)); otherwise past rides are never aged out |
| Share, playback speed, volume | Not implemented |

Persisted `lockedSegmentPaths` are read by `RideRecord` (list grouping, badge, lock markers) and by the orphan-telemetry prune, which never deletes a file that lists locked paths. Loop roll-over consults only the current session's in-memory lock set and never touches the files of earlier rides. The storage budget never selects a ride that lists any locked segment.
