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

All release notes are maintained in the `release-notes/` directory. See the latest entry:

- v0.1.13 (latest): [release-notes/v0.1.13.md](release-notes/v0.1.13.md)

To view detailed changes and artifacts for prior releases, open the corresponding file in `release-notes/`.

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
├── main.dart                              # Application entry point & Provider setup
├── core/
│   ├── providers/
│   │   └── app_settings_provider.dart     # Persisted user preferences (SharedPreferences)
│   ├── services/
│   │   ├── app_permission_service.dart     # Runtime permission audit & recovery
│   │   ├── background_recording_service.dart  # Android foreground-service bridge
│   │   ├── device_status_service.dart      # Battery / thermal status via MethodChannel
│   │   ├── location_service.dart           # GPS tracking wrapper (Geolocator)
│   │   └── pip_service.dart               # Picture-in-Picture bridge
│   └── utils/
│       ├── integrity_utils.dart            # SHA-256 hashing & atomic file writes
│       └── path_utils.dart                # Cross-platform path normalisation
└── features/
    ├── camera/
    │   ├── providers/
    │   │   └── camera_provider.dart        # Camera lifecycle, segments, retention
    │   └── widgets/
    │       └── camera_preview_pip.dart     # Compact camera preview widget
    ├── history/
    │   ├── models/
    │   │   └── ride_record.dart            # Ride session model + integrity checks
    │   ├── widgets/
    │   │   └── route_map_view.dart         # Interactive flutter_map route viewer
    │   ├── ride_playback_screen.dart       # Video + telemetry playback
    │   └── rides_list_screen.dart          # Ride history list
    ├── map/
    │   ├── map_source_config.dart          # Tile-provider constants
    │   └── widgets/
    │       └── static_map_viewer.dart      # CustomPaint fallback map
    ├── recording/
    │   └── recording_screen.dart           # Main recording UI & coordination
    └── telemetry/
        ├── models/
        │   └── telemetry_data.dart         # Per-sample data model
        └── providers/
            └── telemetry_provider.dart     # GPS + accelerometer collection
```

## Architecture Overview

### State Management

The app uses **Provider** (`ChangeNotifierProvider`) for reactive state management. Three providers form the core:

| Provider | Responsibility |
|---|---|
| `AppSettingsProvider` | Persists user preferences via SharedPreferences |
| `CameraProvider` | Camera lifecycle, segmented recording, rolling retention |
| `TelemetryProvider` | GPS + accelerometer sampling, incident detection, telemetry persistence |

### Native Bridges (Method Channels)

| Channel | Purpose |
|---|---|
| `com.example.motocam/pip` | Enter/detect Picture-in-Picture mode |
| `com.example.motocam/background_recording` | Android foreground service for screen-off recording |
| `com.example.motocam/device_status` | Battery level, temperature, thermal throttling |
| `com.example.motocam/media` | MediaScanner integration and gallery export |

### Integrity Pipeline

Each ride session is protected by a SHA-256 integrity envelope stored in the telemetry JSON. On playback, the `RideRecord` model verifies both the payload hash and per-segment file hashes, surfacing "VERIFIED", "MODIFIED", or "QUARANTINED" statuses to the user.

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
- **App Storage (private-first)**: To store recordings and telemetry in app-scoped directories
- **Optional Public Export**: To export selected clips to gallery-compatible public folders

These permissions are managed automatically by the `permission_handler` package.

## Development

### Running Tests

```bash
flutter test
```

### Building for Release

**Android**:
```bash
pwsh ./scripts/release-security-precheck.ps1
flutter build apk --release
```

The release precheck accepts signing credentials from either `android/key.properties` or `MOTOCAM_KEYSTORE_*` environment variables. When both are present, environment variables take precedence.
The Android version name and version code come from `pubspec.yaml` and are propagated through Flutter's generated `android/local.properties`.

**iOS**:
```bash
flutter build ios --release
```

The release precheck is Android-specific for now.

## Notes

- If Android SDK licenses are pending, run `flutter doctor --android-licenses`.
- If dependencies change, run `flutter pub get` again.
- For release builds, run `pwsh ./scripts/release-security-precheck.ps1` before packaging Android artifacts.
- Use `android/key.properties` for local signing or `MOTOCAM_KEYSTORE_*` in CI and automation.

### Local signing (recommended for open-source development)

If you want to build a signed APK for distribution (not Play Store), generate a local keystore and keep it out of source control.

1. Generate a keystore locally (interactive):

```powershell
pwsh ./scripts/generate-keystore.ps1
```

2. Copy `android/key.properties.template` to `android/key.properties` and fill the values.

3. Build a signed release APK:

```bash
flutter pub get
pwsh ./scripts/release-security-precheck.ps1
flutter build apk --release
```

Notes:
- The repository `.gitignore` already excludes `android/key.properties` and keystore files. Do not commit them.
- For Play Store distribution in future, consider enrolling in Play App Signing and using an upload key rather than exposing the app signing key.

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
