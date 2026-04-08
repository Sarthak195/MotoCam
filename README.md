# MotoCam

A navigation-enabled dashcam app for motorcycle riders built with Flutter.

## Platform Support

MotoCam is now maintained as a **mobile-only** Flutter app:

- Android
- iOS

Desktop and web platform folders were intentionally removed.

## Overview

MotoCam is a mobile application that combines video recording with location tracking and ride telemetry. It is designed for motorcycle riders to capture journeys and review recorded GPS routes during playback.

## Release Notes

### v0.1.10 (2026-04-02)

Highlights:

- Fixed day-later recording visibility issues by moving recording retention to persistent app storage instead of relying on temporary paths.
- Hardened multi-segment ride metadata handling so stale or malformed telemetry sidecars no longer hide valid video clips.
- Added fallback history discovery for video-only recovered segments (including older gallery-visible clips) with de-duplication.
- Added a clear `VIDEO ONLY (RECOVERED)` badge in ride history for clips that are playable but missing telemetry overlays.

Release artifact:
- `build/app/outputs/flutter-apk/app-release.apk`
- SHA256: `C1173CE2F7B89840838360DE182DEB19D02D2D43FD73F73805257F65F4FAAFAD`
- Size: `53,913,969 bytes (51.42 MiB)`

### v0.1.9 (2026-03-31)

Highlights:

- Added a pre-recording checklist to validate permissions, location services, camera readiness, storage writability, and device health before recording starts.
- Added an interactive route map to ride playback using OpenStreetMap tiles, with start/end/current markers and a collapsible panel state.
- Added fullscreen playback mode to hide app chrome and focus on video during ride review.
- Added playback timeline markers for incidents (high-G events) and locked segments, including tap-to-jump navigation.
- Improved camera lifecycle when moving to and from ride history by releasing idle camera resources and reinitializing cleanly.

Release artifact:
- `build/app/outputs/flutter-apk/app-release.apk`

### v0.1.8 (2026-03-28)

Highlights:

- Added runtime permission auditing for reliable camera, audio, location, and background recording behavior, with clearer in-app guidance for missing permissions.
- Added Android device status bridge and live battery/temperature telemetry on the recording screen.
- Hardened camera settings apply flow to reduce preview loss during resolution switches (interaction lock while applying, controller reset before re-init, preview texture refresh).
- Implemented safer capability-aware resolution routing so requested quality falls back to the nearest known-supported level per device/camera instead of static assumptions.
- Improved recording start and settings synchronization messaging so requested versus applied quality/FPS is transparent.

Release artifact:
- `build/app/outputs/flutter-apk/app-release.apk`

### v0.1.7 (2026-03-23)

Highlights:

- Faster and more stable speed telemetry updates with jitter filtering and stale-update fallback polling.
- Ride playback upgrades: speed graph, smoother segment transitions, timeline scrubbing improvements, and telemetry continuity fixes.
- Camera selector support with persisted lens preference.
- Android background recording improvements with a foreground notification (elapsed timer and stop action).
- Recording PiP refinements with a minimal compact UI and a blinking REC indicator.

Release artifact:
- `build/app/outputs/flutter-apk/app-release.apk`

### v0.1.5 (2026-03-22)

- Removed Mappls SDK integration to resolve startup configuration failures.
- Added persistent recording profile settings for quality, FPS, bitrate, audio, and speed refresh interval.
- Added active profile chips to the recording screen.
- Added FPS fallback handling for unsupported device and quality combinations.
- Added a static GPS route viewer in playback using recorded latitude/longitude samples.
- Enabled Android release shrinking/minification with ProGuard (R8).
- Improved telemetry refresh throttling for smoother UI performance.

Release artifact:
- `build/app/outputs/flutter-apk/app-release.apk`

## Features

- **Video Recording**: Capture dashcam footage with the device camera
- **Route Tracking**: Visualize recorded GPS routes on an interactive map viewer
- **Location Tracking**: Track your position in real-time using GPS
- **Sensor Data**: Collect accelerometer and sensor data during rides
- **Permission Management**: Automatic handling of camera, location, and sensor permissions
- **File Storage**: Efficient storage of recorded videos and data
- **Localization**: Multi-language support with intl package

## Technology Stack

- **Framework**: Flutter 3.0+
- **State Management**: Provider 6.1.1
- **Camera**: camera 0.12.0
- **Location Services**: geolocator 14.0.2
- **Sensors**: sensors_plus 7.0.0
- **Storage**: path_provider 2.1.1
- **Permissions**: permission_handler 12.0.1
- **UI**: Material Design

## Project Structure

```
lib/
├── main.dart                 # Application entry point
├── core/                     # Core utilities and constants
└── features/                 # Feature modules
```

## Getting Started

### Prerequisites

- Flutter SDK: >=3.0.0 <4.0.0
- Dart SDK: Compatible with Flutter version
- Android SDK for Android development
- Xcode for iOS development

### Installation

1. **Clone the repository**:
   ```bash
   git clone <repository-url>
   cd MotoCam
   ```

2. **Install dependencies**:
   ```bash
   flutter pub get
   ```

3. **Run the app**:
   ```bash
   flutter run
   ```

### Run From Android Studio

1. Open the project root folder in Android Studio.
2. Wait for Gradle/Flutter indexing to finish.
3. Start an emulator from Device Manager or connect a physical Android device.
4. Select the target device from the device dropdown.
5. Click the Run button (green triangle) for the Flutter run configuration.

## Required Permissions

The app requires the following permissions:

- **Camera**: To record video
- **Location**: For GPS tracking and navigation
- **Sensor Access**: To collect motion and orientation data
- **File Storage**: To save recorded videos

These permissions are managed automatically by the `permission_handler` package.

## Development

### Running Tests

```bash
flutter test
```

### Building for Release

**Android**:
```bash
flutter build apk --release
```

**iOS**:
```bash
flutter build ios --release
```

## Notes

- If Android SDK licenses are pending, run `flutter doctor --android-licenses`.
- If dependencies change, run `flutter pub get` again.

## Dependencies

For a complete list of dependencies and their versions, see [pubspec.yaml](pubspec.yaml).

## Contributing

1. Create a feature branch
2. Commit your changes
3. Push to the branch
4. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Support

For issues, feature requests, or questions, please open an issue on GitHub.

## Resources

- [Flutter Documentation](https://docs.flutter.dev/)
- [Geolocator Plugin](https://pub.dev/packages/geolocator)
- [Camera Plugin](https://pub.dev/packages/camera)
- [Provider Package](https://pub.dev/packages/provider)
