import 'package:flutter/services.dart';

import '../ride_file/ride_telemetry_codec.dart' as ride_codec;

/// What happened to one gallery copy in a [GalleryCopies.delete] or
/// [GalleryCopies.requestDelete] call.
enum GalleryCopyStatus {
  /// The copy was deleted.
  deleted,

  /// The copy no longer exists (for example deleted in a gallery app);
  /// it counts as removed.
  missing,

  /// Android 9 and lower: the URI now names a file outside the gallery
  /// folder (for example after the media database was rebuilt, its ID
  /// names another video). Nothing was deleted, and the URI no longer
  /// identifies the copy.
  changed,

  /// MediaStore refused the delete (API 29+); [GalleryCopies.requestDelete]
  /// asks the rider through a system prompt.
  needsConsent,

  /// Android 9 and lower without the storage permission; the delete can
  /// be tried again once it is granted.
  needsPermission,

  /// The rider declined the system prompt.
  denied,

  /// The delete failed for another reason.
  failed;

  /// Whether the copy is gone.
  bool get isRemoved => this == deleted || this == missing;

  /// Parses a status sent by the native side; anything unknown is
  /// [failed].
  static GalleryCopyStatus parse(Object? value) {
    for (final status in values) {
      if (status.name == value) {
        return status;
      }
    }
    return failed;
  }
}

/// The gallery copies MotoCam made (Android only), on the channel
/// `com.example.motocam/gallery`: checking that they still exist and
/// removing them.
///
/// Every method answers with a per-URI result and never throws: without the
/// native handler (tests) or after a channel error every URI is reported as
/// [GalleryCopyStatus.failed], and [existingUris] returns `null`.
class GalleryCopies {
  GalleryCopies._();

  /// The method channel to the native side.
  static const MethodChannel channel = MethodChannel(
    'com.example.motocam/gallery',
  );

  /// Which of [uris] still exist, or `null` when that cannot be checked.
  /// On Android 9 and lower a URI counts only while its file is directly in
  /// [relativePath], the gallery folder the copies were written to.
  static Future<Set<String>?> existingUris(
    List<String> uris, {
    String relativePath = ride_codec.publicExportRelativePath,
  }) async {
    if (uris.isEmpty) {
      return <String>{};
    }
    try {
      final result = await channel.invokeListMethod<String>(
        'galleryItemsExist',
        <String, Object?>{'uris': uris, 'relativePath': relativePath},
      );
      return result?.toSet();
    } catch (_) {
      return null;
    }
  }

  /// Deletes each of [uris] with `ContentResolver.delete`, without any
  /// prompt. Copies MotoCam inserted are its own, so this normally deletes
  /// them; a refused one is reported as [GalleryCopyStatus.needsConsent]
  /// (API 29+) or [GalleryCopyStatus.needsPermission] (Android 9 and
  /// lower). On Android 9 and lower, where nothing else stops a delete, a
  /// URI whose file is not directly in [relativePath] is never deleted
  /// ([GalleryCopyStatus.changed]).
  static Future<Map<String, GalleryCopyStatus>> delete(
    List<String> uris, {
    String relativePath = ride_codec.publicExportRelativePath,
  }) => _statuses('deleteGalleryItems', uris, relativePath: relativePath);

  /// Asks the rider to allow deleting [uris]: one system prompt for all of
  /// them on API 30+ (`MediaStore.createDeleteRequest`), one prompt per
  /// copy on API 29 (the `RecoverableSecurityException` action). Each URI
  /// comes back [GalleryCopyStatus.deleted], [GalleryCopyStatus.missing],
  /// [GalleryCopyStatus.denied] or [GalleryCopyStatus.failed] (also on
  /// Android 9 and lower, where no such prompt exists).
  static Future<Map<String, GalleryCopyStatus>> requestDelete(
    List<String> uris,
  ) => _statuses('requestDeleteGalleryItems', uris);

  static Future<Map<String, GalleryCopyStatus>> _statuses(
    String method,
    List<String> uris, {
    String? relativePath,
  }) async {
    if (uris.isEmpty) {
      return <String, GalleryCopyStatus>{};
    }
    Map<String, Object?>? result;
    try {
      result = await channel.invokeMapMethod<String, Object?>(
        method,
        <String, Object?>{'uris': uris, 'relativePath': ?relativePath},
      );
    } catch (_) {
      result = null;
    }
    return <String, GalleryCopyStatus>{
      for (final uri in uris) uri: GalleryCopyStatus.parse(result?[uri]),
    };
  }
}
