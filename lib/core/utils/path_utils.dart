/// Shared file-path utilities used across recording, telemetry, and history
/// modules.
///
/// All functions are pure or platform-aware helpers that normalise paths,
/// check containment within directories, and extract file names. They
/// intentionally avoid I/O so they remain fast and side-effect-free.
library;

import 'dart:io';

/// Normalises [path] for reliable comparison:
///
/// * Resolves relative segments (`.` and `..`).
/// * Standardises all separators to `Platform.pathSeparator`.
/// * Lower-cases the result on Windows for case-insensitive matching.
String normalizePath(String path) {
  var trimmed = path.trim().replaceAll('\\', '/');
  if (trimmed.isEmpty) {
    return trimmed;
  }

  var prefix = '';
  if (trimmed.startsWith('//')) {
    prefix = '//';
    trimmed = trimmed.substring(2);
  } else if (trimmed.length >= 2 && trimmed[1] == ':') {
    prefix = trimmed.substring(0, 2);
    trimmed = trimmed.substring(2);
    while (trimmed.startsWith('/')) {
      trimmed = trimmed.substring(1);
    }
  } else if (trimmed.startsWith('/')) {
    prefix = '/';
    trimmed = trimmed.substring(1);
  }

  final segments = <String>[];
  for (final segment in trimmed.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty && segments.last != '..') {
        segments.removeLast();
      } else if (prefix.isEmpty) {
        segments.add(segment);
      }
      continue;
    }
    segments.add(segment);
  }

  var resolved = segments.join('/');
  if (prefix.isNotEmpty) {
    if (resolved.isEmpty) {
      resolved = prefix;
    } else if (prefix == '//') {
      resolved = '$prefix$resolved';
    } else {
      resolved = '$prefix/$resolved';
    }
  }

  if (resolved.isEmpty) {
    resolved = '.';
  }

  var result = resolved.replaceAll('/', Platform.pathSeparator);
  return Platform.isWindows ? result.toLowerCase() : result;
}

/// Returns `true` when [filePath] is equal to or nested inside
/// [directoryPath], using platform-aware normalisation.
bool isPathInsideDirectory(String filePath, String directoryPath) {
  final normalizedFilePath = normalizePath(filePath);
  final normalizedDirectoryPath = normalizePath(directoryPath);
  if (normalizedFilePath == normalizedDirectoryPath) {
    return true;
  }

  final fileSegments = normalizedFilePath.split(Platform.pathSeparator);
  final dirSegments = normalizedDirectoryPath.split(Platform.pathSeparator);

  if (dirSegments.isEmpty || fileSegments.length <= dirSegments.length) {
    return false;
  }

  for (var index = 0; index < dirSegments.length; index++) {
    if (fileSegments[index] != dirSegments[index]) {
      return false;
    }
  }

  return true;
}

/// Extracts the file-name component from a full [path].
///
/// Returns [path] unchanged if it contains no separator.
String fileNameFromPath(String path) {
  final parts = path.split(Platform.pathSeparator);
  if (parts.isEmpty) {
    return path;
  }
  return parts.last;
}
