import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/legacy_recordings_access.dart';

const _channel = MethodChannel(LegacyRecordingsAccess.channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger().setMockMethodCallHandler(_channel, null));

  test(
    'lists files, picks, copies, cancels and deletes over the channel',
    () async {
      final calls = <MethodCall>[];
      messenger().setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'pickRecordingsTree':
            return 'content://tree/primary%3AMovies%2FMotoCam%2FRecordings';
          case 'listTree':
            return <Object?>[
              <String, Object?>{
                'uri': 'content://doc/a',
                'name': 'a.mp4',
                'size': 12,
                'canDelete': true,
              },
              <String, Object?>{
                'uri': 'content://doc/b',
                'name': 'ride_b.telemetry.json',
                'size': -1,
                'canDelete': false,
              },
              'not a document',
              <String, Object?>{'uri': 7, 'name': 'bad'},
            ];
          case 'copyDocument':
            final args = call.arguments as Map<Object?, Object?>;
            if (args['uri'] == 'content://doc/b') {
              throw PlatformException(code: 'CANCELLED');
            }
            return 12;
          case 'cancelCopy':
            return true;
          case 'deleteDocuments':
            return <String>['content://doc/b'];
        }
        return null;
      });

      final tree = await LegacyRecordingsAccess.pickRecordingsTree();
      expect(tree, contains('Recordings'));
      final access = LegacyRecordingsAccess(tree!);
      final documents = await access.list();
      expect(documents.map((d) => d.name), <String>[
        'a.mp4',
        'ride_b.telemetry.json',
      ]);
      expect(documents.first.size, 12);
      expect(documents.last.size, isNull);
      expect(documents.last.canDelete, isFalse);
      expect(calls[1].arguments, <String, Object?>{'treeUri': tree});

      expect(await access.copyTo(documents.first, '/tmp/a'), 12);
      await expectLater(
        () => access.copyTo(documents.last, '/tmp/b'),
        throwsA(isA<LegacyCopyCancelled>()),
      );
      await access.cancelCopy();
      expect(await access.delete(documents), <String>['content://doc/b']);
      expect(calls.last.arguments, <String, Object?>{
        'uris': <String>['content://doc/a', 'content://doc/b'],
      });
    },
  );

  test('other copy failures stay platform exceptions', () async {
    messenger().setMockMethodCallHandler(_channel, (call) async {
      throw PlatformException(code: 'COPY_FAILED');
    });
    final access = LegacyRecordingsAccess('content://tree/x');
    await expectLater(
      () => access.copyTo(
        const LegacyRideDocument(uri: 'content://doc/a', name: 'a.mp4'),
        '/tmp/a',
      ),
      throwsA(isA<PlatformException>()),
    );
    // cancelCopy never throws.
    await access.cancelCopy();
  });
}
