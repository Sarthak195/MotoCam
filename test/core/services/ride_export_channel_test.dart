import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/ride_export_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = RideExportChannel.channel;
  const native = RideExportChannel();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger().setMockMethodCallHandler(channel, null));

  test('the channel name matches the native side', () {
    expect(channel.name, 'com.example.motocam/ride_export');
  });

  test('every method sends the exact argument map', () async {
    final calls = <MethodCall>[];
    messenger().setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'pickExportFolder':
          return 'content://tree/x';
        case 'prepareFolder':
          return 'content://tree/x/document/y';
        case 'exportFile':
          return <String, Object?>{
            'bytes': 12,
            'sourceSha256': 'AB',
            'copySha256': 'ab',
            'skipped': false,
            'synced': true,
          };
        case 'hashFile':
          return <String, Object?>{'bytes': 3, 'sha256': 'CD'};
        case 'trimClip':
          return <String, Object?>{
            'bytes': 7,
            'firstUs': 11960000,
            'lastUs': 39966000,
          };
        case 'cancel':
          return true;
        case 'shareFiles':
          return true;
        case 'setKeepScreenOn':
          return null;
      }
      return null;
    });

    expect(await native.pickExportFolder(), 'content://tree/x');
    expect(
      await native.prepareFolder(
        treeUri: 'content://tree/x',
        name: 'MotoCam ride a (all clips)',
        expectedNames: <String>['a.mp4', 'manifest.json'],
      ),
      'content://tree/x/document/y',
    );
    final exported = await native.exportFile(
      folderUri: 'content://tree/x/document/y',
      sourcePath: '/data/a.mp4',
      name: 'a.mp4',
      mimeType: 'video/mp4',
    );
    expect(exported.bytes, 12);
    expect(exported.sourceSha256, 'ab');
    expect(exported.copySha256, 'ab');
    expect(exported.skipped, isFalse);
    expect(exported.synced, isTrue);
    final hashed = await native.hashFile('/data/a.mp4');
    expect(hashed.bytes, 3);
    expect(hashed.sha256, 'cd');
    await native.cancel();
    final trimmed = await native.trimClip(
      sourcePath: '/data/a.mp4',
      targetPath: '/cache/ride_export/trim/a.mp4',
      startUs: 12000000,
      endUs: 40000000,
    );
    expect(trimmed.bytes, 7);
    expect(trimmed.firstUs, 11960000);
    expect(trimmed.lastUs, 39966000);
    await native.exportFile(
      folderUri: 'content://tree/x/document/y',
      sourcePath: '/cache/ride_export/trim/a.mp4',
      name: 'a.mp4',
      mimeType: 'video/mp4',
      replace: true,
    );
    expect(
      await native.shareFiles(
        paths: <String>['/data/a.mp4'],
        mimeTypes: <String>['video/mp4'],
        subject: 'MotoCam ride a (all clips)',
      ),
      isTrue,
    );
    await native.setKeepScreenOn(true);

    expect(calls.map((c) => c.method), <String>[
      'pickExportFolder',
      'prepareFolder',
      'exportFile',
      'hashFile',
      'cancel',
      'trimClip',
      'exportFile',
      'shareFiles',
      'setKeepScreenOn',
    ]);
    expect(calls[0].arguments, isNull);
    expect(calls[1].arguments, <String, Object?>{
      'treeUri': 'content://tree/x',
      'name': 'MotoCam ride a (all clips)',
      'expectedNames': <String>['a.mp4', 'manifest.json'],
    });
    expect(calls[2].arguments, <String, Object?>{
      'folderUri': 'content://tree/x/document/y',
      'sourcePath': '/data/a.mp4',
      'name': 'a.mp4',
      'mimeType': 'video/mp4',
      'replace': false,
    });
    expect(calls[3].arguments, <String, Object?>{'path': '/data/a.mp4'});
    expect(calls[4].arguments, isNull);
    expect(calls[5].arguments, <String, Object?>{
      'sourcePath': '/data/a.mp4',
      'targetPath': '/cache/ride_export/trim/a.mp4',
      'startUs': 12000000,
      'endUs': 40000000,
    });
    expect(calls[6].arguments, <String, Object?>{
      'folderUri': 'content://tree/x/document/y',
      'sourcePath': '/cache/ride_export/trim/a.mp4',
      'name': 'a.mp4',
      'mimeType': 'video/mp4',
      'replace': true,
    });
    expect(calls[7].arguments, <String, Object?>{
      'paths': <String>['/data/a.mp4'],
      'mimeTypes': <String>['video/mp4'],
      'subject': 'MotoCam ride a (all clips)',
    });
    expect(calls[8].arguments, <String, Object?>{'enabled': true});
  });

  test('a cancelled picker gives null', () async {
    messenger().setMockMethodCallHandler(channel, (call) async => null);
    expect(await native.pickExportFolder(), isNull);
    messenger().setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'CANCELLED'),
    );
    expect(await native.pickExportFolder(), isNull);
  });

  test('CANCELLED becomes RideExportCancelled', () async {
    messenger().setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'CANCELLED'),
    );
    await expectLater(
      native.exportFile(
        folderUri: 'f',
        sourcePath: 's',
        name: 'n',
        mimeType: 'video/mp4',
      ),
      throwsA(isA<RideExportCancelled>()),
    );
    await expectLater(
      native.hashFile('s'),
      throwsA(isA<RideExportCancelled>()),
    );
    await expectLater(
      native.trimClip(sourcePath: 's', targetPath: 't', startUs: 0, endUs: 1),
      throwsA(isA<RideExportCancelled>()),
    );
  });

  test('TRIM_FAILED keeps its message', () async {
    messenger().setMockMethodCallHandler(
      channel,
      (call) async =>
          throw PlatformException(code: 'TRIM_FAILED', message: 'no video'),
    );
    await expectLater(
      native.trimClip(sourcePath: 's', targetPath: 't', startUs: 0, endUs: 1),
      throwsA(
        isA<RideExportFailure>()
            .having((f) => f.code, 'code', 'TRIM_FAILED')
            .having((f) => f.message, 'message', 'no video'),
      ),
    );
  });

  test('other platform errors become failures with their code', () async {
    messenger().setMockMethodCallHandler(
      channel,
      (call) async =>
          throw PlatformException(code: 'EXISTS_DIFFERENT', message: 'a.mp4'),
    );
    await expectLater(
      native.exportFile(
        folderUri: 'f',
        sourcePath: 's',
        name: 'a.mp4',
        mimeType: 'video/mp4',
      ),
      throwsA(
        isA<RideExportFailure>()
            .having((f) => f.code, 'code', 'EXISTS_DIFFERENT')
            .having((f) => f.message, 'message', 'a.mp4'),
      ),
    );
    messenger().setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'NO_PICKER'),
    );
    await expectLater(
      native.pickExportFolder(),
      throwsA(
        isA<RideExportFailure>().having((f) => f.code, 'code', 'NO_PICKER'),
      ),
    );
  });

  test('a missing native side is an UNAVAILABLE failure', () async {
    await expectLater(
      native.prepareFolder(
        treeUri: 't',
        name: 'n',
        expectedNames: const <String>[],
      ),
      throwsA(
        isA<RideExportFailure>().having((f) => f.code, 'code', 'UNAVAILABLE'),
      ),
    );
    await expectLater(
      native.shareFiles(
        paths: const <String>[],
        mimeTypes: const <String>[],
        subject: 's',
      ),
      throwsA(isA<RideExportFailure>()),
    );
    // cancel and setKeepScreenOn never throw.
    await native.cancel();
    await native.setKeepScreenOn(false);
  });

  test('a reply of the wrong shape is an INVALID_REPLY failure', () async {
    messenger().setMockMethodCallHandler(
      channel,
      (call) async => <String, Object?>{'bytes': 'twelve'},
    );
    await expectLater(
      native.hashFile('s'),
      throwsA(
        isA<RideExportFailure>().having((f) => f.code, 'code', 'INVALID_REPLY'),
      ),
    );
    await expectLater(
      native.trimClip(sourcePath: 's', targetPath: 't', startUs: 0, endUs: 1),
      throwsA(
        isA<RideExportFailure>().having((f) => f.code, 'code', 'INVALID_REPLY'),
      ),
    );
  });
}
