/// The native side of ride export (Android only): the system folder
/// picker, copies into a picked Storage Access Framework tree with a
/// read-back check, hashing for a share, the share sheet and the
/// keep-screen-on request. The native side is `RideExport.kt` (channel
/// `com.example.motocam/ride_export`); the contract is in the ride export
/// design, section 11.8.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thrown by a [RideExportNative] call that stopped because
/// [RideExportNative.cancel] was called (native error `CANCELLED`).
class RideExportCancelled implements Exception {
  /// Creates the exception.
  const RideExportCancelled();

  @override
  String toString() => 'RideExportCancelled';
}

/// Thrown by a [RideExportNative] call that failed. [code] is the native
/// error code (for example `WRITE_FAILED` or `EXISTS_DIFFERENT`), or
/// `UNAVAILABLE` when there is no native side, or `INVALID_REPLY` when the
/// reply had the wrong shape.
class RideExportFailure implements Exception {
  /// Creates a failure.
  const RideExportFailure(this.code, [this.message]);

  /// The error code.
  final String code;

  /// The native message, if any (not shown to the rider as is).
  final String? message;

  @override
  String toString() => 'RideExportFailure($code, $message)';
}

/// The reply of [RideExportNative.exportFile].
@immutable
class RideExportedFile {
  /// Creates a reply.
  const RideExportedFile({
    required this.bytes,
    required this.sourceSha256,
    required this.copySha256,
    required this.skipped,
    required this.synced,
  });

  /// Bytes of the source (and of the copy).
  final int bytes;

  /// SHA-256 of the source bytes as they were streamed, lowercase hex.
  final String sourceSha256;

  /// SHA-256 of the copy read back from the folder, lowercase hex.
  final String copySha256;

  /// Whether an equal file was already in the folder (nothing written).
  final bool skipped;

  /// Whether the copy was flushed to the storage device (`false` when the
  /// provider cannot sync, for example a pipe to a cloud app).
  final bool synced;
}

/// The reply of [RideExportNative.hashFile].
@immutable
class RideHashedFile {
  /// Creates a reply.
  const RideHashedFile({required this.bytes, required this.sha256});

  /// Bytes read.
  final int bytes;

  /// SHA-256 of the bytes read, lowercase hex.
  final String sha256;
}

/// The native operations of ride export. The app uses [RideExportChannel];
/// tests use a fake.
abstract class RideExportNative {
  /// Opens the system folder picker and returns the picked tree URI, or
  /// `null` when the rider cancelled. The grant is not persisted.
  Future<String?> pickExportFolder();

  /// Finds or creates the folder [name] in the tree [treeUri] (or uses the
  /// tree itself when it has that name), refuses it when it holds a file
  /// not in [expectedNames], deletes an old `manifest.json` and
  /// `MOTOCAM-EXPORT.txt` there, and returns the folder document URI.
  Future<String> prepareFolder({
    required String treeUri,
    required String name,
    required List<String> expectedNames,
  });

  /// Copies the private file [sourcePath] into the folder [folderUri] as
  /// [name], reads the copy back and hashes both. An equal file already
  /// there is skipped; a different one is never overwritten
  /// (`EXISTS_DIFFERENT`). Throws [RideExportCancelled] after [cancel].
  Future<RideExportedFile> exportFile({
    required String folderUri,
    required String sourcePath,
    required String name,
    required String mimeType,
  });

  /// Hashes the private file [path]. Throws [RideExportCancelled] after
  /// [cancel].
  Future<RideHashedFile> hashFile(String path);

  /// Stops the [exportFile] or [hashFile] in progress at its next buffer.
  /// Never throws.
  Future<void> cancel();

  /// Opens the share sheet with the private files [paths] (with
  /// [mimeTypes], one per path) and returns whether it opened.
  Future<bool> shareFiles({
    required List<String> paths,
    required List<String> mimeTypes,
    required String subject,
  });

  /// Keeps the screen on while an export runs. Never throws.
  Future<void> setKeepScreenOn(bool enabled);
}

/// The method channel to `RideExport.kt`.
class RideExportChannel implements RideExportNative {
  /// Creates the channel wrapper.
  const RideExportChannel();

  /// The method channel.
  static const MethodChannel channel = MethodChannel(
    'com.example.motocam/ride_export',
  );

  /// Runs [call], mapping `CANCELLED` to [RideExportCancelled], other
  /// platform errors to [RideExportFailure], and a missing native side to
  /// a `UNAVAILABLE` failure.
  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') {
        throw const RideExportCancelled();
      }
      throw RideExportFailure(e.code, e.message);
    } on MissingPluginException catch (e) {
      throw RideExportFailure('UNAVAILABLE', e.message);
    }
  }

  static Never _invalidReply(String method) =>
      throw RideExportFailure('INVALID_REPLY', 'Unexpected reply to $method.');

  @override
  Future<String?> pickExportFolder() async {
    try {
      return await _guard(
        () => channel.invokeMethod<String>('pickExportFolder'),
      );
    } on RideExportCancelled {
      return null;
    }
  }

  @override
  Future<String> prepareFolder({
    required String treeUri,
    required String name,
    required List<String> expectedNames,
  }) async {
    final uri = await _guard(
      () => channel.invokeMethod<String>('prepareFolder', <String, Object?>{
        'treeUri': treeUri,
        'name': name,
        'expectedNames': expectedNames,
      }),
    );
    return uri ?? _invalidReply('prepareFolder');
  }

  @override
  Future<RideExportedFile> exportFile({
    required String folderUri,
    required String sourcePath,
    required String name,
    required String mimeType,
  }) async {
    final reply = await _guard(
      () => channel
          .invokeMapMethod<String, Object?>('exportFile', <String, Object?>{
            'folderUri': folderUri,
            'sourcePath': sourcePath,
            'name': name,
            'mimeType': mimeType,
          }),
    );
    final bytes = reply?['bytes'];
    final sourceSha256 = reply?['sourceSha256'];
    final copySha256 = reply?['copySha256'];
    final skipped = reply?['skipped'];
    final synced = reply?['synced'];
    if (bytes is! int ||
        sourceSha256 is! String ||
        copySha256 is! String ||
        skipped is! bool ||
        synced is! bool) {
      _invalidReply('exportFile');
    }
    return RideExportedFile(
      bytes: bytes,
      sourceSha256: sourceSha256.toLowerCase(),
      copySha256: copySha256.toLowerCase(),
      skipped: skipped,
      synced: synced,
    );
  }

  @override
  Future<RideHashedFile> hashFile(String path) async {
    final reply = await _guard(
      () => channel.invokeMapMethod<String, Object?>(
        'hashFile',
        <String, Object?>{'path': path},
      ),
    );
    final bytes = reply?['bytes'];
    final sha256 = reply?['sha256'];
    if (bytes is! int || sha256 is! String) {
      _invalidReply('hashFile');
    }
    return RideHashedFile(bytes: bytes, sha256: sha256.toLowerCase());
  }

  @override
  Future<void> cancel() async {
    try {
      await channel.invokeMethod<bool>('cancel');
    } catch (_) {
      // Nothing is running.
    }
  }

  @override
  Future<bool> shareFiles({
    required List<String> paths,
    required List<String> mimeTypes,
    required String subject,
  }) async {
    final opened = await _guard(
      () => channel.invokeMethod<bool>('shareFiles', <String, Object?>{
        'paths': paths,
        'mimeTypes': mimeTypes,
        'subject': subject,
      }),
    );
    return opened ?? false;
  }

  @override
  Future<void> setKeepScreenOn(bool enabled) async {
    try {
      await channel.invokeMethod<void>('setKeepScreenOn', <String, Object?>{
        'enabled': enabled,
      });
    } catch (_) {
      // Best effort: the export runs without it.
    }
  }
}
