import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:motocam/core/utils/path_utils.dart';

void main() {
  final sep = Platform.pathSeparator;
  String native(String posixPath) => posixPath.replaceAll('/', sep);

  group('normalizePath', () {
    test('resolves dot segments and duplicate separators', () {
      final expected = native('/a/c/d');
      final normalized = normalizePath('/a/b/../c//./d/');
      expect(
        normalized,
        Platform.isWindows ? expected.toLowerCase() : expected,
      );
    });

    test('does not climb above an absolute root', () {
      final expected = native('/x');
      final normalized = normalizePath('/../../x');
      expect(
        normalized,
        Platform.isWindows ? expected.toLowerCase() : expected,
      );
    });
  });

  group('isPathInsideDirectory', () {
    test('accepts nested paths and the directory itself', () {
      expect(isPathInsideDirectory('/data/rec/a.mp4', '/data/rec'), isTrue);
      expect(isPathInsideDirectory('/data/rec', '/data/rec/'), isTrue);
    });

    test('rejects siblings, prefixes and traversal', () {
      expect(
        isPathInsideDirectory('/data/recordings/a.mp4', '/data/rec'),
        isFalse,
      );
      expect(
        isPathInsideDirectory('/data/rec/../other/a.mp4', '/data/rec'),
        isFalse,
      );
      expect(isPathInsideDirectory('/data', '/data/rec'), isFalse);
    });
  });

  group('fileNameFromPath', () {
    test('returns the last component', () {
      expect(fileNameFromPath(native('/data/rec/REC1.mp4')), 'REC1.mp4');
      expect(fileNameFromPath('/data/rec/REC2.mp4'), 'REC2.mp4');
      expect(fileNameFromPath('REC3.mp4'), 'REC3.mp4');
    });
  });
}
