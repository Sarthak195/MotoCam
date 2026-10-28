import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/gallery_copies.dart';
import 'package:motocam/features/history/services/gallery_copy_removal.dart';
import 'package:motocam/features/history/services/gallery_links.dart';

final String _sep = Platform.pathSeparator;

GalleryLink _link(String name) => GalleryLink(
  rideSessionId: 'r1',
  fileName: name,
  contentUri: 'content://media/external/video/media/$name',
  displayName: name,
  relativePath: 'Movies/MotoCam/Recordings',
  exportedAt: DateTime(2026),
);

void main() {
  late Directory temp;
  late GalleryLinkStore store;
  final links = <GalleryLink>[_link('a'), _link('b'), _link('c')];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('motocam_gallery_remove_');
    store = GalleryLinkStore(File('${temp.path}${_sep}gallery_links.json'));
    await store.update((data) {
      for (final link in links) {
        data.links[link.key] = link;
      }
    });
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  GalleryCopyStatusCall answer(Map<String, GalleryCopyStatus> byName) =>
      (uris) async => <String, GalleryCopyStatus>{
        for (final uri in uris) uri: byName[uri.split('/').last]!,
      };

  test('drops the ride\'s queued copies and removes newer links', () async {
    await store.update((data) {
      for (final name in <String>['d', 'other']) {
        final entry = PendingGalleryExport(
          rideSessionId: name == 'other' ? 'r2' : 'r1',
          fileName: name,
          sourcePath: name,
          queuedAt: DateTime(2026),
        );
        data.pending[entry.key] = entry;
      }
      // Linked after the dialog read the ride's links.
      data.links['r1|e'] = _link('e');
    });
    final deleted = <String>[];
    final result = await removeGalleryCopies(
      <GalleryLink>[_link('a')],
      store: store,
      rideKeys: <String>['r1|a', 'r1|d', 'r1|e'],
      delete: (uris) async {
        deleted.addAll(uris);
        return <String, GalleryCopyStatus>{
          for (final uri in uris) uri: GalleryCopyStatus.deleted,
        };
      },
      requestDelete: (uris) async => <String, GalleryCopyStatus>{},
    );
    expect(result.removed.map((l) => l.fileName), <String>['a', 'e']);
    expect(deleted.map((uri) => uri.split('/').last), <String>['a', 'e']);
    final data = await store.read();
    expect(data.pending.keys, <String>['r2|other']);
    expect(data.links.keys, <String>['r1|b', 'r1|c']);
  });

  test('deleted and missing copies count as removed', () async {
    var prompts = 0;
    final result = await removeGalleryCopies(
      links,
      store: store,
      delete: answer(<String, GalleryCopyStatus>{
        'a': GalleryCopyStatus.deleted,
        'b': GalleryCopyStatus.missing,
        'c': GalleryCopyStatus.failed,
      }),
      requestDelete: (uris) async {
        prompts++;
        return <String, GalleryCopyStatus>{};
      },
    );
    expect(prompts, 0);
    expect(result.removed.map((l) => l.fileName), <String>['a', 'b']);
    expect(result.notRemoved.map((l) => l.fileName), <String>['c']);
    expect(result.declined, isFalse);
    expect((await store.read()).links.keys, <String>['r1|c']);
    expect(
      galleryRemovalSummary(result),
      'Removed 2 of 3 gallery copies. 1 is still in Movies/MotoCam/Recordings '
      '(they could not be removed); delete it in a gallery app or try again '
      'from the ride\'s menu.',
    );
  });

  test('copies needing consent go to one system prompt', () async {
    List<String>? asked;
    final result = await removeGalleryCopies(
      links,
      store: store,
      delete: answer(<String, GalleryCopyStatus>{
        'a': GalleryCopyStatus.deleted,
        'b': GalleryCopyStatus.needsConsent,
        'c': GalleryCopyStatus.needsConsent,
      }),
      requestDelete: (uris) async {
        asked = uris;
        return <String, GalleryCopyStatus>{
          for (final uri in uris) uri: GalleryCopyStatus.deleted,
        };
      },
    );
    expect(asked, hasLength(2));
    expect(result.notRemoved, isEmpty);
    expect((await store.read()).links, isEmpty);
    expect(galleryRemovalSummary(result), 'Removed 3 gallery copies.');
  });

  test('a declined prompt keeps the links and says so', () async {
    final result = await removeGalleryCopies(
      links,
      store: store,
      delete: answer(<String, GalleryCopyStatus>{
        'a': GalleryCopyStatus.needsConsent,
        'b': GalleryCopyStatus.needsConsent,
        'c': GalleryCopyStatus.deleted,
      }),
      requestDelete: (uris) async => <String, GalleryCopyStatus>{
        for (final uri in uris) uri: GalleryCopyStatus.denied,
      },
    );
    expect(result.declined, isTrue);
    expect(result.notRemoved, hasLength(2));
    expect((await store.read()).links.keys, <String>['r1|a', 'r1|b']);
    expect(
      galleryRemovalSummary(result, canRetry: false),
      'Removed 1 of 3 gallery copies. 2 are still in '
      'Movies/MotoCam/Recordings (the system prompt was declined); delete '
      'them in a gallery app.',
    );
  });

  test('Android 9: retried after the storage permission is granted', () async {
    var deletes = 0;
    final result = await removeGalleryCopies(
      links.take(1).toList(),
      store: store,
      delete: (uris) async {
        deletes++;
        return <String, GalleryCopyStatus>{
          for (final uri in uris)
            uri: deletes == 1
                ? GalleryCopyStatus.needsPermission
                : GalleryCopyStatus.deleted,
        };
      },
      requestStoragePermission: () async => true,
    );
    expect(deletes, 2);
    expect(result.removed, hasLength(1));
    expect(result.permissionDenied, isFalse);
  });

  test('Android 9: a denied permission removes nothing', () async {
    final result = await removeGalleryCopies(
      links.take(1).toList(),
      store: store,
      delete: (uris) async => <String, GalleryCopyStatus>{
        for (final uri in uris) uri: GalleryCopyStatus.needsPermission,
      },
      requestStoragePermission: () async => false,
    );
    expect(result.removed, isEmpty);
    expect(result.permissionDenied, isTrue);
    expect((await store.read()).links, hasLength(3));
    expect(galleryRemovalSummary(result), contains('storage permission'));
  });

  test('a newer copy of the same segment is not forgotten', () async {
    final newer = GalleryLink(
      rideSessionId: 'r1',
      fileName: 'a',
      contentUri: 'content://media/external/video/media/newer',
      displayName: 'a',
      relativePath: 'Movies/MotoCam/Recordings',
      exportedAt: DateTime(2027),
    );
    await store.update((data) => data.links[newer.key] = newer);
    await removeGalleryCopies(
      <GalleryLink>[_link('a')],
      store: store,
      delete: (uris) async => <String, GalleryCopyStatus>{
        for (final uri in uris) uri: GalleryCopyStatus.deleted,
      },
    );
    expect(
      (await store.read()).links['r1|a']!.contentUri,
      'content://media/external/video/media/newer',
    );
  });
}
