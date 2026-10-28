import 'package:flutter/services.dart';

/// What happened to one gallery copy in a [GalleryCopies.delete] or
/// [GalleryCopies.requestDelete] call.
enum GalleryCopyStatus {
  /// The copy was deleted.
  deleted,

  /// The copy no longer exists (for example deleted in a gallery app);
  /// it counts as removed.
  missing,

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
/// Every method answers with a per-URI result and never throws: on iOS (no
/// handler) or after a channel error every URI is reported as
/// [GalleryCopyStatus.failed], and [existingUris] returns `null`.
class GalleryCopies {
  GalleryCopies._();

  /// The method channel to the native side.
  static const MethodChannel channel = MethodChannel(
    'com.example.motocam/gallery',
  );

  /// Which of [uris] still exist, or `null` when that cannot be checked.
  static Future<Set<String>?> existingUris(List<String> uris) async {
    if (uris.isEmpty) {
      return <String>{};
    }
    try {
      final result = await channel.invokeListMethod<String>(
        'galleryItemsExist',
        <String, Object?>{'uris': uris},
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
  /// lower).
  static Future<Map<String, GalleryCopyStatus>> delete(List<String> uris) =>
      _statuses('deleteGalleryItems', uris);

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
    List<String> uris,
  ) async {
    if (uris.isEmpty) {
      return <String, GalleryCopyStatus>{};
    }
    Map<String, Object?>? result;
    try {
      result = await channel.invokeMapMethod<String, Object?>(
        method,
        <String, Object?>{'uris': uris},
      );
    } catch (_) {
      result = null;
    }
    return <String, GalleryCopyStatus>{
      for (final uri in uris) uri: GalleryCopyStatus.parse(result?[uri]),
    };
  }
}
