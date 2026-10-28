import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/utils/path_utils.dart' as path_utils;
import 'package:motocam/features/camera/providers/storage_budget.dart';

final String _sep = Platform.pathSeparator;

void main() {
  final root = '${_sep}data${_sep}files${_sep}MotoCam Recordings';
  String inRoot(String name) => '$root$_sep$name';

  StorageBudgetRide ride(
    String name,
    int day, {
    List<String>? videos,
    bool locked = false,
    bool quarantined = false,
    String? sessionId,
    DateTime? lastModified,
  }) {
    final json = inRoot('ride_$name.telemetry.json');
    return StorageBudgetRide(
      id: json,
      createdAt: DateTime(2026, 10, day),
      files: <String>[
        for (final video in videos ?? <String>['${name}_a.mp4']) inRoot(video),
        json,
      ],
      rideSessionId: sessionId ?? name,
      isLocked: locked,
      hasQuarantinedPaths: quarantined,
      lastModified: lastModified,
    );
  }

  Map<String, int> sizesOf(List<StorageBudgetRide> rides, {int video = 100}) {
    return <String, int>{
      for (final r in rides)
        for (final file in r.files)
          file: file.endsWith('.telemetry.json') ? 1 : video,
    };
  }

  test('off or within budget selects nothing', () {
    final rides = <StorageBudgetRide>[ride('a', 1), ride('b', 2)];
    final sizes = sizesOf(rides);
    final off = selectRidesForStorageBudget(
      budgetBytes: 0,
      fileSizes: sizes,
      rides: rides,
      recordingsRoot: root,
    );
    expect(off.ridesToDelete, isEmpty);
    expect(off.isOverBudget, isFalse);
    expect(off.totalBytes, 202);
    final within = selectRidesForStorageBudget(
      budgetBytes: 202,
      fileSizes: sizes,
      rides: rides,
      recordingsRoot: root,
    );
    expect(within.ridesToDelete, isEmpty);
    expect(within.attainable, isTrue);
  });

  test('deletes whole rides, oldest first, until the total fits', () {
    final rides = <StorageBudgetRide>[
      ride('new', 9),
      ride('old', 1, videos: <String>['old_a.mp4', 'old_b.mp4']),
      ride('mid', 5),
    ];
    final selection = selectRidesForStorageBudget(
      budgetBytes: 250,
      fileSizes: sizesOf(rides),
      rides: rides,
      recordingsRoot: root,
    );
    expect(selection.totalBytes, 403);
    expect(selection.ridesToDelete.map((r) => r.rideSessionId), <String>[
      'old',
    ]);
    // Every file of the ride goes, its JSON included.
    expect(selection.bytesToFree, 201);

    final tighter = selectRidesForStorageBudget(
      budgetBytes: 150,
      fileSizes: sizesOf(rides),
      rides: rides,
      recordingsRoot: root,
    );
    expect(tighter.ridesToDelete.map((r) => r.rideSessionId), <String>[
      'old',
      'mid',
    ]);
  });

  test('never selects a locked or quarantined ride', () {
    final rides = <StorageBudgetRide>[
      ride('locked', 1, locked: true),
      ride('quarantined', 2, quarantined: true),
      ride('free', 3),
    ];
    final selection = selectRidesForStorageBudget(
      budgetBytes: 210,
      fileSizes: sizesOf(rides),
      rides: rides,
      recordingsRoot: root,
    );
    expect(selection.ridesToDelete.map((r) => r.rideSessionId), <String>[
      'free',
    ]);
    expect(selection.protectedBytes, 202);
  });

  test('excludes the current session by id and by its segment paths', () {
    // The current session's first segments exist before its checkpoint
    // JSON does: they show up as a video-only ride.
    final early = StorageBudgetRide(
      id: inRoot('REC1.mp4'),
      createdAt: DateTime(2026, 10, 1),
      files: <String>[inRoot('REC1.mp4')],
    );
    final checkpoint = ride('current', 1, sessionId: 'session-now');
    final old = ride('old', 2);
    final rides = <StorageBudgetRide>[early, checkpoint, old];
    final sizes = sizesOf(rides);
    final selection = selectRidesForStorageBudget(
      budgetBytes: 205,
      fileSizes: sizes,
      rides: rides,
      recordingsRoot: root,
      currentRideSessionId: 'session-now',
      currentSessionPaths: <String>[inRoot('REC1.mp4')],
    );
    expect(selection.ridesToDelete.map((r) => r.id), <String>[old.id]);

    // A ride sharing a file with the session is protected with it.
    final sharing = ride('sharing', 1, videos: <String>['REC1.mp4']);
    final again = selectRidesForStorageBudget(
      budgetBytes: 150,
      fileSizes: sizesOf(<StorageBudgetRide>[sharing, old]),
      rides: <StorageBudgetRide>[sharing, old],
      recordingsRoot: root,
      currentSessionPaths: <String>[inRoot('REC1.mp4')],
    );
    expect(again.ridesToDelete.map((r) => r.id), <String>[old.id]);
  });

  test('a file written since the session started is never selected', () {
    final started = DateTime(2026, 10, 28, 9);
    final fresh = StorageBudgetRide(
      id: inRoot('REC9.mp4'),
      createdAt: DateTime(2026, 10, 1),
      files: <String>[inRoot('REC9.mp4')],
      lastModified: started,
    );
    final old = ride('old', 2, lastModified: DateTime(2026, 10, 2));
    final selection = selectRidesForStorageBudget(
      budgetBytes: 150,
      fileSizes: sizesOf(<StorageBudgetRide>[fresh, old]),
      rides: <StorageBudgetRide>[fresh, old],
      recordingsRoot: root,
      currentSessionStartedAt: started,
    );
    expect(selection.ridesToDelete.map((r) => r.id), <String>[old.id]);
  });

  test('the videos of a half-moved ride in the protected paths are never '
      'selected', () {
    // The migration paused after moving this locked ride's first video; its
    // JSON is still in the legacy root, so the video looks like the oldest
    // unlocked video-only ride.
    final halfMoved = StorageBudgetRide(
      id: inRoot('seg_half_1.mp4'),
      createdAt: DateTime(2026, 1, 1),
      files: <String>[inRoot('seg_half_1.mp4')],
    );
    final old = ride('old', 2);
    final rides = <StorageBudgetRide>[halfMoved, old];
    final selection = selectRidesForStorageBudget(
      budgetBytes: 150,
      fileSizes: sizesOf(rides),
      rides: rides,
      recordingsRoot: root,
      protectedPaths: <String>[inRoot('seg_half_1.mp4')],
    );
    expect(selection.ridesToDelete.map((r) => r.id), <String>[old.id]);
    expect(selection.protectedBytes, 100);

    // Without the protection it would have gone first.
    final unprotected = selectRidesForStorageBudget(
      budgetBytes: 150,
      fileSizes: sizesOf(rides),
      rides: rides,
      recordingsRoot: root,
    );
    expect(unprotected.ridesToDelete.first.id, halfMoved.id);
  });

  test('orphan videos and files of no ride count toward the total', () {
    final orphan = StorageBudgetRide(
      id: inRoot('orphan.mp4'),
      createdAt: DateTime(2026, 10, 1),
      files: <String>[inRoot('orphan.mp4')],
    );
    final newer = ride('newer', 5);
    final sizes = <String, int>{
      ...sizesOf(<StorageBudgetRide>[orphan, newer]),
      // An unreadable ride JSON: counted, never deleted.
      inRoot('ride_broken.telemetry.json'): 50,
    };
    final selection = selectRidesForStorageBudget(
      budgetBytes: 160,
      fileSizes: sizes,
      rides: <StorageBudgetRide>[orphan, newer],
      recordingsRoot: root,
    );
    expect(selection.totalBytes, 251);
    // The orphan video is the oldest ride and goes first.
    expect(selection.ridesToDelete.map((r) => r.id), <String>[orphan.id]);
    expect(selection.bytesToFree, 100);
  });

  test('legacy-root, staging and gallery files are never counted or '
      'selected', () {
    final legacy = StorageBudgetRide(
      id: '${_sep}legacy${_sep}MotoCam Recordings${_sep}r.telemetry.json',
      createdAt: DateTime(2026, 1, 1),
      files: <String>[
        '${_sep}legacy${_sep}MotoCam Recordings${_sep}a.mp4',
        '${_sep}legacy${_sep}MotoCam Recordings${_sep}r.telemetry.json',
      ],
    );
    final nested = StorageBudgetRide(
      id: inRoot('sub${_sep}x.mp4'),
      createdAt: DateTime(2026, 1, 2),
      files: <String>[inRoot('sub${_sep}x.mp4')],
    );
    final mine = ride('mine', 5);
    final selection = selectRidesForStorageBudget(
      budgetBytes: 50,
      fileSizes: <String, int>{
        ...sizesOf(<StorageBudgetRide>[legacy, nested]),
        ...sizesOf(<StorageBudgetRide>[mine]),
      },
      rides: <StorageBudgetRide>[legacy, nested, mine],
      recordingsRoot: root,
    );
    expect(selection.totalBytes, 101);
    expect(selection.ridesToDelete.map((r) => r.id), <String>[mine.id]);
  });

  test('an unattainable budget deletes nothing and says so', () {
    final rides = <StorageBudgetRide>[
      ride('locked', 1, locked: true),
      ride('free', 2),
    ];
    final selection = selectRidesForStorageBudget(
      budgetBytes: 50,
      fileSizes: sizesOf(rides),
      rides: rides,
      recordingsRoot: root,
    );
    expect(selection.attainable, isFalse);
    expect(selection.ridesToDelete, isEmpty);
    expect(selection.protectedBytes, 101);
    expect(
      storageBudgetNotice(
        deletedRides: 0,
        deletedBytes: 0,
        unattainable: true,
        budgetBytes: 4 * 1024 * 1024 * 1024,
      ),
      contains('Storage budget of 4 GB cannot be met'),
    );
  });

  test('the notice names the rides and the space freed', () {
    expect(
      storageBudgetNotice(
        deletedRides: 3,
        deletedBytes: (2.4 * 1024 * 1024 * 1024).round(),
        unattainable: false,
        budgetBytes: 4 * 1024 * 1024 * 1024,
      ),
      'Storage budget: deleted 3 oldest unlocked rides (2.4 GB).',
    );
    expect(
      storageBudgetNotice(
        deletedRides: 0,
        deletedBytes: 0,
        unattainable: false,
        budgetBytes: 1,
      ),
      isNull,
    );
  });

  group('scanStorageBudgetInventory', () {
    late Directory temp;
    late Directory recordings;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('motocam_budget_');
      recordings = Directory('${temp.path}${_sep}MotoCam Recordings')
        ..createSync();
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('lists the top level only and reads locks and orphans', () async {
      File write(String name, int bytes) =>
          File('${recordings.path}$_sep$name')
            ..writeAsBytesSync(List<int>.filled(bytes, 1));
      final a = write('a.mp4', 10);
      write('lone.mp4', 20);
      write('.nomedia', 0);
      Directory('${recordings.path}${_sep}staging').createSync();
      File(
        '${recordings.path}${_sep}staging${_sep}x.mp4',
      ).writeAsBytesSync(List<int>.filled(30, 1));
      File('${recordings.path}${_sep}ride_r1.telemetry.json').writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 3,
          'rideSessionId': 'r1',
          'sessionComplete': true,
          'videoPath': a.path,
          'segmentPaths': <String>[a.path],
          'lockedSegmentPaths': <String>[a.path],
          'startedAt': '2026-10-20T08:00:00.000Z',
          'samples': <Object?>[],
        }),
      );

      final inventory = await scanStorageBudgetInventory(recordings.path);
      expect(
        inventory.fileSizes.keys.map((p) => p.split(_sep).last).toSet(),
        <String>{'a.mp4', 'lone.mp4', 'ride_r1.telemetry.json'},
      );
      final byName = <String, StorageBudgetRide>{
        for (final r in inventory.rides) r.id.split(_sep).last: r,
      };
      expect(byName['ride_r1.telemetry.json']!.isLocked, isTrue);
      expect(byName['ride_r1.telemetry.json']!.rideSessionId, 'r1');
      expect(byName['ride_r1.telemetry.json']!.files, hasLength(2));
      expect(byName['lone.mp4']!.files, <String>[
        '${recordings.path}${_sep}lone.mp4',
      ]);
      expect(byName['lone.mp4']!.lastModified, isNotNull);
      expect(inventory.records, hasLength(2));
      expect(inventory.protectedPaths, isEmpty);
    });

    test(
      'a ride JSON that fails to load protects every video-only ride',
      () async {
        File write(String name, int bytes) =>
            File('${recordings.path}$_sep$name')
              ..writeAsBytesSync(List<int>.filled(bytes, 1));
        final locked = write('locked_1.mp4', 10);
        final other = write('other.mp4', 10);
        // A truncated JSON that would have locked locked_1.mp4.
        File(
          '${recordings.path}${_sep}ride_bad.telemetry.json',
        ).writeAsStringSync('{"schemaVersion": 3, "lockedSegmentPaths": ["');

        final inventory = await scanStorageBudgetInventory(recordings.path);
        expect(inventory.protectedPaths, <String>{
          path_utils.normalizePath(locked.path),
          path_utils.normalizePath(other.path),
        });
        final rides = inventory.rides;
        final selection = selectRidesForStorageBudget(
          budgetBytes: 1,
          fileSizes: inventory.fileSizes,
          rides: rides,
          recordingsRoot: recordings.path,
          protectedPaths: inventory.protectedPaths,
        );
        expect(selection.ridesToDelete, isEmpty);
      },
    );
  });
}
