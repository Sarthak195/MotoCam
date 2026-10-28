import 'dart:io';
import 'dart:isolate';

import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../../../core/ride_file/ride_telemetry_codec.dart'
    show
        RideIncident,
        RideIntegrityReport,
        RideIntegrityStatus,
        RideSegmentTimelineEntry,
        RideSignedBy,
        RideSignerContext;
import '../../../core/services/ride_signing_service.dart';
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import '../../telemetry/models/telemetry_data.dart';

// The ride-file types live in the codec; existing callers keep importing
// them from here.
export '../../../core/ride_file/ride_telemetry_codec.dart'
    show
        RideIncident,
        RideIntegrityReport,
        RideIntegrityStatus,
        RideSegmentTimelineEntry,
        RideSignedBy,
        RideSignerContext;

/// Represents a persisted ride session loaded from a telemetry JSON file.
///
/// A ride record holds references to video segments, GPS/telemetry samples,
/// integrity verification results, and summary statistics (distance, speed).
/// It is the primary data model consumed by the ride history and playback
/// screens.
///
/// Ride History works with sample-less records ([samplesLoaded] `false`):
/// they carry [sampleCount] and [duration] but an empty [samples] list.
/// Playback needs the samples and loads them with [loadSamples].
///
/// Segment paths are resolved against the directory that holds the
/// telemetry file: a declared absolute path that no longer exists (for
/// example after the iOS data-container path changed) is replaced by the
/// same file name in that directory when such a file exists. Only that
/// directory is trusted; declared paths outside it are quarantined.
class RideRecord {
  /// Creates a ride record. Prefer [fromTelemetryFile] or [fromVideoFile].
  RideRecord({
    required this.videoPath,
    required this.segmentPaths,
    required this.lockedSegmentPaths,
    required this.createdAt,
    required this.telemetryPath,
    required this.rideSessionId,
    required this.isSessionComplete,
    required this.distanceKm,
    required this.maxSpeedKmh,
    required this.averageSpeedKmh,
    required this.segmentTimeline,
    required this.samples,
    required this.integrity,
    required this.quarantinedSegmentPaths,
    this.missingSegmentPaths = const <String>[],
    this.incidents,
    this.mockLocationDetected = false,
    this.expectedSegmentHashes = const <String, String>{},
    this.samplesLoaded = true,
    int? sampleCount,
    int? lastSampleElapsedMs,
  }) : assert(
         samplesLoaded || samples.isEmpty,
         'A sample-less ride must not carry samples.',
       ),
       sampleCount = sampleCount ?? samples.length,
       lastSampleElapsedMs =
           lastSampleElapsedMs ??
           (samples.isEmpty ? 0 : samples.last.elapsedMs);

  /// Lower-case file extensions treated as ride video files.
  static const List<String> videoFileExtensions =
      ride_codec.rideVideoFileExtensions;

  /// Returns `true` when [path] ends with one of [videoFileExtensions].
  static bool isVideoFilePath(String path) =>
      ride_codec.isRideVideoFilePath(path);

  /// Path of the ride's main (last) video segment.
  final String videoPath;

  /// Trusted segment paths in recording order, resolved against the
  /// telemetry file's directory. May include files that no longer exist;
  /// those are also listed in [missingSegmentPaths].
  final List<String> segmentPaths;

  /// Locked segments (manual LOCK or automatic incident locks); a subset of
  /// [segmentPaths].
  final List<String> lockedSegmentPaths;

  /// Ride start time in local time, or the file modification time when
  /// unknown.
  final DateTime createdAt;

  /// Path of the ride JSON, or `null` for a video-only (recovered) ride.
  final String? telemetryPath;

  /// Session identifier written by the recorder, if any.
  final String? rideSessionId;

  /// Whether the recorder marked the session as complete.
  final bool isSessionComplete;

  /// Total ride distance in kilometres.
  final double distanceKm;

  /// Maximum speed in km/h.
  final double maxSpeedKmh;

  /// Average speed in km/h.
  final double averageSpeedKmh;

  /// Start/end offsets of each segment within the ride, sorted by start.
  final List<RideSegmentTimelineEntry> segmentTimeline;

  /// Telemetry samples in file order (the recorder writes them by elapsed
  /// time); malformed entries are skipped. Empty when [samplesLoaded] is
  /// `false`.
  final List<TelemetryData> samples;

  /// Whether [samples] holds the ride's samples. Records built for Ride
  /// History (from the ride index or with `loadSamples: false`) do not;
  /// use [loadSamples] before reading samples.
  final bool samplesLoaded;

  /// Number of samples in the ride file, known even when [samplesLoaded] is
  /// `false`.
  final int sampleCount;

  /// `elapsedMs` of the last sample (0 when there is none), known even when
  /// [samplesLoaded] is `false`.
  final int lastSampleElapsedMs;

  /// Result of the most recent integrity check. Records read from a file
  /// carry the report from the file alone; [withSignerContext] adds who
  /// signed the ride and the `signature-removed` check.
  final RideIntegrityReport integrity;

  /// Declared segment paths rejected because they lie outside the
  /// directory that holds the telemetry file.
  final List<String> quarantinedSegmentPaths;

  /// Entries of [segmentPaths] whose files no longer exist. A missing file
  /// makes the ride incomplete; on its own it is not an integrity failure.
  final List<String> missingSegmentPaths;

  /// Incidents detected live during the ride, from the optional top-level
  /// `incidents` list, or `null` for files written before that key existed
  /// (playback then derives markers from the samples).
  final List<RideIncident>? incidents;

  /// Whether the recorder saw a mock (simulated) location provider during
  /// the ride (optional top-level `mockLocationDetected`, default `false`).
  final bool mockLocationDetected;

  /// The SHA-256 recorded in the integrity envelope for each trusted
  /// segment, keyed by its resolved path. Segments without a recorded hash
  /// are absent.
  final Map<String, String> expectedSegmentHashes;

  /// File name of [videoPath].
  String get fileName => path_utils.fileNameFromPath(videoPath);

  /// Whether any segment of the ride is locked.
  bool get isLocked => lockedSegmentPaths.isNotEmpty;

  /// Whether any declared segment path was quarantined.
  bool get hasQuarantinedSegments => quarantinedSegmentPaths.isNotEmpty;

  /// Whether any declared segment file no longer exists.
  bool get hasMissingSegments => missingSegmentPaths.isNotEmpty;

  /// Number of [segmentPaths] whose files still exist.
  int get availableSegmentCount =>
      segmentPaths.where((path) => !missingSegmentPaths.contains(path)).length;

  /// Ride duration taken from the last sample's elapsed time.
  Duration get duration {
    if (sampleCount == 0) {
      return Duration.zero;
    }
    return Duration(milliseconds: lastSampleElapsedMs);
  }

  /// Returns the telemetry at [position], linearly interpolated between the
  /// two nearest samples and clamped to the first and last sample.
  ///
  /// Position is never interpolated across a sample without a GPS fix: when
  /// either neighbour has `hasFix == false`, the neighbour with a fix
  /// supplies latitude, longitude and bearing (or the nearest sample is
  /// returned when neither has a fix). Bearing is interpolated along the
  /// shortest arc (see [interpolateBearing]).
  ///
  /// A ride without samples, including a sample-less record whose file
  /// could not be re-read by [loadSamples], gives [TelemetryData.empty].
  TelemetryData sampleForPosition(Duration position) {
    if (samples.isEmpty) {
      return TelemetryData.empty();
    }

    final targetMs = position.inMilliseconds;
    if (targetMs <= samples.first.elapsedMs) {
      return samples.first;
    }
    if (targetMs >= samples.last.elapsedMs) {
      return samples.last;
    }

    var low = 0;
    var high = samples.length - 1;

    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final sample = samples[mid];
      if (sample.elapsedMs == targetMs) {
        return sample;
      }
      if (sample.elapsedMs < targetMs) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    final upperIndex = low.clamp(1, samples.length - 1);
    final lowerIndex = (upperIndex - 1).clamp(0, samples.length - 1);
    final lower = samples[lowerIndex];
    final upper = samples[upperIndex];

    final spanMs = (upper.elapsedMs - lower.elapsedMs).abs();
    if (spanMs == 0) {
      return lower;
    }

    final t = ((targetMs - lower.elapsedMs) / spanMs).clamp(0.0, 1.0);
    final timestamp = lower.timestamp.add(
      Duration(milliseconds: targetMs - lower.elapsedMs),
    );

    if (!lower.hasFix || !upper.hasFix) {
      final nearest = t < 0.5 ? lower : upper;
      final TelemetryData? fixed = lower.hasFix
          ? lower
          : (upper.hasFix ? upper : null);
      if (fixed == null) {
        return nearest;
      }
      return TelemetryData(
        latitude: fixed.latitude,
        longitude: fixed.longitude,
        speed: fixed.speed,
        bearing: fixed.bearing,
        accelerationG: _lerp(lower.accelerationG, upper.accelerationG, t),
        elapsedMs: targetMs,
        distanceKm: _lerp(lower.distanceKm, upper.distanceKm, t),
        timestamp: timestamp,
        hasFix: true,
        fixAgeMs: fixed.fixAgeMs,
      );
    }

    return TelemetryData(
      latitude: _lerp(lower.latitude, upper.latitude, t),
      longitude: _lerp(lower.longitude, upper.longitude, t),
      speed: _lerp(lower.speed, upper.speed, t),
      bearing: interpolateBearing(lower.bearing, upper.bearing, t),
      accelerationG: _lerp(lower.accelerationG, upper.accelerationG, t),
      elapsedMs: targetMs,
      distanceKm: _lerp(lower.distanceKm, upper.distanceKm, t),
      timestamp: timestamp,
    );
  }

  /// This ride with its [integrity] derived for [context] (see
  /// `applySignerContext`): who signed it, and `signature-removed` when this
  /// install wrote it signed but it no longer is. A `null` [context] gives
  /// the report from the file alone.
  RideRecord withSignerContext(RideSignerContext? context) {
    final report = ride_codec.applySignerContext(
      integrity,
      rideSessionId: rideSessionId,
      context: context,
    );
    if (identical(report, integrity)) {
      return this;
    }
    return _withIntegrity(report);
  }

  RideRecord _withIntegrity(
    RideIntegrityReport report, {
    List<String>? quarantinedSegmentPaths,
    List<String>? missingSegmentPaths,
  }) {
    return RideRecord(
      videoPath: videoPath,
      segmentPaths: segmentPaths,
      lockedSegmentPaths: lockedSegmentPaths,
      createdAt: createdAt,
      telemetryPath: telemetryPath,
      rideSessionId: rideSessionId,
      isSessionComplete: isSessionComplete,
      distanceKm: distanceKm,
      maxSpeedKmh: maxSpeedKmh,
      averageSpeedKmh: averageSpeedKmh,
      segmentTimeline: segmentTimeline,
      samples: samples,
      samplesLoaded: samplesLoaded,
      sampleCount: sampleCount,
      lastSampleElapsedMs: lastSampleElapsedMs,
      integrity: report,
      quarantinedSegmentPaths:
          quarantinedSegmentPaths ?? this.quarantinedSegmentPaths,
      missingSegmentPaths: missingSegmentPaths ?? this.missingSegmentPaths,
      incidents: incidents,
      mockLocationDetected: mockLocationDetected,
      expectedSegmentHashes: expectedSegmentHashes,
    );
  }

  /// Interpolates between bearings [a] and [b] (degrees) along the shortest
  /// arc, returning a value in `[0, 360)`. A negative bearing means
  /// "unavailable": the other value is returned instead (or `-1` when both
  /// are unavailable).
  static double interpolateBearing(double a, double b, double t) {
    final aValid = a.isFinite && a >= 0;
    final bValid = b.isFinite && b >= 0;
    if (!aValid && !bValid) {
      return -1;
    }
    if (!aValid) {
      return b % 360;
    }
    if (!bValid) {
      return a % 360;
    }
    var delta = (b - a) % 360; // [0, 360)
    if (delta > 180) {
      delta -= 360; // (-180, 180]
    }
    final result = (a + delta * t) % 360;
    return result < 0 ? result + 360 : result;
  }

  static double _lerp(double a, double b, double t) => a + ((b - a) * t);

  /// Builds a ride for a video file that no ride JSON references.
  ///
  /// If a `<video name>.telemetry.json` file sits next to the video and
  /// references it, the ride is loaded from it. Otherwise a video-only ride
  /// is returned with no telemetry, [RideIntegrityStatus.unknown] and
  /// [telemetryPath] `null` (so a sibling JSON that describes other
  /// segments is not listed a second time in place of this video).
  ///
  /// [loadSamples] is passed on to [fromTelemetryFile].
  static Future<RideRecord> fromVideoFile(
    File videoFile, {
    bool verifySegments = false,
    bool loadSamples = true,
  }) async {
    final telemetryFile = File(
      ride_codec.legacyTelemetryPathForVideo(videoFile.path),
    );
    if (await telemetryFile.exists()) {
      final ride = await fromTelemetryFile(
        telemetryFile,
        verifySegments: verifySegments,
        loadSamples: loadSamples,
      );
      final videoKey = path_utils.normalizePath(videoFile.path);
      if (ride != null &&
          <String>[
            ride.videoPath,
            ...ride.segmentPaths,
          ].any((path) => path_utils.normalizePath(path) == videoKey)) {
        return ride;
      }
    }

    return RideRecord(
      videoPath: videoFile.path,
      segmentPaths: <String>[videoFile.path],
      lockedSegmentPaths: const <String>[],
      createdAt: (await videoFile.stat()).modified,
      telemetryPath: null,
      rideSessionId: null,
      isSessionComplete: true,
      distanceKm: 0,
      maxSpeedKmh: 0,
      averageSpeedKmh: 0,
      segmentTimeline: const <RideSegmentTimelineEntry>[],
      samples: const <TelemetryData>[],
      integrity: const RideIntegrityReport.unknown(),
      quarantinedSegmentPaths: const <String>[],
    );
  }

  /// Loads a ride from its telemetry JSON, or returns `null` when the file
  /// is missing, unreadable, malformed or names no video.
  ///
  /// The payload hash is always checked. Segment files are hashed only when
  /// [verifySegments] is `true` (see [verifySegmentIntegrity]). With
  /// [loadSamples] `false` the record is sample-less ([samplesLoaded]
  /// `false`): only the sample count and the last `elapsedMs` are read.
  static Future<RideRecord?> fromTelemetryFile(
    File telemetryFile, {
    bool verifySegments = false,
    bool loadSamples = true,
  }) async {
    if (!await telemetryFile.exists()) {
      return null;
    }

    try {
      final json = await ride_codec.readRideFileJson(telemetryFile);
      if (json == null) {
        return null;
      }

      final decoded = await ride_codec.decodeRideFile(
        telemetryFile: telemetryFile,
        json: json,
        verifySegments: verifySegments,
      );
      if (decoded == null) {
        return null;
      }

      final summary = decoded.summary;
      final segments = decoded.segments;
      final samples = loadSamples
          ? ride_codec.decodeRideSamples(json, TelemetryData.fromJson)
          : const <TelemetryData>[];
      final stats = loadSamples ? null : _sampleStats(json);
      return RideRecord(
        videoPath: segments.videoPath,
        segmentPaths: segments.segmentPaths,
        lockedSegmentPaths: decoded.lockedSegmentPaths,
        createdAt: summary.startedAt ?? (await telemetryFile.stat()).modified,
        telemetryPath: telemetryFile.path,
        rideSessionId: summary.rideSessionId,
        isSessionComplete: summary.sessionComplete,
        distanceKm: summary.distanceKm,
        maxSpeedKmh: summary.maxSpeedKmh,
        averageSpeedKmh: summary.averageSpeedKmh,
        segmentTimeline: decoded.segmentTimeline,
        samples: samples,
        samplesLoaded: loadSamples,
        sampleCount: stats?.count,
        lastSampleElapsedMs: stats?.lastElapsedMs,
        integrity: decoded.integrity,
        quarantinedSegmentPaths: segments.quarantinedSegmentPaths,
        missingSegmentPaths: segments.missingSegmentPaths,
        incidents: summary.incidents,
        mockLocationDetected: summary.mockLocationDetected,
        expectedSegmentHashes: ride_codec.expectedSegmentHashesFor(
          json,
          segments: segments,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Sample count and last `elapsedMs` of [json] without parsing every
  /// sample. It counts the entries `decodeRideSamples` keeps:
  /// [TelemetryData.fromJson] accepts every object entry.
  static ({int count, int lastElapsedMs}) _sampleStats(
    Map<String, dynamic> json,
  ) {
    final raw = json['samples'];
    if (raw is! List) {
      return (count: 0, lastElapsedMs: 0);
    }
    var count = 0;
    Map<dynamic, dynamic>? last;
    for (final entry in raw) {
      if (entry is Map) {
        count++;
        last = entry;
      }
    }
    if (last == null) {
      return (count: 0, lastElapsedMs: 0);
    }
    final sample = TelemetryData.fromJson(
      last.map((key, value) => MapEntry(key.toString(), value)),
    );
    return (count: count, lastElapsedMs: sample.elapsedMs);
  }

  /// Returns this ride with its samples: this record when [samplesLoaded]
  /// is already `true`, otherwise the ride re-read from [telemetryPath]
  /// (this record when that fails or there is no telemetry file). So a
  /// result with a [telemetryPath] and [samplesLoaded] `false` means the
  /// file could not be read again. The re-read ride keeps the signer
  /// context of this record's [integrity].
  ///
  /// Parsing a long ride takes a while; run it off the UI isolate.
  Future<RideRecord> loadSamples() async {
    final path = telemetryPath;
    if (samplesLoaded || path == null) {
      return this;
    }
    final ride = await fromTelemetryFile(File(path));
    return ride?.withSignerContext(integrity.signerContext) ?? this;
  }

  /// Locks ([locked] `true`) or unlocks every segment of this ride in its
  /// telemetry JSON, and returns whether the change was saved.
  ///
  /// The ride is re-read and fully re-verified, including segment hashes,
  /// first. The change is refused when any check fails or a path is
  /// quarantined. For a verified ride the existing segment hashes are kept
  /// and only the payload hash is recomputed; a legacy ride without an
  /// envelope is updated without creating one, so it stays unverified.
  ///
  /// A ride validly signed by this phone (or by an unknown signer, when
  /// this phone's key could not be read) is re-signed with [signer]
  /// (default: this phone's Keystore key through
  /// [RideSigningService.instance]) and stays a version 3 file. When the
  /// signer fails, or its key differs from the signer of a ride this phone
  /// signed, the change is refused and the file is left untouched. A ride
  /// signed by another key, or unsigned, is re-sealed as version 2: a
  /// foreign signature is dropped, since it signed the old hash.
  ///
  /// Segment files are hashed with [hashSegment]; Ride History passes one
  /// that reuses still-valid results from the ride index
  /// (`SegmentVerifier.lockHasher`) and hashes the rest off the UI isolate.
  /// Call it on the UI isolate (the signer uses a platform channel).
  Future<bool> setLockState(
    bool locked, {
    ride_codec.SegmentFileHasher hashSegment = ride_codec.hashSegmentFile,
    ride_codec.RidePayloadSigner? signer,
  }) async {
    if (integrity.status == RideIntegrityStatus.modified ||
        hasQuarantinedSegments) {
      return false;
    }

    final path = telemetryPath;
    if (path == null) {
      return false;
    }

    return integrity_utils.runExclusiveForPath<bool>(path, () async {
      try {
        final telemetryFile = File(path);
        if (!await telemetryFile.exists()) {
          return false;
        }

        final json = await ride_codec.readRideFileJson(telemetryFile);
        if (json == null) {
          return false;
        }

        final segments = await ride_codec.resolveRideSegments(
          telemetryFile: telemetryFile,
          json: json,
        );
        if (segments == null || segments.quarantinedSegmentPaths.isNotEmpty) {
          return false;
        }

        final report = await ride_codec.checkRideFileIntegrity(
          json: json,
          segments: segments,
          verifySegments: true,
          hashSegment: hashSegment,
        );
        if (report.status == RideIntegrityStatus.modified) {
          return false;
        }

        final facts = report.signature;
        final resign =
            report.status == RideIntegrityStatus.verified &&
            facts != null &&
            facts.valid &&
            integrity.signedBy != RideSignedBy.otherKey;
        if (!resign) {
          ride_codec.applyLockState(
            json,
            segments: segments,
            locked: locked,
            reseal: report.status == RideIntegrityStatus.verified,
          );
          await integrity_utils.writeTelemetryAtomically(
            telemetryFile: telemetryFile,
            content: ride_codec.encodeRideFileJson(json),
          );
          return true;
        }

        final payloadHash = ride_codec.applyLockState(
          json,
          segments: segments,
          locked: locked,
          reseal: true,
          envelopeVersion: ride_codec.signedIntegrityEnvelopeVersion,
        )!;
        final signature =
            await (signer ?? RideSigningService.instance.signPayloadHash)(
              payloadHash,
            );
        if (signature == null) {
          return false;
        }
        var updated = json;
        if (ride_codec.sameRideSigningKey(
          signature.publicKey,
          facts.signerPublicKey,
        )) {
          final valid = await Isolate.run(
            () => ride_codec.isValidRideSignature(signature, payloadHash),
          );
          if (!valid) {
            return false;
          }
          updated = ride_codec.withRideSignature(json, signature);
        } else if (integrity.signedBy == RideSignedBy.thisDevice) {
          // This phone signed the ride but now answers with another key.
          return false;
        } else {
          // The signer was unknown and is not this phone: drop the foreign
          // signature and seal as version 2.
          ride_codec.resealIntegrityEnvelope(json);
        }

        await integrity_utils.writeTelemetryAtomically(
          telemetryFile: telemetryFile,
          content: ride_codec.encodeRideFileJson(updated),
        );
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  /// Re-reads the telemetry JSON and returns a copy of this ride whose
  /// [integrity] also covers the SHA-256 of every existing segment file.
  ///
  /// Returns this ride unchanged when it has no telemetry file or the file
  /// cannot be read. Hashing can take a long time for long rides.
  Future<RideRecord> verifySegmentIntegrity() async {
    if (telemetryPath == null) {
      return this;
    }
    final telemetryFile = File(telemetryPath!);
    if (!await telemetryFile.exists()) {
      return this;
    }

    try {
      final json = await ride_codec.readRideFileJson(telemetryFile);
      if (json == null) {
        return this;
      }

      final segments = await ride_codec.resolveRideSegments(
        telemetryFile: telemetryFile,
        json: json,
      );
      if (segments == null) {
        return this;
      }

      final report = await ride_codec.checkRideFileIntegrity(
        json: json,
        segments: segments,
        verifySegments: true,
      );

      return _withIntegrity(
        ride_codec.applySignerContext(
          report,
          rideSessionId: rideSessionId,
          context: integrity.signerContext,
        ),
        quarantinedSegmentPaths: segments.quarantinedSegmentPaths,
        missingSegmentPaths: segments.missingSegmentPaths,
      );
    } catch (_) {
      return this;
    }
  }
}
