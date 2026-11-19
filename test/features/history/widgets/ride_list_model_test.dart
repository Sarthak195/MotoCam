import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/utils/format_utils.dart';
import 'package:motocam/features/history/models/ride_record.dart';
import 'package:motocam/features/history/models/segment_verifier.dart';
import 'package:motocam/features/history/widgets/ride_list_model.dart';

import 'ride_list_fixtures.dart';

void main() {
  group('filters', () {
    test('Locked matches rides with locked clips', () {
      expect(rideMatchesFilter(listRide(locked: 1), RideFilter.locked), true);
      expect(rideMatchesFilter(listRide(), RideFilter.locked), false);
    });

    test('Incidents matches rides with at least one incident', () {
      expect(
        rideMatchesFilter(listRide(incidents: 2), RideFilter.incidents),
        true,
      );
      expect(
        rideMatchesFilter(listRide(incidents: 0), RideFilter.incidents),
        false,
      );
      // Older ride files have no incidents list.
      expect(rideMatchesFilter(listRide(), RideFilter.incidents), false);
    });

    test('Recovered matches video-only rides and rides not closed with '
        'Stop', () {
      expect(
        rideMatchesFilter(listRide(telemetryPath: null), RideFilter.recovered),
        true,
      );
      expect(
        rideMatchesFilter(listRide(complete: false), RideFilter.recovered),
        true,
      );
      expect(rideMatchesFilter(listRide(), RideFilter.recovered), false);
    });

    test('several chips narrow the list: a ride must match every one', () {
      final both = listRide(locked: 1, incidents: 1);
      final lockedOnly = listRide(locked: 1);
      const filters = <RideFilter>{RideFilter.locked, RideFilter.incidents};
      expect(rideMatchesFilters(both, filters), true);
      expect(rideMatchesFilters(lockedOnly, filters), false);
      expect(rideMatchesFilters(listRide(), const <RideFilter>{}), true);
    });
  });

  group('the incomplete-ride row', () {
    test('is a ride file not closed with Stop', () {
      expect(isIncompleteRideRow(listRide(complete: false)), true);
    });

    test('is not a complete ride nor a video-only ride', () {
      expect(isIncompleteRideRow(listRide()), false);
      expect(
        isIncompleteRideRow(listRide(telemetryPath: null, complete: false)),
        false,
      );
      expect(isIncompleteRideRow(listRide(telemetryPath: null)), false);
    });

    test('says when it ended (about), what was saved and its locked clips', () {
      expect(
        incompleteRideText(listRide(complete: false, locked: 3)),
        'Recording ended without Stop at about 14:02. 41 minutes saved, 3 '
        'locked clips.',
      );
      expect(
        incompleteRideText(listRide(complete: false, minutes: 61)),
        'Recording ended without Stop at about 14:22. 1 hour 1 minute saved.',
      );
    });

    test('carries the unsigned note only without a checked envelope', () {
      expect(
        incompleteRideNote(listRide(complete: false)),
        'Unsigned: it was not closed with Stop, so MotoCam cannot prove the '
        'files are unchanged.',
      );
      expect(
        incompleteRideNote(
          listRide(
            complete: false,
            integrity: const RideIntegrityReport.verified(),
          ),
        ),
        isNull,
      );
    });
  });

  group('stamps', () {
    const none = RideVideoCheck.none;
    const verifiedVideos = RideVideoCheck(total: 2, checked: 2, failed: 0);
    const failedVideos = RideVideoCheck(total: 2, checked: 2, failed: 1);

    List<RideStampKind> kinds({
      bool hasTelemetry = true,
      RideIntegrityStatus status = RideIntegrityStatus.unknown,
      RideSignedBy signedBy = RideSignedBy.none,
      bool mock = false,
      RideVideoCheck videoCheck = none,
      int quarantined = 0,
      int missing = 0,
      int locked = 0,
      int incidents = 0,
    }) => rideStampsFor(
      RideStampFacts(
        hasTelemetry: hasTelemetry,
        status: status,
        signedBy: signedBy,
        mockLocation: mock,
        videoCheck: videoCheck,
        quarantinedCount: quarantined,
        missingCount: missing,
        segmentCount: 6,
        lockedCount: locked,
        incidentCount: incidents,
      ),
    ).map((stamp) => stamp.kind).toList();

    test('signed with this phone\'s key is Signed on this phone', () {
      final stamps = rideStampsFor(
        const RideStampFacts(
          hasTelemetry: true,
          status: RideIntegrityStatus.verified,
          signedBy: RideSignedBy.thisDevice,
          mockLocation: false,
          videoCheck: none,
        ),
      );
      expect(stamps.single.kind, RideStampKind.signedHere);
      expect(stamps.single.label, 'Signed on this phone');
    });

    test('verified by another key, an unknown signer or none is '
        'Unmodified', () {
      for (final signer in <RideSignedBy>[
        RideSignedBy.otherKey,
        RideSignedBy.unknownSigner,
        RideSignedBy.none,
      ]) {
        expect(
          kinds(status: RideIntegrityStatus.verified, signedBy: signer),
          <RideStampKind>[RideStampKind.unmodified],
          reason: '$signer',
        );
      }
    });

    test('a ride file without an envelope is Unsigned', () {
      expect(kinds(), <RideStampKind>[RideStampKind.unsigned]);
    });

    test('a failed data check is Check failed and never Signed', () {
      expect(
        kinds(
          status: RideIntegrityStatus.modified,
          signedBy: RideSignedBy.thisDevice,
        ),
        <RideStampKind>[RideStampKind.checkFailed],
      );
    });

    test('a failed video check is Check failed in place of Signed', () {
      final stamps = rideStampsFor(
        const RideStampFacts(
          hasTelemetry: true,
          status: RideIntegrityStatus.verified,
          signedBy: RideSignedBy.thisDevice,
          mockLocation: false,
          videoCheck: failedVideos,
        ),
      );
      expect(stamps.map((s) => s.kind), <RideStampKind>[
        RideStampKind.checkFailed,
      ]);
      expect(
        stamps.single.semanticsLabel,
        'Check failed: 1 of 2 videos differ from the recorded hash',
      );
    });

    test('simulated GPS replaces Signed and Unmodified and stays beside a '
        'failed video check', () {
      expect(
        kinds(
          status: RideIntegrityStatus.verified,
          signedBy: RideSignedBy.thisDevice,
          mock: true,
        ),
        <RideStampKind>[RideStampKind.simulatedGps],
      );
      expect(
        kinds(
          status: RideIntegrityStatus.verified,
          mock: true,
          videoCheck: failedVideos,
        ),
        <RideStampKind>[RideStampKind.checkFailed, RideStampKind.simulatedGps],
      );
      expect(kinds(mock: true), <RideStampKind>[RideStampKind.simulatedGps]);
    });

    test('a failed data check with simulated GPS is Check failed only, as '
        'before', () {
      expect(
        kinds(status: RideIntegrityStatus.modified, mock: true),
        <RideStampKind>[RideStampKind.checkFailed],
      );
    });

    test('a video-only ride is Video only with no integrity stamp', () {
      expect(kinds(hasTelemetry: false), <RideStampKind>[
        RideStampKind.videoOnly,
      ]);
    });

    test('checked videos add Videos verified', () {
      expect(
        kinds(
          status: RideIntegrityStatus.verified,
          signedBy: RideSignedBy.thisDevice,
          videoCheck: verifiedVideos,
        ),
        <RideStampKind>[RideStampKind.signedHere, RideStampKind.videosVerified],
      );
    });

    test('quarantined, missing, locked and incident counts each keep a '
        'stamp', () {
      final stamps = rideStampsFor(
        const RideStampFacts(
          hasTelemetry: true,
          status: RideIntegrityStatus.modified,
          signedBy: RideSignedBy.none,
          mockLocation: false,
          videoCheck: none,
          quarantinedCount: 2,
          missingCount: 1,
          segmentCount: 6,
          lockedCount: 2,
          incidentCount: 1,
        ),
      );
      expect(stamps.map((s) => s.label), <String>[
        'Check failed',
        'Quarantined 2',
        'Incomplete',
        '2 locked',
        '1 incident',
      ]);
      expect(stamps[2].semanticsLabel, 'Incomplete: 1 of 6 clips missing');
      expect(kinds(incidents: 3).last, RideStampKind.incidents);
      expect(
        rideStampsFor(
          const RideStampFacts(
            hasTelemetry: true,
            status: RideIntegrityStatus.unknown,
            signedBy: RideSignedBy.none,
            mockLocation: false,
            videoCheck: none,
            incidentCount: 3,
          ),
        ).last.label,
        '3 incidents',
      );
    });

    test('rideStamps reads the ride', () {
      final stamps = rideStamps(
        listRide(locked: 2, incidents: 1, missing: 1, quarantined: 1),
        none,
      );
      expect(stamps.map((s) => s.kind), <RideStampKind>[
        RideStampKind.unsigned,
        RideStampKind.quarantined,
        RideStampKind.incomplete,
        RideStampKind.locked,
        RideStampKind.incidents,
      ]);
    });
  });

  group('the list', () {
    final now = DateTime(2026, 11, 19);

    String describe(List<RideListItem> items) => items
        .map(
          (item) => switch (item) {
            RideSectionHeader(:final title) => '# $title',
            RideMonthHeader(:final label) => '- $label',
            RideListRide(:final ride) =>
              '${ride.createdAt.month}/${ride.createdAt.day}'
                  '${ride.isLocked ? ' L' : ''}',
          },
        )
        .join(', ');

    final rides = <RideRecord>[
      listRide(createdAt: DateTime(2026, 11, 13)),
      listRide(createdAt: DateTime(2026, 11, 11), locked: 1),
      listRide(createdAt: DateTime(2026, 11, 9), incidents: 1),
      listRide(createdAt: DateTime(2026, 10, 30)),
      listRide(createdAt: DateTime(2025, 12, 1)),
    ];

    test('puts Locked Clips first, then All Rides with month headers', () {
      expect(
        describe(rideListItems(rides, now: now)),
        '# Locked Clips, 11/11 L, # All Rides, - NOVEMBER, 11/13, 11/9, '
        '- OCTOBER, 10/30, - DECEMBER 2025, 12/1',
      );
    });

    test('keeps the All Rides title without filters even when every ride '
        'is locked', () {
      expect(
        describe(rideListItems(<RideRecord>[rides[1]], now: now)),
        '# Locked Clips, 11/11 L, # All Rides',
      );
    });

    test('filters leave out empty sections, and nothing matches as an '
        'empty list', () {
      expect(
        describe(
          rideListItems(
            rides,
            filters: const <RideFilter>{RideFilter.locked},
            now: now,
          ),
        ),
        '# Locked Clips, 11/11 L',
      );
      expect(
        describe(
          rideListItems(
            rides,
            filters: const <RideFilter>{RideFilter.incidents},
            now: now,
          ),
        ),
        '# All Rides, - NOVEMBER, 11/9',
      );
      expect(
        rideListItems(
          rides,
          filters: const <RideFilter>{RideFilter.recovered},
          now: now,
        ),
        isEmpty,
      );
    });
  });

  group('the menu', () {
    List<RideMenuEntry> entries({
      bool android = true,
      bool isLocked = false,
      bool canChangeLockState = true,
      bool isUpdatingLock = false,
      bool galleryBusy = false,
      bool exportBusy = false,
      int galleryCopies = 0,
    }) => rideMenuEntries(
      android: android,
      isLocked: isLocked,
      canChangeLockState: canChangeLockState,
      isUpdatingLock: isUpdatingLock,
      galleryBusy: galleryBusy,
      exportBusy: exportBusy,
      galleryCopies: galleryCopies,
    );

    RideMenuEntry entry(List<RideMenuEntry> all, RideMenuAction action) =>
        all.firstWhere((e) => e.action == action);

    test('has the Share and export group on Android, then Delete', () {
      expect(entries().map((e) => e.action), <RideMenuAction>[
        RideMenuAction.exportFolder,
        RideMenuAction.share,
        RideMenuAction.saveToGallery,
        RideMenuAction.delete,
      ]);
    });

    test('offers Remove gallery copies only when the ride has some', () {
      expect(
        entries(galleryCopies: 2).map((e) => e.action),
        contains(RideMenuAction.removeGalleryCopies),
      );
    });

    test('keeps Unlock and Delete off Android, without the group', () {
      expect(
        entries(android: false, isLocked: true).map((e) => e.action),
        <RideMenuAction>[RideMenuAction.unlock, RideMenuAction.delete],
      );
    });

    test('shows Unlock only for a locked ride', () {
      expect(
        entries().map((e) => e.action),
        isNot(contains(RideMenuAction.unlock)),
      );
      final unlock = entry(entries(isLocked: true), RideMenuAction.unlock);
      expect(unlock.enabled, true);
      expect(unlock.reason, isNull);
    });

    test('disables Unlock when the lock cannot change, with the reason', () {
      final unlock = entry(
        entries(isLocked: true, canChangeLockState: false),
        RideMenuAction.unlock,
      );
      expect(unlock.enabled, false);
      expect(unlock.reason, 'Integrity warning: lock state changes disabled');
      expect(
        entry(
          entries(isLocked: true, isUpdatingLock: true),
          RideMenuAction.unlock,
        ).enabled,
        false,
      );
    });

    test('disables Unlock and Delete while a gallery job or an export of '
        'the ride runs', () {
      final gallery = entries(isLocked: true, galleryBusy: true);
      expect(entry(gallery, RideMenuAction.unlock).enabled, false);
      expect(
        entry(gallery, RideMenuAction.unlock).reason,
        'Wait for the gallery copies to finish',
      );
      expect(entry(gallery, RideMenuAction.delete).enabled, false);
      final export = entries(isLocked: true, exportBusy: true);
      expect(entry(export, RideMenuAction.unlock).enabled, false);
      expect(
        entry(export, RideMenuAction.delete).reason,
        'Wait for the export to finish',
      );
      expect(entry(export, RideMenuAction.delete).enabled, false);
    });

    test('keeps Delete enabled for a locked ride (its handler asks to '
        'unlock first, or warns about a stuck lock)', () {
      final locked = entry(entries(isLocked: true), RideMenuAction.delete);
      expect(locked.enabled, true);
      expect(locked.reason, 'Unlock the ride to delete it');
      final stuck = entry(
        entries(isLocked: true, canChangeLockState: false),
        RideMenuAction.delete,
      );
      expect(stuck.enabled, true);
      expect(stuck.reason, isNull);
    });
  });

  test('the busy slot prefers the export, then gallery, lock check and '
      'delete', () {
    RideRowBusy busy({
      bool export = false,
      bool gallery = false,
      bool lock = false,
      bool deleting = false,
    }) => rideRowBusy(
      exportBusy: export,
      galleryBusy: gallery,
      isUpdatingLock: lock,
      isDeleting: deleting,
    );
    expect(busy(), RideRowBusy.none);
    expect(
      busy(export: true, gallery: true, lock: true, deleting: true),
      RideRowBusy.export,
    );
    expect(busy(gallery: true, lock: true), RideRowBusy.gallery);
    expect(busy(lock: true, deleting: true), RideRowBusy.lockCheck);
    expect(busy(deleting: true), RideRowBusy.deleting);
  });

  group('texts', () {
    test('the summary names duration, size and clips', () {
      expect(
        rideSummaryText(listRide(clips: 6), formatFileSize),
        '41 min, 1.7 GB, 6 clips',
      );
      expect(
        rideSummaryText(
          listRide(clips: 6, missing: 2, minutes: 112, bytes: null),
          formatFileSize,
        ),
        '1 h 52 min, 4 of 6 clips',
      );
      expect(
        rideSummaryText(
          listRide(clips: 1, minutes: 0, bytes: 0),
          formatFileSize,
        ),
        '0 s, 1 clip',
      );
    });

    test('durations', () {
      expect(rideShortDuration(const Duration(seconds: 45)), '45 s');
      expect(rideShortDuration(const Duration(hours: 2)), '2 h');
      expect(rideLongDuration(const Duration(seconds: 1)), '1 second');
      expect(
        rideLongDuration(const Duration(hours: 2, minutes: 1)),
        '2 hours 1 minute',
      );
    });

    test('dates and months show the year only for another year', () {
      final now = DateTime(2026, 11, 19);
      expect(
        rideDateLabel(DateTime(2026, 11, 13, 13, 21), now),
        '13 Nov, 13:21',
      );
      expect(
        rideDateLabel(DateTime(2025, 1, 2, 8, 5), now),
        '2 Jan 2025, 08:05',
      );
      expect(rideMonthLabel(DateTime(2026, 3, 1), now), 'MARCH');
      expect(rideMonthLabel(DateTime(2025, 3, 1), now), 'MARCH 2025');
    });
  });
}
