// lib/features/history/services/ride_export_text.dart
//
// The two text files of a ride export: manifest.json (format 1) and
// MOTOCAM-EXPORT.txt. Both are pure functions of the plan and the files as
// exported; neither is signed. Their fixed strings are part of the export
// format (docs/data-formats.md): change them only with that document.

import '../../../core/ride_file/ride_telemetry_codec.dart' as ride_codec;
import '../models/ride_record.dart';
import 'ride_export.dart';

/// docs/data-formats.md at the release tag, where the canonical JSON form
/// and the integrity envelope are defined. Bump the tag at each release.
const String rideExportFormatDocUrl =
    'https://github.com/Sarthak195/MotoCam/blob/v0.1.19/docs/data-formats.md';

/// `format` of manifest.json.
const String rideExportManifestFormat = 'motocam-ride-export';

/// `formatVersion` of manifest.json.
const int rideExportManifestFormatVersion = 1;

/// Longest issue string written into the text files.
const int _maxIssueLength = 80;

/// Longest file name or recorded hash written into the README.
const int _maxFieldLength = 120;

/// Column the README is wrapped at.
const int _wrapColumn = 72;

/// The integrity state of [source] for the text files (fixed strings):
/// `signed` (verified, a valid signature and envelope version 3),
/// `checksums` (verified, version 2, unsigned), `checksumsUnbound`
/// (verified, version 1), `failed` (modified) or `none` (no envelope).
String rideExportIntegrityState(RideExportSource source) {
  final integrity = source.ride.integrity;
  switch (integrity.status) {
    case RideIntegrityStatus.modified:
      return 'failed';
    case RideIntegrityStatus.unknown:
      return 'none';
    case RideIntegrityStatus.verified:
      final version = source.envelopeVersion ?? 1;
      if (version >= ride_codec.signedIntegrityEnvelopeVersion &&
          integrity.signature?.valid == true &&
          integrity.signature?.signerPublicKey != null) {
        return 'signed';
      }
      return version <= 1 ? 'checksumsUnbound' : 'checksums';
  }
}

/// [issue] for the text files: one line, control characters removed, a
/// private path after the code's prefix replaced by its file name, at most
/// 80 characters.
String sanitizeExportIssue(String issue) {
  var text = _oneLine(issue);
  final colon = text.indexOf(':');
  if (colon >= 0) {
    final rest = text.substring(colon + 1);
    text =
        '${text.substring(0, colon + 1)}${rest.split(RegExp(r'[/\\]')).last}';
  }
  return text.length > _maxIssueLength
      ? text.substring(0, _maxIssueLength)
      : text;
}

/// [text] without control characters, line or paragraph separators and
/// bidirectional embedding, override and isolate controls.
String _oneLine(String text) => text.replaceAll(
  RegExp(r'[\x00-\x1F\x7F-\x9F\u2028\u2029\u202A-\u202E\u2066-\u2069]'),
  '',
);

/// A file name or recorded hash for the README: [_oneLine], at most
/// [_maxFieldLength] characters.
String _field(String text) {
  final runes = _oneLine(text).runes;
  return String.fromCharCodes(
    runes.length > _maxFieldLength ? runes.take(_maxFieldLength) : runes,
  );
}

/// [time] in UTC as ISO 8601 with milliseconds (microseconds truncated).
String _exportedAtText(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
  time.millisecondsSinceEpoch,
  isUtc: true,
).toIso8601String();

String _signedByValue(RideSignedBy signedBy) => switch (signedBy) {
  RideSignedBy.thisDevice => 'exportingPhone',
  RideSignedBy.otherKey => 'otherKey',
  RideSignedBy.unknownSigner => 'unknownSigner',
  RideSignedBy.none => 'none',
};

String _recordedValue(RideExportRecorded recorded) => switch (recorded) {
  RideExportRecorded.match => 'match',
  RideExportRecorded.differs => 'differs',
  RideExportRecorded.none => 'none',
};

String _reasonValue(RideExportOmissionReason reason) => switch (reason) {
  RideExportOmissionReason.notSelected => 'notSelected',
  RideExportOmissionReason.missing => 'missing',
};

/// The README's `Clips:` value of [plan] (not a section).
String _clipsText(RideExportPlan plan) =>
    plan.clipChoice == RideExportClips.evidence
    ? 'locked and incident clips'
    : 'all clips';

/// manifest.json of a section export ([buildExportManifest]): no ride
/// data, no integrity block; each file with whether it was trimmed and its
/// clip-local range; `section.actualFromMs` is where the first file starts
/// in ride time (after the keyframe snap), `null` without files.
Map<String, Object?> _sectionManifest(
  RideExportPlan plan,
  RideExportSection section, {
  required List<RideExportFileEntry> clips,
  required RideExportDestination destination,
  required DateTime exportedAt,
}) => <String, Object?>{
  'format': rideExportManifestFormat,
  'formatVersion': rideExportManifestFormatVersion,
  'rideSessionId': plan.source.ride.rideSessionId,
  'exportedAt': _exportedAtText(exportedAt),
  'destination': destination == RideExportDestination.folder
      ? 'folder'
      : 'share',
  'clips': 'section',
  'section': <String, Object?>{
    'fromMs': section.fromMs,
    'toMs': section.toMs,
    'actualFromMs': _actualFromMs(plan, clips),
  },
  'rideDataIncluded': false,
  'sha256Of': destination == RideExportDestination.folder ? 'copy' : 'source',
  'integrity': null,
  'files': <Map<String, Object?>>[
    for (final clip in clips)
      <String, Object?>{
        'name': clip.name,
        'bytes': clip.bytes,
        'sha256': clip.sha256,
        'trimmed': clip.trimmed,
        'clipFromMs': clip.clipFromMs,
        'clipToMs': clip.clipToMs,
      },
  ],
  'rideData': null,
  'notExported': <Map<String, Object?>>[
    for (final omission in plan.notExported)
      <String, Object?>{
        'name': omission.name,
        'reason': _reasonValue(omission.reason),
      },
  ],
};

/// Where the first of [clips] starts in ride time, or `null` without one.
int? _actualFromMs(RideExportPlan plan, List<RideExportFileEntry> clips) {
  final part = plan.clips.isEmpty ? null : plan.clips.first.part;
  final from = clips.isEmpty ? null : clips.first.clipFromMs;
  return part == null || from == null ? null : part.rideStartMs + from;
}

/// manifest.json (format 1) of an export of [plan] whose [clips] and
/// [rideData] were exported (for a share: hashed) at [exportedAt]. The
/// `integrity` block is `null` when the ride data is not included, except
/// that a video-only export in the `failed` or `none` state writes only
/// that `state`; its `signed`, `alg`, `keyId` and `publicKey` fields are
/// written only in the `signed` state.
Map<String, Object?> buildExportManifest(
  RideExportPlan plan, {
  required List<RideExportFileEntry> clips,
  required RideExportFileEntry? rideData,
  required RideExportDestination destination,
  required DateTime exportedAt,
}) {
  final section = plan.section;
  if (section != null) {
    return _sectionManifest(
      plan,
      section,
      clips: clips,
      destination: destination,
      exportedAt: exportedAt,
    );
  }
  final source = plan.source;
  final ride = source.ride;
  Map<String, Object?>? integrity;
  if (plan.includeRideData) {
    final state = rideExportIntegrityState(source);
    final signed = state == 'signed';
    integrity = <String, Object?>{
      'state': state,
      if (signed) ...<String, Object?>{
        'signed': true,
        'alg': source.signatureAlg,
        'keyId': source.signatureKeyId,
        'publicKey': ride.integrity.signature?.signerPublicKey,
      },
      'signedBy': signed ? _signedByValue(ride.integrity.signedBy) : 'none',
      'envelopeVersion': source.envelopeVersion,
      'sessionComplete': ride.isSessionComplete,
      'mockLocationDetected': ride.mockLocationDetected,
      'issues': <String>[
        for (final issue in ride.integrity.issues) sanitizeExportIssue(issue),
      ],
    };
  } else {
    final state = rideExportIntegrityState(source);
    if (state == 'failed' || state == 'none') {
      integrity = <String, Object?>{'state': state};
    }
  }
  return <String, Object?>{
    'format': rideExportManifestFormat,
    'formatVersion': rideExportManifestFormatVersion,
    'rideSessionId': ride.rideSessionId,
    'exportedAt': _exportedAtText(exportedAt),
    'destination': destination == RideExportDestination.folder
        ? 'folder'
        : 'share',
    'clips': plan.clipChoice == RideExportClips.evidence ? 'evidence' : 'all',
    'section': null,
    'rideDataIncluded': plan.includeRideData,
    'sha256Of': destination == RideExportDestination.folder ? 'copy' : 'source',
    'integrity': integrity,
    'files': <Map<String, Object?>>[
      for (final clip in clips)
        <String, Object?>{
          'name': clip.name,
          'kind': 'clip',
          'bytes': clip.bytes,
          'sha256': clip.sha256,
          'recordedSha256': clip.recordedSha256,
          'recorded': _recordedValue(clip.recorded),
          'locked': clip.locked,
        },
    ],
    'rideData': rideData == null
        ? null
        : <String, Object?>{
            'name': rideData.name,
            'bytes': rideData.bytes,
            'sha256': rideData.sha256,
          },
    'notExported': <Map<String, Object?>>[
      for (final omission in plan.notExported)
        <String, Object?>{
          'name': omission.name,
          if (omission.recordedSha256 != null)
            'recordedSha256': omission.recordedSha256,
          'reason': _reasonValue(omission.reason),
        },
    ],
  };
}

/// MOTOCAM-EXPORT.txt of an export of [plan] (see [buildExportManifest]),
/// wrapped near 72 columns; keys, hashes, commands and the URL are never
/// wrapped. A section's README names its files and ranges only: no
/// integrity, key or verification text.
String buildExportReadme(
  RideExportPlan plan, {
  required List<RideExportFileEntry> clips,
  required RideExportFileEntry? rideData,
  required RideExportDestination destination,
  required DateTime exportedAt,
}) {
  final section = plan.section;
  if (section != null) {
    return _sectionReadme(
      plan,
      section,
      clips: clips,
      destination: destination,
      exportedAt: exportedAt,
    );
  }
  final source = plan.source;
  final ride = source.ride;
  final folder = destination == RideExportDestination.folder;
  final out = StringBuffer();
  void line([String text = '']) => out.writeln(text);
  void para(String text) {
    out.writeln(_wrap(text));
    out.writeln();
  }

  void heading(String text) {
    line(text);
    line('-' * text.length);
  }

  line('MotoCam ride export');
  line('===================');
  line();
  line('Ride: ${_field(ride.rideSessionId ?? ride.fileName)}');
  line('Exported: ${_exportedAtText(exportedAt)} (UTC)');
  line('Local time: ${_localTime(exportedAt)}');
  line('Clips: ${_clipsText(plan)}');
  line(
    'Ride data: ${plan.includeRideData ? 'included (${_field(rideData?.name ?? plan.rideData?.name ?? '')})' : 'not included (video only)'}',
  );
  line(
    folder
        ? 'Destination: a folder picked on the phone'
        : 'Destination: the Android share sheet',
  );
  line();

  heading('Integrity');
  final state = rideExportIntegrityState(source);
  if (!plan.includeRideData) {
    para(
      source.hasRideData
          ? 'Video only: the ride data is not included, so nothing in this '
                'export can be checked against the ride\'s checksums or '
                'signature.'
          : 'No integrity data (older ride format or a video-only '
                'recovery).',
    );
    if (state == 'failed') {
      para(
        'The phone\'s integrity check of this ride failed when exported, so '
        'the recorded hashes listed below cannot be relied on.',
      );
    } else if (state == 'none') {
      para(
        'This ride has no integrity data, so the recorded hashes listed '
        'below cannot be relied on.',
      );
    }
  } else {
    switch (state) {
      case 'signed':
        para(
          'SIGNED: the ride data and the listed clip hashes were not '
          'changed after the holder of this key signed them (ECDSA P-256, '
          'SHA-256).',
        );
        para(
          'The key was made by the phone and is not certified by anyone. '
          'It identifies the signer only if you already know this key from '
          'another source (for example the rider\'s earlier exports). It '
          'does not prove the footage is genuine: a rooted phone or a '
          'modified app can sign anything.',
        );
      case 'checksums':
        para(
          'Unsigned: SHA-256 checksums only. They show accidental '
          'corruption, not deliberate edits: anyone who can edit the files '
          'can recompute them.',
        );
      case 'checksumsUnbound':
        para(
          'Older format: the clip checksums are not covered by the ride '
          'checksum, so they show accidental corruption of the clips only.',
        );
      case 'failed':
        final issues = <String>[
          for (final issue in ride.integrity.issues) sanitizeExportIssue(issue),
        ];
        para(
          'INTEGRITY CHECK FAILED when exported: '
          '${issues.isEmpty ? 'no details' : issues.join(', ')}.',
        );
      default:
        para('No integrity data (older ride format or a video-only recovery).');
    }
    if (!ride.isSessionComplete) {
      para(
        'This ride ended without Stop: the ride data ends at its last '
        'checkpoint; clips recorded after it are separate rides and are not '
        'covered.',
      );
    }
    if (ride.mockLocationDetected) {
      para(
        'SIMULATED GPS: the phone reported mock locations during this ride.',
      );
    }
  }
  para(
    'Recorded-hash results mean something only when the integrity line is '
    'SIGNED or Unsigned.',
  );
  final matched = clips
      .where((c) => c.recorded == RideExportRecorded.match)
      .length;
  final differ = clips
      .where((c) => c.recorded == RideExportRecorded.differs)
      .length;
  final none = clips.where((c) => c.recorded == RideExportRecorded.none).length;
  para(
    '$matched of ${clips.length} exported clips match their recorded hash; '
    '$differ differ; $none have none.',
  );

  final publicKey = ride.integrity.signature?.signerPublicKey;
  if (plan.includeRideData && state == 'signed' && publicKey != null) {
    heading('Signer key');
    line('keyId: ${_field(source.signatureKeyId ?? '')}');
    line('Public key (base64 SubjectPublicKeyInfo DER):');
    line(publicKey);
    line('Fingerprint (SHA-256 of the key DER):');
    line(ride_codec.rideSigningKeyFingerprintOf(publicKey) ?? '');
    line();
    para(
      'Compare the full public key (or its fingerprint) with a key you '
      'already know, not the short keyId.',
    );
    switch (ride.integrity.signedBy) {
      case RideSignedBy.thisDevice:
        para('The phone that made this export holds this key.');
      case RideSignedBy.otherKey:
        para(
          'This is not the key of the phone that made this export (another '
          'phone, or an earlier install of MotoCam).',
        );
      case RideSignedBy.unknownSigner:
        para(
          'The phone that made this export could not read its own key, so '
          'it cannot tell whether it holds this key.',
        );
      case RideSignedBy.none:
        break;
    }
  }

  heading('Files');
  para(
    folder
        ? 'Each SHA-256 is of the copy in this folder, read back after '
              'copying.'
        : 'Each SHA-256 is of the file on the phone: MotoCam cannot read '
              'the copy the receiving app made.',
  );
  for (final clip in clips) {
    line('${_field(clip.name)} (clip${clip.locked ? ', locked' : ''})');
    line('  ${clip.bytes} bytes');
    line('  SHA-256: ${clip.sha256}');
    switch (clip.recorded) {
      case RideExportRecorded.match:
        line('  Recorded hash: matches');
      case RideExportRecorded.differs:
        line(
          '  Recorded hash: DIFFERS, recorded '
          '${_field(clip.recordedSha256 ?? '')}',
        );
      case RideExportRecorded.none:
        // A recorded value that is not a SHA-256 counts as none.
        line('  Recorded hash: ${clip.recordedInvalid ? 'invalid' : 'none'}');
    }
  }
  if (rideData != null) {
    line('${_field(rideData.name)} (ride data, copied byte for byte)');
    line('  ${rideData.bytes} bytes');
    line('  SHA-256: ${rideData.sha256}');
  }
  line();

  if (plan.notExported.isNotEmpty || plan.unmappedIncidentsMs.isNotEmpty) {
    heading('Not exported');
    for (final omission in plan.notExported) {
      final recorded = omission.recordedSha256;
      final name = _field(omission.name);
      switch (omission.reason) {
        case RideExportOmissionReason.notSelected:
          line('$name: not selected');
        case RideExportOmissionReason.missing:
          line('$name: missing on the phone');
      }
      if (recorded != null) {
        line('  Recorded SHA-256: ${_field(recorded)}');
      } else if (omission.recordedInvalid) {
        line('  Recorded SHA-256: invalid');
      }
    }
    for (final ms in plan.unmappedIncidentsMs) {
      line('Incident at ${_minutesSeconds(ms)} not in any kept clip');
    }
    line();
  }

  void hashCommands() {
    line('  sha256sum FILE                    (Linux or macOS)');
    line('  certutil -hashfile FILE SHA256    (Windows)');
    line();
  }

  heading('How to check');
  if (plan.includeRideData) {
    para(
      state == 'none'
          ? 'Only step 1 applies: this ride has no integrity data, so steps '
                '2 and 3 (payloadHash and signature) do not apply.'
          : 'Every step is required.',
    );
    para(
      '1. Hash each clip. It must equal the SHA-256 listed above and the '
      'integrity.segmentHashes value in the ride data whose key ends in '
      'that file name (the keys are the phone\'s private paths):',
    );
    hashCommands();
    para(
      '2. Recompute payloadHash from the ride data: for envelopeVersion 3 '
      'remove integrity.payloadHash and integrity.signature; for version 2 '
      'remove integrity.payloadHash; for version 1 (no envelopeVersion) '
      'remove integrity. Then take the SHA-256 of the canonical JSON (keys '
      'sorted, compact, as Dart jsonEncode writes it) and compare it with '
      'the stored integrity.payloadHash.',
    );
    para(
      '3. Verify the signature (SIGNED rides): the message is the 64 ASCII '
      'characters of the lowercase payloadHash, with no newline. '
      'integrity.signature.sig is base64 DER (not JOSE r||s). With '
      'openssl, where PAYLOADHASH, SIG and PUBLICKEY are the values from '
      'the ride data:',
    );
    line('  printf %s PAYLOADHASH > m');
    line("  printf %s 'SIG' | openssl base64 -d -A > sig.der");
    line(
      "  printf -- '-----BEGIN PUBLIC KEY-----\\n%s\\n-----END PUBLIC KEY-----\\n' 'PUBLICKEY' > pub.pem",
    );
    line('  openssl dgst -sha256 -verify pub.pem -signature sig.der m');
    line();
    para(
      'The canonical form and the integrity envelope are defined in '
      'docs/data-formats.md at:',
    );
    line(rideExportFormatDocUrl);
    line();
    para(
      'A payloadHash mismatch caused by another language\'s JSON encoder '
      'is not by itself evidence of tampering.',
    );
  } else {
    para(
      'Hash each clip and compare it with the list above. Without the ride '
      'data that only shows that a copy matches this list:',
    );
    hashCommands();
  }

  heading('Privacy');
  para(
    'Videos show other road users: share them only for your own records, '
    'the police or your insurer.',
  );
  if (plan.includeRideData) {
    para(
      'The ride data holds the route, the speed every second and private '
      'file paths of the phone.',
    );
    para(
      'All exports from this phone carry the same public key, so they can '
      'be linked to each other.',
    );
  }
  if (folder) {
    para(
      'The folder you pick is shared storage: other apps with media or '
      'storage access, and gallery backups, may see these files.',
    );
    para('A folder without MOTOCAM-EXPORT.txt is an incomplete export.');
  }
  para('manifest.json and this file are not signed.');
  return '${out.toString().trimRight()}\n';
}

/// MOTOCAM-EXPORT.txt of a section export ([buildExportReadme]).
String _sectionReadme(
  RideExportPlan plan,
  RideExportSection section, {
  required List<RideExportFileEntry> clips,
  required RideExportDestination destination,
  required DateTime exportedAt,
}) {
  final ride = plan.source.ride;
  final folder = destination == RideExportDestination.folder;
  final out = StringBuffer();
  void line([String text = '']) => out.writeln(text);
  void para(String text) {
    out.writeln(_wrap(text));
    out.writeln();
  }

  void heading(String text) {
    line(text);
    line('-' * text.length);
  }

  line('MotoCam ride export');
  line('===================');
  line();
  line('Ride: ${_field(ride.rideSessionId ?? ride.fileName)}');
  line('Exported: ${_exportedAtText(exportedAt)} (UTC)');
  line('Local time: ${_localTime(exportedAt)}');
  line(
    'Section: ${_minutesSeconds(section.fromMs)} to '
    '${_minutesSeconds(section.toMs)} of the ride (clock time '
    '${rideExportClockText(ride, section.fromMs)} to '
    '${rideExportClockText(ride, section.toMs)})',
  );
  line('Ride data: not included (video only)');
  line(
    folder
        ? 'Destination: a folder picked on the phone'
        : 'Destination: the Android share sheet',
  );
  line();

  heading('Files');
  para(
    folder
        ? 'Each SHA-256 is of the copy in this folder, read back after '
              'copying.'
        : 'Each SHA-256 is of the file on the phone: MotoCam cannot read '
              'the copy the receiving app made.',
  );
  for (final clip in clips) {
    line('${_field(clip.name)} (${clip.trimmed ? 'trimmed' : 'whole clip'})');
    line(
      '  In the clip: ${_clipTime(clip.clipFromMs ?? 0)} to '
      '${_clipTime(clip.clipToMs ?? 0)}',
    );
    line('  ${clip.bytes} bytes');
    line('  SHA-256: ${clip.sha256}');
  }
  for (final omission in plan.notExported) {
    line('${_field(omission.name)}: missing on the phone');
  }
  line();
  para(
    'Files keep their original clip names. Trimmed files are cut copies '
    'made without re-encoding: they are not the original recordings and do '
    'not match the original clips\' checksums. This export carries no ride '
    'data and no signature.',
  );

  heading('Privacy');
  para(
    'Videos show other road users: share them only for your own records, '
    'the police or your insurer.',
  );
  if (folder) {
    para(
      'The folder you pick is shared storage: other apps with media or '
      'storage access, and gallery backups, may see these files.',
    );
  }
  return '${out.toString().trimRight()}\n';
}

/// [ms] in a clip as `mm:ss.mmm`.
String _clipTime(int ms) =>
    '${_minutesSeconds(ms)}.${(ms % 1000).toString().padLeft(3, '0')}';

/// Greedy word wrap at [_wrapColumn]; a word longer than a line stands
/// alone.
String _wrap(String text) {
  final lines = <String>[];
  var current = '';
  for (final word in text.split(' ')) {
    if (word.isEmpty) {
      continue;
    }
    if (current.isEmpty) {
      current = word;
    } else if (current.length + 1 + word.length <= _wrapColumn) {
      current = '$current $word';
    } else {
      lines.add(current);
      current = word;
    }
  }
  if (current.isNotEmpty) {
    lines.add(current);
  }
  return lines.join('\n');
}

String _two(int value) => value.toString().padLeft(2, '0');

/// [time] in local time with its UTC offset, for example
/// `2026-11-19 18:35:00 (UTC+05:30)`.
String _localTime(DateTime time) {
  final local = time.toLocal();
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  return '${local.year}-${_two(local.month)}-${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)} '
      '(UTC$sign${_two(abs.inHours)}:${_two(abs.inMinutes.remainder(60))})';
}

/// [ms] as `mm:ss` (minutes not wrapped at 60).
String _minutesSeconds(int ms) =>
    '${_two(ms ~/ 60000)}:${_two((ms ~/ 1000) % 60)}';
