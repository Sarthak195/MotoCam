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
/// * Converts all separators to `Platform.pathSeparator`.
/// * Strips trailing separators.
/// * Lower-cases the result on Windows for case-insensitive matching.
String normalizePath(String path) {
  var normalized = path.replaceAll('\\', Platform.pathSeparator);
  normalized = normalized.replaceAll('/', Platform.pathSeparator);
  while (normalized.length > 1 && normalized.endsWith(Platform.pathSeparator)) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

/// Returns `true` when [filePath] is equal to or nested inside
/// [directoryPath], using platform-aware normalisation.
bool isPathInsideDirectory(String filePath, String directoryPath) {
  final normalizedFilePath = normalizePath(filePath);
  final normalizedDirectoryPath = normalizePath(directoryPath);
  if (normalizedFilePath == normalizedDirectoryPath) {
    return true;
  }
  return normalizedFilePath
      .startsWith('$normalizedDirectoryPath${Platform.pathSeparator}');
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
