import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/gallery_copies.dart';
import 'package:motocam/features/camera/providers/gallery_export.dart';
import 'package:motocam/features/history/services/gallery_copy_removal.dart';
import 'package:motocam/features/history/services/gallery_links.dart';

final String _sep = Platform.pathSeparator;

/// A fake native exporter: records each call and answers with a URI or the
/// error code queued for the file.
class _FakeNative {
  final List<String> calls = <String>[];
  final List<String> sources = <String>[];
  final Map<String, List<String>> errors = <String, List<String>>{};

  /// Runs while the copy of a file "is made", before the answer.
  Future<void> Function(String displayName)? during;

  Future<String?> call({
    required String sourcePath,
    required String displayName,
  }) async {
    calls.add(displayName);
    sources.add(sourcePath);
    await during?.call(displayName);
    final queued = errors[displayName];
    if (queued != null && queued.isNotEmpty) {
      throw PlatformException(code: queued.removeAt(0));
    }
    return 'content://media/external/video/media/$displayName';
  }
}

void main() {
  late Directory temp;
  late Directory root;
  late Directory legacy;
  late File storeFile;
  late _FakeNative native;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('motocam_gallery_export_');
    root = Directory('${temp.path}${_sep}MotoCam Recordings')..createSync();
    legacy = Directory('${temp.path}${_sep}legacy')..createSync();
    storeFile = File('${temp.path}${_sep}links${_sep}gallery_links.json');
    native = _FakeNative();
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  File write(Directory dir, String name) =>
      File('${dir.path}$_sep$name')..writeAsStringSync('video');

  GalleryExporter exporter({
    GalleryLinkStore? store,
    Future<bool> Function()? requestPermission,
    GalleryCopyStatusCall? deleteCopies,
  }) => GalleryExporter(
    store: store ?? GalleryLinkStore(storeFile),
    exportVideo: native.call,
    locate: (entry) => locateGalleryExportSource(
      entry: entry,
      roots: <String>[root.path, legacy.path],
    ),
    requestStoragePermission: requestPermission,
    deleteCopies: deleteCopies,
  );

  GalleryExportItem item(String? id, File file) =>
      GalleryExportItem(rideSessionId: id, sourcePath: file.path);

  test('a queue survives the process and is retried once', () async {
    final a = write(root, 'a.mp4');
    final b = write(root, 'b.mp4');
    // The process is killed after queueing, before the 2 s drain.
    await exporter().enqueue(<GalleryExportItem>[item('r1', a), item('r1', b)]);
    expect(native.calls, isEmpty);

    // Next launch: a fresh store reads the queue from disk.
    final store = GalleryLinkStore(storeFile);
    expect((await store.read()).pending.keys, <String>['r1|a.mp4', 'r1|b.mp4']);
    final run = await exporter(store: store).drain();
    expect(run.exported, 2);
    expect(native.calls, <String>['a.mp4', 'b.mp4']);

    final data = await GalleryLinkStore(storeFile).read();
    expect(data.pending, isEmpty);
    expect(
      data.links['r1|a.mp4']!.contentUri,
      'content://media/external/video/media/a.mp4',
    );

    // A second retry (another launch) copies nothing again.
    final again = await exporter(store: GalleryLinkStore(storeFile)).drain();
    expect(again.hasOutcome, isFalse);
    expect(native.calls, hasLength(2));
  });

  test('never queues or copies a linked segment twice', () async {
    final a = write(root, 'a.mp4');
    final store = GalleryLinkStore(storeFile);
    final queue = exporter(store: store);
    await queue.enqueue(<GalleryExportItem>[item('r1', a), item('r1', a)]);
    expect((await store.read()).pending, hasLength(1));
    await queue.drain();

    final second = await queue.enqueue(<GalleryExportItem>[item('r1', a)]);
    expect(second.alreadySaved, 1);
    expect(second.keys, isEmpty);
    await queue.drain();
    expect(native.calls, <String>['a.mp4']);

    // A pending entry whose key got linked meanwhile is dropped.
    await store.update((data) {
      data.pending['r1|a.mp4'] = PendingGalleryExport(
        rideSessionId: 'r1',
        fileName: 'a.mp4',
        sourcePath: a.path,
        queuedAt: DateTime(2026),
      );
    });
    final run = await queue.drain();
    expect(run.alreadySaved, 1);
    expect(native.calls, <String>['a.mp4']);
    expect((await store.read()).pending, isEmpty);
  });

  test('the same file name in two rides is two segments', () async {
    final a = write(root, 'a.mp4');
    final queue = exporter();
    await queue.enqueue(<GalleryExportItem>[item('r1', a), item('r2', a)]);
    final run = await queue.drain();
    expect(run.exported, 2);
  });

  test('a moved ride is found by file name; a gone file is dropped', () async {
    final moved = write(root, 'm.mp4');
    final store = GalleryLinkStore(storeFile);
    await store.update((data) {
      for (final name in <String>['m.mp4', 'gone.mp4']) {
        final entry = PendingGalleryExport(
          rideSessionId: 'r1',
          fileName: name,
          // Where the files were before the migration moved them.
          sourcePath: '${legacy.path}${_sep}old$_sep$name',
          queuedAt: DateTime(2026),
        );
        data.pending[entry.key] = entry;
      }
    });
    final run = await exporter(store: store).drain();
    expect(run.exported, 1);
    expect(run.missing, 1);
    expect(native.calls, <String>['m.mp4']);
    expect((await store.read()).pending, isEmpty);
    expect(moved.existsSync(), isTrue);
  });

  group('locateGalleryExportSource', () {
    PendingGalleryExport entry(String sourcePath, String name) =>
        PendingGalleryExport(
          rideSessionId: 'r',
          fileName: name,
          sourcePath: sourcePath,
          queuedAt: DateTime(2026),
        );

    test('prefers the queued path, then the roots in order', () async {
      final inLegacy = write(legacy, 'x.mp4');
      expect(
        await locateGalleryExportSource(
          entry: entry(inLegacy.path, 'x.mp4'),
          roots: <String>[root.path, legacy.path],
        ),
        inLegacy.path,
      );
      final inRoot = write(root, 'x.mp4');
      expect(
        await locateGalleryExportSource(
          entry: entry('/gone/x.mp4', 'x.mp4'),
          roots: <String>[root.path, legacy.path],
        ),
        inRoot.path,
      );
    });

    test('never returns a queued path outside the roots', () async {
      final outside = Directory('${temp.path}${_sep}outside')..createSync();
      final file = write(outside, 'y.mp4');
      expect(
        await locateGalleryExportSource(
          entry: entry(file.path, 'y.mp4'),
          roots: <String>[root.path],
        ),
        isNull,
      );
    });
  });

  test('a failed copy stays queued until the third attempt', () async {
    final a = write(root, 'a.mp4');
    native.errors['a.mp4'] = <String>['EXPORT_FAILED', 'EXPORT_FAILED'];
    final store = GalleryLinkStore(storeFile);
    final queue = exporter(store: store);
    await queue.enqueue(<GalleryExportItem>[item('r1', a)]);

    var run = await queue.drain();
    expect(run.failed, 1);
    expect((await store.read()).pending['r1|a.mp4']!.attempts, 1);
    run = await queue.drain();
    expect((await store.read()).pending['r1|a.mp4']!.attempts, 2);
    // The third attempt succeeds.
    run = await queue.drain();
    expect(run.exported, 1);
    expect((await store.read()).links.keys, <String>['r1|a.mp4']);

    final b = write(root, 'b.mp4');
    native.errors['b.mp4'] = List<String>.filled(3, 'EXPORT_FAILED');
    await queue.enqueue(<GalleryExportItem>[item('r1', b)]);
    for (var i = 0; i < GalleryExporter.maxAttempts; i++) {
      await queue.drain();
    }
    expect((await store.read()).pending, isEmpty);
    expect((await store.read()).links.keys, <String>['r1|a.mp4']);
  });

  test('asks for the storage permission once per drain and retries', () async {
    final a = write(root, 'a.mp4');
    final b = write(root, 'b.mp4');
    native.errors['a.mp4'] = <String>[galleryPermissionDeniedCode];
    native.errors['b.mp4'] = <String>[galleryPermissionDeniedCode];
    var asked = 0;
    final queue = exporter(
      requestPermission: () async {
        asked++;
        return true;
      },
    );
    await queue.enqueue(<GalleryExportItem>[item('r1', a), item('r1', b)]);
    final run = await queue.drain(askPermission: true);
    expect(asked, 1);
    expect(run.exported, 2);
    expect(run.permissionDenied, isFalse);
  });

  test(
    'a denied permission is reported; the launch retry never asks',
    () async {
      final a = write(root, 'a.mp4');
      native.errors['a.mp4'] = <String>[
        galleryPermissionDeniedCode,
        galleryPermissionDeniedCode,
      ];
      var asked = 0;
      final queue = exporter(
        requestPermission: () async {
          asked++;
          return false;
        },
      );
      await queue.enqueue(<GalleryExportItem>[item('r1', a)]);
      var run = await queue.drain(askPermission: true);
      expect(asked, 1);
      expect(run.failed, 1);
      expect(run.permissionDenied, isTrue);

      // A drain that does not ask (the launch retry) leaves the entry
      // waiting without counting an attempt, however often it runs.
      for (var i = 0; i < GalleryExporter.maxAttempts + 1; i++) {
        native.errors['a.mp4'] = <String>[galleryPermissionDeniedCode];
        run = await queue.drain();
        expect(run.failed, 0);
        expect(run.awaitingPermission, 1);
        expect(run.hasOutcome, isFalse);
      }
      expect(asked, 1);
      final data = await queue.store.read();
      expect(data.pending['r1|a.mp4']!.attempts, 1);
    },
  );

  test('a copy whose entry was dropped meanwhile is deleted', () async {
    final a = write(root, 'a.mp4');
    final b = write(root, 'b.mp4');
    final store = GalleryLinkStore(storeFile);
    final deleted = <String>[];
    final queue = exporter(
      store: store,
      deleteCopies: (uris) async {
        deleted.addAll(uris);
        return <String, GalleryCopyStatus>{
          for (final uri in uris) uri: GalleryCopyStatus.deleted,
        };
      },
    );
    await queue.enqueue(<GalleryExportItem>[item('r1', a), item('r1', b)]);
    // The ride is deleted (or its copies removed) while a.mp4 is copied.
    native.during = (name) async {
      if (name == 'a.mp4') {
        await store.dropPending(<String>['r1|a.mp4', 'r1|b.mp4']);
      }
    };
    final run = await queue.drain();
    expect(run.discarded, 1);
    expect(run.exported, 0);
    expect(native.calls, <String>['a.mp4']);
    expect(deleted, <String>['content://media/external/video/media/a.mp4']);
    final data = await store.read();
    expect(data.links, isEmpty);
    expect(data.pending, isEmpty);
  });

  test('a dropped entry\'s copy is linked when deleting it fails', () async {
    final a = write(root, 'a.mp4');
    final store = GalleryLinkStore(storeFile);
    final queue = exporter(
      store: store,
      deleteCopies: (uris) async => <String, GalleryCopyStatus>{
        for (final uri in uris) uri: GalleryCopyStatus.failed,
      },
    );
    await queue.enqueue(<GalleryExportItem>[item('r1', a)]);
    native.during = (_) => store.dropPending(<String>['r1|a.mp4']);
    final run = await queue.drain();
    expect(run.exported, 1);
    expect(run.discarded, 0);
    expect((await store.read()).links.keys, <String>['r1|a.mp4']);
  });

  test('a failed copy whose entry was dropped is not queued again', () async {
    final a = write(root, 'a.mp4');
    native.errors['a.mp4'] = <String>['EXPORT_FAILED'];
    final store = GalleryLinkStore(storeFile);
    final queue = exporter(store: store);
    await queue.enqueue(<GalleryExportItem>[item('r1', a)]);
    native.during = (_) => store.dropPending(<String>['r1|a.mp4']);
    final run = await queue.drain();
    expect(run.failed, 1);
    expect((await store.read()).pending, isEmpty);
  });

  test('a file moved during the copy is copied from its new place', () async {
    final old = write(legacy, 'm.mp4');
    native.errors['m.mp4'] = <String>['SOURCE_NOT_FOUND'];
    // The migration moves the file while the first copy starts.
    native.during = (name) async {
      if (old.existsSync()) {
        old.renameSync('${root.path}${_sep}m.mp4');
      }
    };
    final store = GalleryLinkStore(storeFile);
    final queue = exporter(store: store);
    await queue.enqueue(<GalleryExportItem>[item('r1', old)]);
    final run = await queue.drain();
    expect(run.exported, 1);
    expect(run.missing, 0);
    expect(native.sources, <String>[old.path, '${root.path}${_sep}m.mp4']);
    expect((await store.read()).links.keys, <String>['r1|m.mp4']);
  });

  test('pauses before the next copy and keeps the rest queued', () async {
    final a = write(root, 'a.mp4');
    final b = write(root, 'b.mp4');
    final store = GalleryLinkStore(storeFile);
    final queue = exporter(store: store);
    await queue.enqueue(<GalleryExportItem>[item('r1', a), item('r1', b)]);
    var checks = 0;
    final progress = <String>[];
    final run = await queue.drain(
      shouldPause: () => ++checks > 1,
      onProgress: (done, total) => progress.add('$done/$total'),
    );
    expect(run.exported, 1);
    expect(run.paused, isTrue);
    expect(progress, <String>['0/2', '1/2']);
    expect((await store.read()).pending.keys, <String>['r1|b.mp4']);
  });

  test('only the given keys are drained', () async {
    final a = write(root, 'a.mp4');
    final b = write(root, 'b.mp4');
    final store = GalleryLinkStore(storeFile);
    final queue = exporter(store: store);
    await queue.enqueue(<GalleryExportItem>[item('old', a)]);
    final save = await queue.enqueue(<GalleryExportItem>[item('r1', b)]);
    final run = await queue.drain(onlyKeys: save.keys);
    expect(run.exported, 1);
    expect(native.calls, <String>['b.mp4']);
    expect((await store.read()).pending.keys, <String>['old|a.mp4']);
  });

  test('a source that vanished during the copy is dropped', () async {
    final a = write(root, 'a.mp4');
    native.errors['a.mp4'] = <String>['SOURCE_NOT_FOUND'];
    final store = GalleryLinkStore(storeFile);
    final queue = exporter(store: store);
    await queue.enqueue(<GalleryExportItem>[item('r1', a)]);
    final run = await queue.drain();
    expect(run.missing, 1);
    expect((await store.read()).pending, isEmpty);
  });

  test(
    'forgets links whose copy is gone, so they can be saved again',
    () async {
      final a = write(root, 'a.mp4');
      final b = write(root, 'b.mp4');
      final store = GalleryLinkStore(storeFile);
      final queue = exporter(store: store);
      await queue.enqueue(<GalleryExportItem>[item('r1', a), item('r1', b)]);
      await queue.drain();

      // The check is unavailable: nothing is forgotten.
      expect(
        await queue.forgetMissingLinks(<String>['r1|a.mp4'], (_) async => null),
        0,
      );
      final forgotten = await queue.forgetMissingLinks(
        <String>['r1|a.mp4', 'r1|b.mp4'],
        (uris) async => <String>{'content://media/external/video/media/b.mp4'},
      );
      expect(forgotten, 1);
      expect((await store.read()).links.keys, <String>['r1|b.mp4']);
      final again = await queue.enqueue(<GalleryExportItem>[
        item('r1', a),
        item('r1', b),
      ]);
      expect(again.keys, <String>{'r1|a.mp4'});
      expect(again.alreadySaved, 1);
    },
  );

  test('gallerySaveSummary', () {
    expect(
      gallerySaveSummary(const GalleryExportRun(exported: 2, alreadySaved: 1)),
      'Saved 2 segments to Movies/MotoCam/Recordings; 1 segment already in '
      'the gallery.',
    );
    expect(
      gallerySaveSummary(
        const GalleryExportRun(failed: 1, permissionDenied: true),
      ),
      contains('storage access was denied'),
    );
    expect(
      gallerySaveSummary(const GalleryExportRun()),
      'Nothing to save: this ride has no video on the phone.',
    );
  });
}
