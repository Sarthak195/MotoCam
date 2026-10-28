/// Removing the gallery copies of a ride (Android): offered by Ride History
/// when a ride with gallery copies is unlocked or deleted, and from the
/// ride's menu.
library;

import '../../../core/services/gallery_copies.dart';
import 'gallery_links.dart';

/// Deletes gallery copies by content URI; the app uses [GalleryCopies].
typedef GalleryCopyStatusCall =
    Future<Map<String, GalleryCopyStatus>> Function(List<String> uris);

/// What [removeGalleryCopies] did.
class GalleryRemovalResult {
  /// Creates a result.
  const GalleryRemovalResult({
    required this.removed,
    required this.notRemoved,
    required this.declined,
    required this.permissionDenied,
  });

  /// Links whose copy is gone (deleted now, or already missing).
  final List<GalleryLink> removed;

  /// Links whose copy is still in the gallery, or no longer identified by
  /// its URI ([GalleryCopyStatus.changed]); only the first stay in the
  /// store.
  final List<GalleryLink> notRemoved;

  /// Whether the rider declined the system prompt for at least one copy.
  final bool declined;

  /// Whether the storage permission (Android 9 and lower) was denied.
  final bool permissionDenied;

  /// Number of copies that were to be removed.
  int get total => removed.length + notRemoved.length;
}

/// Removes the gallery copies of [links] and drops the removed ones from
/// [store].
///
/// Each copy is first deleted without a prompt ([delete]): MotoCam owns
/// the media it inserted. A copy that no longer exists counts as removed.
/// Copies refused for lack of the storage permission (Android 9 and lower)
/// are tried once more after [requestStoragePermission] grants it. Copies
/// MediaStore refuses on API 29+ go to [requestDelete], which shows the
/// system prompt (one for all of them on API 30+). Links of copies that are
/// still there stay in [store], so the removal can be tried again. A link
/// whose URI no longer names the copy ([GalleryCopyStatus.changed], Android
/// 9 and lower) is dropped without deleting anything, and counts as not
/// removed.
///
/// [rideKeys] (the ride's `galleryKeysOfRide` keys) first drops the ride's
/// queued exports from [store], so no new copy appears after the removal,
/// and adds the ride's links recorded since [links] was read.
Future<GalleryRemovalResult> removeGalleryCopies(
  List<GalleryLink> links, {
  required GalleryLinkStore? store,
  Iterable<String> rideKeys = const <String>[],
  GalleryCopyStatusCall delete = GalleryCopies.delete,
  GalleryCopyStatusCall requestDelete = GalleryCopies.requestDelete,
  Future<bool> Function()? requestStoragePermission,
}) async {
  if (store != null && rideKeys.isNotEmpty) {
    await store.dropPending(rideKeys);
    final data = await store.read();
    final known = links.map((link) => link.contentUri).toSet();
    final current = <GalleryLink>[for (final key in rideKeys) ?data.links[key]];
    links = <GalleryLink>[
      ...links,
      ...current.where((link) => !known.contains(link.contentUri)),
    ];
  }
  final uris = <String>{
    for (final link in links)
      if (link.contentUri.isNotEmpty) link.contentUri,
  }.toList(growable: false);
  final statuses = <String, GalleryCopyStatus>{
    for (final uri in uris) uri: GalleryCopyStatus.failed,
  };
  if (uris.isNotEmpty) {
    statuses.addAll(await delete(uris));
  }

  var permissionDenied = false;
  List<String> withStatus(GalleryCopyStatus status) => <String>[
    for (final entry in statuses.entries)
      if (entry.value == status) entry.key,
  ];

  final needPermission = withStatus(GalleryCopyStatus.needsPermission);
  if (needPermission.isNotEmpty) {
    var granted = false;
    if (requestStoragePermission != null) {
      try {
        granted = await requestStoragePermission();
      } catch (_) {
        granted = false;
      }
    }
    if (granted) {
      statuses.addAll(await delete(needPermission));
    }
    permissionDenied = withStatus(GalleryCopyStatus.needsPermission).isNotEmpty;
  }

  final needConsent = withStatus(GalleryCopyStatus.needsConsent);
  if (needConsent.isNotEmpty) {
    statuses.addAll(await requestDelete(needConsent));
  }
  final declined = statuses.values.contains(GalleryCopyStatus.denied);

  final removed = <GalleryLink>[];
  final notRemoved = <GalleryLink>[];
  final forgotten = <GalleryLink>[];
  for (final link in links) {
    final status = statuses[link.contentUri] ?? GalleryCopyStatus.failed;
    (status.isRemoved ? removed : notRemoved).add(link);
    if (status.isRemoved || status == GalleryCopyStatus.changed) {
      forgotten.add(link);
    }
  }

  if (store != null && forgotten.isNotEmpty) {
    await store.update((data) {
      for (final link in forgotten) {
        // Only the link that was removed, not a newer copy of the segment.
        if (data.links[link.key]?.contentUri == link.contentUri) {
          data.links.remove(link.key);
        }
      }
    });
  }

  return GalleryRemovalResult(
    removed: List<GalleryLink>.unmodifiable(removed),
    notRemoved: List<GalleryLink>.unmodifiable(notRemoved),
    declined: declined,
    permissionDenied: permissionDenied,
  );
}

/// Rider-facing summary of [result]; [canRetry] is false when the ride is
/// gone (deleted), so the ride's menu cannot offer the removal again.
String galleryRemovalSummary(
  GalleryRemovalResult result, {
  bool canRetry = true,
}) {
  String copies(int n) => '$n gallery cop${n == 1 ? 'y' : 'ies'}';
  if (result.notRemoved.isEmpty) {
    return 'Removed ${copies(result.removed.length)}.';
  }
  final why = result.declined
      ? 'the system prompt was declined'
      : result.permissionDenied
      ? 'storage permission denied'
      : 'they could not be removed';
  final kept = result.notRemoved.length;
  return 'Removed ${result.removed.length} of ${copies(result.total)}. '
      '$kept ${kept == 1 ? 'is' : 'are'} still in Movies/MotoCam/Recordings '
      '($why); delete ${kept == 1 ? 'it' : 'them'} in a gallery app'
      '${canRetry ? ' or try again from the ride\'s menu' : ''}.';
}
