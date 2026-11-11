# camera_android_camerax, vendored for MotoCam

Upstream: camera_android_camerax 0.7.2 from pub.dev (pub cache sha256 b5064cf25a2787d122d0bf12e77c7b1033a2b983d0730e3091f770ee376efde5), copied unchanged except that `example/` is left out. Used through `dependency_overrides` in the app's pubspec.yaml. Licence: LICENSE in this folder (BSD-style, The Flutter Authors).

Why vendored: two fixes found on the phone on 2026-11-11 need changes inside this plugin (details and evidence: MotoCam-audit-data/2026-10-20/device-run-2026-11-10/crash-and-roll-facts.md).

## Patches

None yet in this commit; see the next commit and the list below once added.

## Upgrading

When moving to a newer upstream version, copy the new release over this folder (leave out `example/`), reapply every patch listed above, run this package's tests (`flutter pub get` and `flutter test` in this folder) and the app's checks, and repeat the phone checks named in each patch.
