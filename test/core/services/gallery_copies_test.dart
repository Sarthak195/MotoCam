import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motocam/core/services/gallery_copies.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(GalleryCopies.channel, null);
  });

  test('statuses are parsed per URI; unknown values are failures', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(GalleryCopies.channel, (call) async {
      calls.add(call);
      return <String, Object?>{
        'u1': 'deleted',
        'u2': 'needsConsent',
        'u3': 'something new',
      };
    });
    final statuses = await GalleryCopies.delete(<String>['u1', 'u2', 'u3']);
    expect(calls.single.method, 'deleteGalleryItems');
    expect(calls.single.arguments, <String, Object?>{
      'uris': <String>['u1', 'u2', 'u3'],
    });
    expect(statuses, <String, GalleryCopyStatus>{
      'u1': GalleryCopyStatus.deleted,
      'u2': GalleryCopyStatus.needsConsent,
      'u3': GalleryCopyStatus.failed,
    });
  });

  test('a channel error or missing handler reports failures', () async {
    messenger.setMockMethodCallHandler(GalleryCopies.channel, (call) async {
      throw PlatformException(code: 'BUSY');
    });
    expect(
      await GalleryCopies.requestDelete(<String>['u1']),
      <String, GalleryCopyStatus>{'u1': GalleryCopyStatus.failed},
    );
    expect(await GalleryCopies.existingUris(<String>['u1']), isNull);

    messenger.setMockMethodCallHandler(GalleryCopies.channel, null);
    expect(
      await GalleryCopies.delete(<String>['u1']),
      <String, GalleryCopyStatus>{'u1': GalleryCopyStatus.failed},
    );
  });

  test('existingUris returns the URIs the native side still finds', () async {
    messenger.setMockMethodCallHandler(GalleryCopies.channel, (call) async {
      expect(call.method, 'galleryItemsExist');
      return <String>['u2'];
    });
    expect(await GalleryCopies.existingUris(<String>['u1', 'u2']), <String>{
      'u2',
    });
    expect(await GalleryCopies.existingUris(const <String>[]), <String>{});
  });

  test('removed means deleted or missing', () {
    expect(GalleryCopyStatus.deleted.isRemoved, isTrue);
    expect(GalleryCopyStatus.missing.isRemoved, isTrue);
    for (final status in <GalleryCopyStatus>[
      GalleryCopyStatus.needsConsent,
      GalleryCopyStatus.needsPermission,
      GalleryCopyStatus.denied,
      GalleryCopyStatus.failed,
    ]) {
      expect(status.isRemoved, isFalse);
    }
  });
}
