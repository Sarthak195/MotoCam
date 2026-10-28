/// The gallery-link store: what MotoCam copied to the phone's gallery and
/// what it still has to copy (Android).
///
/// It lives outside the recordings directory, in
/// `<application support>/gallery_links/gallery_links.json`, and never in
/// a ride JSON (that file is hashed and signed, so it stays byte-identical).
/// Entries are keyed by the ride's `rideSessionId` plus the segment's file
/// name, never by a full path, because rides move (the migration into
/// private storage, the import); a video without a ride id is keyed by its
/// file name alone. See [galleryLinkKey].
///
/// * [GalleryLinkData.links]: the gallery copies made, each with the
///   content URI `exportVideoToGallery` returned, so Ride History can offer
///   to remove them when the ride is unlocked or deleted.
/// * [GalleryLinkData.pending]: the export queue. Segments are added before
///   they are copied, so a queue that a killed process left behind is
///   retried at the next launch; a successful copy moves its entry from
///   `pending` to `links`.
///
/// The layout is described in docs/data-formats.md.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/utils/integrity_utils.dart' as integrity_utils;
import '../../../core/utils/path_utils.dart' as path_utils;
import '../models/ride_record.dart';
import 'ride_deletion.dart';

/// Format number written to the store; a file with any other number is read
/// as empty.
const int galleryLinksFormatVersion = 1;

/// Name of the directory under the application support directory that
/// holds the store.
const String galleryLinksDirectoryName = 'gallery_links';

/// File name of the store.
const String galleryLinksFileName = 'gallery_links.json';

/// The store key of a segment: `<rideSessionId>|<file name>`, or the file
/// name alone when the video has no ride id (a video-only ride).
String galleryLinkKey({String? rideSessionId, required String fileName}) {
  final id = rideSessionId?.trim() ?? '';
  return id.isEmpty ? fileName : '$id|$fileName';
}

/// The video files of [ride] that may be copied to the gallery, by store
/// key: its trusted segment files and main video (never its telemetry JSON,
/// which holds the GPS route, never a quarantined path and never a file
/// outside the ride's own directory; see [filesOfRide]).
Map<String, String> galleryKeysOfRide(RideRecord ride) {
  final telemetryPath = ride.telemetryPath;
  final telemetryKey = telemetryPath == null
      ? null
      : path_utils.normalizePath(telemetryPath);
  final keys = <String, String>{};
  for (final path in filesOfRide(ride)) {
    if (path_utils.normalizePath(path) == telemetryKey) {
      continue;
    }
    keys.putIfAbsent(
      galleryLinkKey(
        rideSessionId: ride.rideSessionId,
        fileName: path_utils.fileNameFromPath(path),
      ),
      () => path,
    );
  }
  return keys;
}

/// One gallery copy MotoCam made.
@immutable
class GalleryLink {
  /// Creates a link.
  const GalleryLink({
    required this.rideSessionId,
    required this.fileName,
    required this.contentUri,
    required this.displayName,
    required this.relativePath,
    required this.exportedAt,
  });

  /// The ride's id, or `null` for a video without a ride id.
  final String? rideSessionId;

  /// File name of the private segment that was copied.
  final String fileName;

  /// The MediaStore content URI of the copy, as `exportVideoToGallery`
  /// returned it.
  final String contentUri;

  /// The display name requested for the copy (the system may have renamed
  /// it to avoid a clash).
  final String displayName;

  /// The gallery folder of the copy, for example `Movies/MotoCam/Recordings`.
  final String relativePath;

  /// When the copy was made.
  final DateTime exportedAt;

  /// The store key of this link.
  String get key =>
      galleryLinkKey(rideSessionId: rideSessionId, fileName: fileName);

  /// The link as stored in the file.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'rideSessionId': rideSessionId,
    'fileName': fileName,
    'contentUri': contentUri,
    'displayName': displayName,
    'relativePath': relativePath,
    'exportedAtMs': exportedAt.millisecondsSinceEpoch,
  };

  /// Parses a stored link, or returns `null` when [json] is malformed.
  static GalleryLink? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final fileName = json['fileName'];
    final contentUri = json['contentUri'];
    final exportedAtMs = json['exportedAtMs'];
    final rideSessionId = json['rideSessionId'];
    if (fileName is! String ||
        fileName.isEmpty ||
        contentUri is! String ||
        contentUri.isEmpty ||
        exportedAtMs is! int ||
        (rideSessionId != null && rideSessionId is! String)) {
      return null;
    }
    final displayName = json['displayName'];
    final relativePath = json['relativePath'];
    return GalleryLink(
      rideSessionId: rideSessionId as String?,
      fileName: fileName,
      contentUri: contentUri,
      displayName: displayName is String ? displayName : fileName,
      relativePath: relativePath is String ? relativePath : '',
      exportedAt: DateTime.fromMillisecondsSinceEpoch(exportedAtMs),
    );
  }
}

/// One segment waiting to be copied to the gallery.
@immutable
class PendingGalleryExport {
  /// Creates a pending entry.
  const PendingGalleryExport({
    required this.rideSessionId,
    required this.fileName,
    required this.sourcePath,
    required this.queuedAt,
    this.attempts = 0,
  });

  /// The ride's id, or `null` for a video without a ride id.
  final String? rideSessionId;

  /// File name of the private segment; the file is found again by this
  /// name when [sourcePath] no longer exists (the ride moved).
  final String fileName;

  /// Where the segment was when it was queued.
  final String sourcePath;

  /// When the segment was queued.
  final DateTime queuedAt;

  /// Failed copy attempts so far.
  final int attempts;

  /// The store key of this entry.
  String get key =>
      galleryLinkKey(rideSessionId: rideSessionId, fileName: fileName);

  /// This entry with [attempts] set.
  PendingGalleryExport withAttempts(int attempts) => PendingGalleryExport(
    rideSessionId: rideSessionId,
    fileName: fileName,
    sourcePath: sourcePath,
    queuedAt: queuedAt,
    attempts: attempts,
  );

  /// The entry as stored in the file.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'rideSessionId': rideSessionId,
    'fileName': fileName,
    'sourcePath': sourcePath,
    'queuedAtMs': queuedAt.millisecondsSinceEpoch,
    'attempts': attempts,
  };

  /// Parses a stored entry, or returns `null` when [json] is malformed.
  static PendingGalleryExport? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final fileName = json['fileName'];
    final sourcePath = json['sourcePath'];
    final queuedAtMs = json['queuedAtMs'];
    final rideSessionId = json['rideSessionId'];
    if (fileName is! String ||
        fileName.isEmpty ||
        sourcePath is! String ||
        queuedAtMs is! int ||
        (rideSessionId != null && rideSessionId is! String)) {
      return null;
    }
    final attempts = json['attempts'];
    return PendingGalleryExport(
      rideSessionId: rideSessionId as String?,
      fileName: fileName,
      sourcePath: sourcePath,
      queuedAt: DateTime.fromMillisecondsSinceEpoch(queuedAtMs),
      attempts: attempts is int && attempts > 0 ? attempts : 0,
    );
  }
}

/// The content of the store: gallery copies made and segments still to
/// copy, both by [galleryLinkKey].
class GalleryLinkData {
  /// Creates the data; both maps default to empty.
  GalleryLinkData({
    Map<String, GalleryLink>? links,
    Map<String, PendingGalleryExport>? pending,
  }) : links = links ?? <String, GalleryLink>{},
       pending = pending ?? <String, PendingGalleryExport>{};

  /// Gallery copies by key.
  final Map<String, GalleryLink> links;

  /// The export queue by key, in the order segments were queued.
  final Map<String, PendingGalleryExport> pending;

  /// The links of [ride]'s video files ([galleryKeysOfRide]).
  List<GalleryLink> linksOfRide(RideRecord ride) => <GalleryLink>[
    for (final key in galleryKeysOfRide(ride).keys) ?links[key],
  ];

  /// The data as stored in the file.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'format': galleryLinksFormatVersion,
    'links': <String, dynamic>{
      for (final entry in links.entries) entry.key: entry.value.toJson(),
    },
    'pending': <String, dynamic>{
      for (final entry in pending.entries) entry.key: entry.value.toJson(),
    },
  };

  /// Parses the file content [raw]. Content that is not JSON, has another
  /// format number or is not shaped like the store gives empty data; a
  /// malformed entry is skipped. Each entry is filed under the key its own
  /// fields give. Never throws.
  static GalleryLinkData parse(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['format'] != galleryLinksFormatVersion) {
        return GalleryLinkData();
      }
      final data = GalleryLinkData();
      final links = json['links'];
      if (links is Map) {
        for (final value in links.values) {
          final link = GalleryLink.fromJson(value);
          if (link != null) {
            data.links[link.key] = link;
          }
        }
      }
      final pending = json['pending'];
      if (pending is Map) {
        for (final value in pending.values) {
          final entry = PendingGalleryExport.fromJson(value);
          if (entry != null) {
            data.pending[entry.key] = entry;
          }
        }
      }
      return data;
    } catch (_) {
      return GalleryLinkData();
    }
  }
}

/// The one reader and writer of the store file, used on the UI isolate
/// only.
///
/// It keeps the data in memory once read. Every change goes through
/// [update], which applies it, notifies listeners and writes the whole file
/// atomically (temp file plus rename); writes are queued, so none is lost.
/// A missing or corrupt file reads as empty: the next write replaces it.
class GalleryLinkStore extends ChangeNotifier {
  /// Creates a store for the file [file]. The app uses [shared].
  GalleryLinkStore(this.file);

  /// The store file.
  final File file;

  GalleryLinkData? _memory;
  Future<GalleryLinkData>? _loading;

  static Future<GalleryLinkStore?>? _shared;

  /// The app's store at
  /// `<application support>/gallery_links/gallery_links.json`, or `null`
  /// when that directory is unavailable (then nothing is queued or
  /// remembered). Resolved with path_provider, so call it on the UI
  /// isolate.
  static Future<GalleryLinkStore?> shared() {
    return _shared ??= () async {
      try {
        final support = await getApplicationSupportDirectory();
        final sep = Platform.pathSeparator;
        return GalleryLinkStore(
          File(
            '${support.path}$sep$galleryLinksDirectoryName$sep'
            '$galleryLinksFileName',
          ),
        );
      } catch (_) {
        return null;
      }
    }();
  }

  /// Replaces the store [shared] returns; for tests only.
  @visibleForTesting
  static set sharedForTesting(GalleryLinkStore? store) {
    _shared = Future<GalleryLinkStore?>.value(store);
  }

  /// Resets [shared] so the next call resolves the directory again; for
  /// tests only.
  @visibleForTesting
  static void resetShared() {
    _shared = null;
  }

  /// The in-memory data, read from [file] on first use.
  Future<GalleryLinkData> read() {
    final memory = _memory;
    if (memory != null) {
      return Future<GalleryLinkData>.value(memory);
    }
    return _loading ??= () async {
      GalleryLinkData data;
      try {
        data = await file.exists()
            ? GalleryLinkData.parse(await file.readAsString())
            : GalleryLinkData();
      } catch (_) {
        data = GalleryLinkData();
      }
      return _memory ??= data;
    }();
  }

  /// Applies [change] to the in-memory data, notifies listeners and writes
  /// the file; completes once the write finished. Returns `false` when the
  /// write failed (the change stays in memory for this process).
  Future<bool> update(void Function(GalleryLinkData data) change) async {
    final data = await read();
    change(data);
    notifyListeners();
    return _write(data);
  }

  Future<bool> _writes = Future<bool>.value(true);

  Future<bool> _write(GalleryLinkData data) {
    return _writes = _writes.then((_) async {
      try {
        await integrity_utils.writeTelemetryAtomically(
          telemetryFile: file,
          content: jsonEncode(data.toJson()),
        );
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  /// Drops every link and pending entry of [ride] whose video file is gone
  /// (the ride, or part of it, was deleted). Gallery copies themselves are
  /// never touched here.
  Future<void> forgetDeletedFilesOf(RideRecord ride) async {
    final gone = <String>[];
    for (final entry in galleryKeysOfRide(ride).entries) {
      var exists = true;
      try {
        exists = await File(entry.value).exists();
      } catch (_) {
        exists = true;
      }
      if (!exists) {
        gone.add(entry.key);
      }
    }
    if (gone.isEmpty) {
      return;
    }
    final data = await read();
    if (!gone.any(
      (key) => data.links.containsKey(key) || data.pending.containsKey(key),
    )) {
      return;
    }
    await update((data) {
      for (final key in gone) {
        data.links.remove(key);
        data.pending.remove(key);
      }
    });
  }
}
