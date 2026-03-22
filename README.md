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

### v0.1.5 (2026-03-22)

- Removed Mappls SDK integration to eliminate startup configuration failures.
- Added persistent recording profile settings (quality, FPS, bitrate, audio, speed refresh interval).
- Added active profile chips on the recording screen.
- Added FPS fallback handling for unsupported device combinations.
- Added static GPS route viewer in playback using recorded latitude/longitude samples.
- Added release build shrinking/minification with ProGuard rules.
- Improved telemetry UI refresh throttling for smoother performance.

Release APK output:
- build/app/outputs/flutter-apk/app-release.apk

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
