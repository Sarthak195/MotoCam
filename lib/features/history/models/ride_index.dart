/// The ride index: a persistent cache of what Ride History needs from each
/// ride file, plus the result of every segment hash computed by playback
/// and the lock flow.
///
/// It lives outside the recordings directory, in
/// `<application support>/ride_index/ride_index.json`, and is only a cache:
/// a missing, corrupt or older-format file is ignored and rebuilt from the
/// ride files, so it can be deleted at any time. The layout is described in
/// docs/data-formats.md.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/ride_file/ride_telemetry_codec.dart'
    show RideSignatureFacts;
import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import '../../telemetry/models/telemetry_data.dart';
import 'ride_record.dart';

/// Format number written to the index; a file with any other number is
/// ignored and rebuilt. Format 2 added the signature facts of each ride.
const int rideIndexFormatVersion = 2;

/// Name of the directory under the application support directory that
/// holds the index.
const String rideIndexDirectoryName = 'ride_index';

/// File name of the index.
const String rideIndexFileName = 'ride_index.json';

/// The identity of a file's current content as far as the index can tell
/// without reading it: size, modification time and change time.
///
/// `changed` is the inode change time on Linux and Android, which tools
/// such as `touch` cannot set back, so restoring a modification time does
/// not hide an edit. (On Windows it is the creation time.)
@immutable
class RideFileStamp {
  /// Creates a stamp from its parts (times in microseconds since the epoch).
  const RideFileStamp({
    required this.size,
    required this.modifiedUs,
    required this.changedUs,
  });

  /// File size in bytes.
  final int size;

  /// Modification time, microseconds since the epoch.
  final int modifiedUs;

  /// Change time (`FileStat.changed`), microseconds since the epoch.
  final int changedUs;

  /// The stamp as stored in the index.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'size': size,
    'modifiedUs': modifiedUs,
    'changedUs': changedUs,
  };

  /// Reads a stored stamp; throws when a part is missing or not an integer.
  factory RideFileStamp.fromJson(Map<String, dynamic> json) => RideFileStamp(
    size: json['size'] as int,
    modifiedUs: json['modifiedUs'] as int,
    changedUs: json['changedUs'] as int,
  );

  @override
  bool operator ==(Object other) =>
      other is RideFileStamp &&
      other.size == size &&
      other.modifiedUs == modifiedUs &&
      other.changedUs == changedUs;

  @override
  int get hashCode => Object.hash(size, modifiedUs, changedUs);

  @override
  String toString() => 'RideFileStamp($size, $modifiedUs, $changedUs)';
}

/// Returns the [RideFileStamp] of the file at a path, or `null` when there
/// is no file. Tests inject a fake one; the app uses [statRideFile].
typedef RideFileStatSource = Future<RideFileStamp?> Function(String path);

/// The default [RideFileStatSource]: one `FileStat.stat` call.
Future<RideFileStamp?> statRideFile(String path) async {
  try {
    final stat = await FileStat.stat(path);
    if (stat.type != FileSystemEntityType.file) {
      return null;
    }
    return RideFileStamp(
      size: stat.size,
      modifiedUs: stat.modified.microsecondsSinceEpoch,
      changedUs: stat.changed.microsecondsSinceEpoch,
    );
  } catch (_) {
    return null;
  }
}

/// Key of a file in the index: its normalised path.
String rideIndexKey(String path) => path_utils.normalizePath(path);

/// One ride in the index: the telemetry file's path and stamp when it was
/// decoded, and the sample-less [RideRecord] decoded from it.
///
/// Only what the file says is stored: the integrity report from the file
/// alone ([RideIntegrityReport.contentReport]) with its signature facts.
/// Who signed the ride is derived again on every load, because it depends
/// on this phone's key.
class RideIndexEntry {
  /// Creates an entry.
  const RideIndexEntry({
    required this.path,
    required this.stamp,
    required this.ride,
  });

  /// Telemetry file path as it was listed.
  final String path;

  /// Stamp of the telemetry file taken before it was decoded.
  final RideFileStamp stamp;

  /// The decoded ride, without samples ([RideRecord.samplesLoaded] is
  /// `false`). Only its content report is stored.
  final RideRecord ride;

  /// The entry as stored in the index.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    ...stamp.toJson(),
    'ride': _rideToJson(ride),
  };

  /// Reads a stored entry, or returns `null` when it is malformed.
  static RideIndexEntry? fromJson(Object? json) {
    try {
      final map = _stringMap(json);
      final path = map['path'] as String;
      return RideIndexEntry(
        path: path,
        stamp: RideFileStamp.fromJson(map),
        ride: _rideFromJson(_stringMap(map['ride']), telemetryPath: path),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A segment hash computed by playback or the lock flow, valid while the
/// segment file keeps its [stamp] and the ride's envelope keeps
/// [expectedHash].
@immutable
class SegmentHashEntry {
  /// Creates an entry.
  const SegmentHashEntry({
    required this.stamp,
    required this.expectedHash,
    required this.sha256,
  });

  /// Stamp of the segment file taken before it was hashed.
  final RideFileStamp stamp;

  /// The hash the ride's integrity envelope recorded for the segment.
  final String expectedHash;

  /// The SHA-256 computed from the file.
  final String sha256;

  /// Whether the computed hash equals the recorded one.
  bool get matches => sha256 == expectedHash;

  /// Whether this result still applies to a file with [currentStamp] whose
  /// envelope records [currentExpectedHash].
  bool isValidFor(RideFileStamp currentStamp, String currentExpectedHash) =>
      stamp == currentStamp && expectedHash == currentExpectedHash;

  /// The entry as stored in the index.
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...stamp.toJson(),
    'expectedHash': expectedHash,
    'sha256': sha256,
  };

  /// Reads a stored entry, or returns `null` when it is malformed.
  static SegmentHashEntry? fromJson(Object? json) {
    try {
      final map = _stringMap(json);
      return SegmentHashEntry(
        stamp: RideFileStamp.fromJson(map),
        expectedHash: map['expectedHash'] as String,
        sha256: map['sha256'] as String,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The content of the index file: ride entries keyed by the telemetry
/// file's [rideIndexKey], and segment hashes keyed by the segment's
/// [rideIndexKey].
class RideIndex {
  /// Creates an index; both maps default to empty.
  RideIndex({
    Map<String, RideIndexEntry>? rides,
    Map<String, SegmentHashEntry>? segmentHashes,
  }) : rides = rides ?? <String, RideIndexEntry>{},
       segmentHashes = segmentHashes ?? <String, SegmentHashEntry>{};

  /// Ride entries by telemetry file key.
  final Map<String, RideIndexEntry> rides;

  /// Segment hashes by segment file key.
  final Map<String, SegmentHashEntry> segmentHashes;

  /// The stored hash of the segment at [path] when it is still valid for
  /// [stamp] and [expectedHash], otherwise `null`.
  SegmentHashEntry? validSegmentHash(
    String path,
    RideFileStamp stamp,
    String expectedHash,
  ) {
    final entry = segmentHashes[rideIndexKey(path)];
    if (entry == null || !entry.isValidFor(stamp, expectedHash)) {
      return null;
    }
    return entry;
  }

  /// Drops every segment hash whose segment no ride entry lists.
  void pruneSegmentHashes() {
    final referenced = <String>{
      for (final entry in rides.values)
        for (final path in entry.ride.segmentPaths) rideIndexKey(path),
    };
    segmentHashes.removeWhere((key, _) => !referenced.contains(key));
  }

  /// The index as stored in the file.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'format': rideIndexFormatVersion,
    'rides': <String, dynamic>{
      for (final entry in rides.entries) entry.key: entry.value.toJson(),
    },
    'segmentHashes': <String, dynamic>{
      for (final entry in segmentHashes.entries)
        entry.key: entry.value.toJson(),
    },
  };

  /// Parses the file content [raw]. Content that is not JSON, has another
  /// format number or is not shaped like an index gives an empty index;
  /// a malformed entry is skipped. Never throws.
  static RideIndex parse(String raw) {
    try {
      final json = _stringMap(jsonDecode(raw));
      if (json['format'] != rideIndexFormatVersion) {
        return RideIndex();
      }
      final index = RideIndex();
      final rides = json['rides'];
      if (rides is Map) {
        for (final entry in rides.entries) {
          final ride = RideIndexEntry.fromJson(entry.value);
          if (ride != null) {
            index.rides[entry.key.toString()] = ride;
          }
        }
      }
      final hashes = json['segmentHashes'];
      if (hashes is Map) {
        for (final entry in hashes.entries) {
          final hash = SegmentHashEntry.fromJson(entry.value);
          if (hash != null) {
            index.segmentHashes[entry.key.toString()] = hash;
          }
        }
      }
      return index;
    } catch (_) {
      return RideIndex();
    }
  }

  /// Reads the index file at [path], or returns an empty index when it is
  /// missing, unreadable or invalid. Never throws.
  static Future<RideIndex> readFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return RideIndex();
      }
      return parse(await file.readAsString());
    } catch (_) {
      return RideIndex();
    }
  }
}

/// The one writer of the index file, used on the UI isolate only.
///
/// It keeps the index in memory once read. Every change goes through
/// [update], which applies it to the in-memory index and then writes the
/// whole index atomically (temp file plus rename); updates are queued, so
/// none is lost when several arrive at once. Background isolates read the
/// file (see [RideIndex.readFile]) but never write it.
///
/// Listeners are notified after each [update] has changed the in-memory
/// index (before its write), so a screen can show a result stored by work
/// it did not start, such as a segment hash that finishes after playback
/// was closed.
class RideIndexStore extends ChangeNotifier {
  /// Creates a store for the index at [file]. The app uses [shared].
  RideIndexStore(this.file);

  /// The index file.
  final File file;

  RideIndex? _memory;
  Future<RideIndex>? _loading;
  bool _pruneStarted = false;

  /// The in-memory index, or `null` until [read] has loaded it. It can be
  /// newer than the file while a write is queued.
  RideIndex? get loaded => _memory;

  static Future<RideIndexStore?>? _shared;

  /// The app's store at
  /// `<application support>/ride_index/ride_index.json`, or `null` when
  /// that directory is unavailable (the app then works without the cache).
  ///
  /// Resolved with path_provider, so call it on the UI isolate.
  static Future<RideIndexStore?> shared() {
    return _shared ??= () async {
      try {
        final support = await getApplicationSupportDirectory();
        final sep = Platform.pathSeparator;
        return RideIndexStore(
          File(
            '${support.path}$sep$rideIndexDirectoryName$sep$rideIndexFileName',
          ),
        );
      } catch (_) {
        return null;
      }
    }();
  }

  /// Replaces the store [shared] returns; for tests only.
  @visibleForTesting
  static set sharedForTesting(RideIndexStore? store) {
    _shared = Future<RideIndexStore?>.value(store);
  }

  /// Resets [shared] so the next call resolves the directory again; for
  /// tests only.
  @visibleForTesting
  static void resetShared() {
    _shared = null;
  }

  /// The in-memory index, read from [file] on first use (parsed on a
  /// background isolate). When [adopt] is given and nothing was read yet,
  /// it is used instead of reading the file again (it is the index a
  /// background isolate has just read). The first call, whichever path it
  /// takes, also deletes stale temp files of the index.
  Future<RideIndex> read({RideIndex? adopt}) {
    if (!_pruneStarted) {
      _pruneStarted = true;
      unawaited(_pruneStaleTempFiles());
    }
    final memory = _memory;
    if (memory != null) {
      return Future<RideIndex>.value(memory);
    }
    if (adopt != null && _loading == null) {
      _memory = adopt;
      return Future<RideIndex>.value(adopt);
    }
    return _loading ??= () async {
      final path = file.path;
      RideIndex index;
      try {
        index = await Isolate.run(() => RideIndex.readFile(path));
      } catch (_) {
        index = await RideIndex.readFile(path);
      }
      return _memory ??= index;
    }();
  }

  /// Deletes temp files that a killed write left next to the index
  /// (`ride_index.json.<suffix>.tmp`) once they are 10 minutes old.
  Future<void> _pruneStaleTempFiles() async {
    try {
      final directory = file.parent;
      if (!await directory.exists()) {
        return;
      }
      final prefix = '${path_utils.fileNameFromPath(file.path)}.';
      final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
      await for (final entity in directory.list(followLinks: false)) {
        final name = path_utils.fileNameFromPath(entity.path);
        if (entity is! File ||
            !name.startsWith(prefix) ||
            !name.endsWith('.tmp')) {
          continue;
        }
        try {
          if ((await entity.stat()).modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {
          // Skip files that vanish or cannot be deleted.
        }
      }
    } catch (_) {
      // Only a cache directory.
    }
  }

  /// Applies [change] to the in-memory index, notifies listeners and writes
  /// the index file. A failed write is ignored: the file is only a cache.
  Future<void> update(void Function(RideIndex index) change) async {
    final index = await read();
    change(index);
    notifyListeners();
    await _write(index);
  }

  Future<void> _writes = Future<void>.value();
  bool _dirty = false;

  /// Queues a write of [index] (the in-memory index). A queued write finds
  /// the index already written when an earlier queued write ran after this
  /// change, and then skips, so a burst of updates costs few writes.
  Future<void> _write(RideIndex index) {
    _dirty = true;
    return _writes = _writes.then((_) async {
      if (!_dirty) {
        return;
      }
      _dirty = false;
      await _writeNow(index);
    });
  }

  Future<void> _writeNow(RideIndex index) async {
    try {
      // The ride-file helper is a generic atomic write: a unique temp file
      // in the same directory, renamed over the target.
      await integrity_utils.writeTelemetryAtomically(
        telemetryFile: file,
        content: jsonEncode(index.toJson()),
      );
    } catch (_) {
      // Only a cache: the next load rebuilds what is missing.
    }
  }
}

Map<String, dynamic> _stringMap(Object? value) {
  if (value is! Map) {
    throw const FormatException('not an object');
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

double _finiteOrZero(double value) => value.isFinite ? value : 0;

List<String> _stringList(Object? value) =>
    (value as List).map((item) => item as String).toList(growable: false);

Map<String, dynamic> _rideToJson(RideRecord ride) => <String, dynamic>{
  'videoPath': ride.videoPath,
  'segmentPaths': ride.segmentPaths,
  'missingSegmentPaths': ride.missingSegmentPaths,
  'quarantinedSegmentPaths': ride.quarantinedSegmentPaths,
  'lockedSegmentPaths': ride.lockedSegmentPaths,
  'segmentTimeline': <Map<String, dynamic>>[
    for (final entry in ride.segmentTimeline) entry.toJson(),
  ],
  'createdAtUs': ride.createdAt.microsecondsSinceEpoch,
  'rideSessionId': ride.rideSessionId,
  'sessionComplete': ride.isSessionComplete,
  // JSON has no infinity or NaN: one such value would make every write of
  // the index throw, so it is stored as 0 (what the codec reads it as).
  'distanceKm': _finiteOrZero(ride.distanceKm),
  'maxSpeedKmh': _finiteOrZero(ride.maxSpeedKmh),
  'averageSpeedKmh': _finiteOrZero(ride.averageSpeedKmh),
  'sampleCount': ride.sampleCount,
  'lastSampleElapsedMs': ride.lastSampleElapsedMs,
  'incidents': ride.incidents == null
      ? null
      : <Map<String, dynamic>>[
          for (final incident in ride.incidents!)
            <String, dynamic>{
              'elapsedMs': incident.elapsedMs,
              if (incident.timestamp != null)
                'timestamp': incident.timestamp!.toUtc().toIso8601String(),
              if (incident.gForce != null) 'gForce': incident.gForce,
              if (incident.triggerGForce != null)
                'triggerGForce': incident.triggerGForce,
              if (incident.reason != null) 'reason': incident.reason,
            },
        ],
  'mockLocationDetected': ride.mockLocationDetected,
  'integrity': _integrityToJson(ride.integrity.contentReport),
  'expectedSegmentHashes': ride.expectedSegmentHashes,
};

Map<String, dynamic> _integrityToJson(RideIntegrityReport report) {
  final signature = report.signature;
  return <String, dynamic>{
    'status': report.status.name,
    'hasMetadata': report.hasMetadata,
    'issues': report.issues,
    // The signature outcome, so verification runs once per file version.
    'signature': signature == null
        ? null
        : <String, dynamic>{
            'publicKey': signature.signerPublicKey,
            'valid': signature.valid,
          },
  };
}

RideSignatureFacts? _signatureFromJson(Map<String, dynamic> integrityJson) {
  if (!integrityJson.containsKey('signature')) {
    throw const FormatException('no signature field');
  }
  final raw = integrityJson['signature'];
  if (raw == null) {
    return null;
  }
  final map = _stringMap(raw);
  return RideSignatureFacts(
    signerPublicKey: map['publicKey'] as String?,
    valid: map['valid'] as bool,
  );
}

RideRecord _rideFromJson(
  Map<String, dynamic> json, {
  required String telemetryPath,
}) {
  final integrityJson = _stringMap(json['integrity']);
  final status = RideIntegrityStatus.values.byName(
    integrityJson['status'] as String,
  );
  final signature = _signatureFromJson(integrityJson);
  final integrity = switch (status) {
    RideIntegrityStatus.unknown => const RideIntegrityReport.unknown(),
    RideIntegrityStatus.verified => RideIntegrityReport.verified(
      signature: signature,
    ),
    RideIntegrityStatus.modified => RideIntegrityReport.modified(
      _stringList(integrityJson['issues']),
      hasMetadata: integrityJson['hasMetadata'] as bool,
      signature: signature,
    ),
  };
  final rawIncidents = json['incidents'];
  return RideRecord(
    videoPath: json['videoPath'] as String,
    segmentPaths: _stringList(json['segmentPaths']),
    missingSegmentPaths: _stringList(json['missingSegmentPaths']),
    quarantinedSegmentPaths: _stringList(json['quarantinedSegmentPaths']),
    lockedSegmentPaths: _stringList(json['lockedSegmentPaths']),
    segmentTimeline: <RideSegmentTimelineEntry>[
      for (final raw in json['segmentTimeline'] as List)
        RideSegmentTimelineEntry(
          path: _stringMap(raw)['path'] as String,
          startMs: _stringMap(raw)['startMs'] as int,
          endMs: _stringMap(raw)['endMs'] as int,
        ),
    ],
    createdAt: DateTime.fromMicrosecondsSinceEpoch(json['createdAtUs'] as int),
    telemetryPath: telemetryPath,
    rideSessionId: json['rideSessionId'] as String?,
    isSessionComplete: json['sessionComplete'] as bool,
    distanceKm: (json['distanceKm'] as num).toDouble(),
    maxSpeedKmh: (json['maxSpeedKmh'] as num).toDouble(),
    averageSpeedKmh: (json['averageSpeedKmh'] as num).toDouble(),
    samples: const <TelemetryData>[],
    samplesLoaded: false,
    sampleCount: json['sampleCount'] as int,
    lastSampleElapsedMs: json['lastSampleElapsedMs'] as int,
    incidents: rawIncidents == null
        ? null
        : List<RideIncident>.unmodifiable(<RideIncident>[
            for (final raw in rawIncidents as List)
              RideIncident.fromJson(_stringMap(raw))!,
          ]),
    mockLocationDetected: json['mockLocationDetected'] as bool,
    integrity: integrity,
    expectedSegmentHashes: Map<String, String>.unmodifiable(
      _stringMap(
        json['expectedSegmentHashes'],
      ).map((key, value) => MapEntry(key, value as String)),
    ),
  );
}
