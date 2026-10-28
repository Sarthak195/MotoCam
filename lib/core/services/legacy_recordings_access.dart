/// Storage Access Framework access to the public folder that v0.1.11 and
/// v0.1.12 recorded to (`Movies/MotoCam/Recordings`, Android only), for the
/// import of old rides. The native side is `LegacyRecordingsAccess.kt`
/// (channel `com.example.motocam/legacy_recordings`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A file in the picked folder.
@immutable
class LegacyRideDocument {
  /// Creates a document.
  const LegacyRideDocument({
    required this.uri,
    required this.name,
    this.size,
    this.canDelete = true,
  });

  /// The document URI (opaque; only passed back to the source).
  final String uri;

  /// The file name, as the provider reports it.
  final String name;

  /// Size in bytes, or `null` when the provider does not report it.
  final int? size;

  /// Whether the provider says the document can be deleted.
  final bool canDelete;
}

/// Thrown by [LegacyRideDocumentSource.copyTo] after
/// [LegacyRideDocumentSource.cancelCopy].
class LegacyCopyCancelled implements Exception {
  /// Creates the exception.
  const LegacyCopyCancelled();
}

/// The files of one picked folder. The app uses [LegacyRecordingsAccess];
/// tests use a fake.
abstract class LegacyRideDocumentSource {
  /// The folder's files (not its subdirectories).
  Future<List<LegacyRideDocument>> list();

  /// Streams [document] into a new file at [targetPath], flushed to disk,
  /// and returns the bytes copied. Throws [LegacyCopyCancelled] after
  /// [cancelCopy]; any other failure throws another exception. A partial
  /// target may be left behind on failure.
  Future<int> copyTo(LegacyRideDocument document, String targetPath);

  /// Stops the copy in progress at its next buffer.
  Future<void> cancelCopy();

  /// Deletes [documents] in order and returns the URIs that could not be
  /// deleted.
  Future<List<String>> delete(List<LegacyRideDocument> documents);
}

/// The channel to the native picker and to the documents of a picked tree.
class LegacyRecordingsAccess implements LegacyRideDocumentSource {
  /// Creates access to the tree at [treeUri] (from [pickRecordingsTree]).
  LegacyRecordingsAccess(this.treeUri);

  /// Name of the method channel.
  static const String channelName = 'com.example.motocam/legacy_recordings';

  static const MethodChannel _channel = MethodChannel(channelName);

  /// The picked tree.
  final String treeUri;

  /// Opens the system folder picker, starting in Movies/MotoCam/Recordings
  /// on Android 8 and later, and returns the picked tree URI, or `null`
  /// when the rider cancelled. The grant is not persisted: it ends with the
  /// activity. Throws a [PlatformException] when no picker is available.
  static Future<String?> pickRecordingsTree() =>
      _channel.invokeMethod<String>('pickRecordingsTree');

  @override
  Future<List<LegacyRideDocument>> list() async {
    final raw = await _channel.invokeListMethod<Object?>('listTree', {
      'treeUri': treeUri,
    });
    final documents = <LegacyRideDocument>[];
    for (final item in raw ?? const <Object?>[]) {
      if (item is! Map) {
        continue;
      }
      final uri = item['uri'];
      final name = item['name'];
      if (uri is! String || name is! String) {
        continue;
      }
      final size = item['size'];
      documents.add(
        LegacyRideDocument(
          uri: uri,
          name: name,
          size: size is int && size >= 0 ? size : null,
          canDelete: item['canDelete'] != false,
        ),
      );
    }
    return documents;
  }

  @override
  Future<int> copyTo(LegacyRideDocument document, String targetPath) async {
    try {
      final copied = await _channel.invokeMethod<int>('copyDocument', {
        'uri': document.uri,
        'targetPath': targetPath,
      });
      return copied ?? 0;
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') {
        throw const LegacyCopyCancelled();
      }
      rethrow;
    }
  }

  @override
  Future<void> cancelCopy() async {
    try {
      await _channel.invokeMethod<bool>('cancelCopy');
    } catch (_) {
      // Nothing is copying.
    }
  }

  @override
  Future<List<String>> delete(List<LegacyRideDocument> documents) async {
    final failed = await _channel.invokeListMethod<String>('deleteDocuments', {
      'uris': <String>[for (final document in documents) document.uri],
    });
    return failed ?? const <String>[];
  }
}
