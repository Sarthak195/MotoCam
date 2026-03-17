# MotoCam

A navigation-enabled dashcam app for motorcycle riders built with Flutter.

## Overview

MotoCam is a mobile application that combines video recording with real-time navigation and location tracking. It's designed specifically for motorcycle riders to capture their journeys while maintaining awareness of their route through integrated mapping features.

## Features

- **Video Recording**: Capture dashcam footage with the device camera
- **Real-time Navigation**: View your route using Mappls Maps SDK
- **Location Tracking**: Track your position in real-time using GPS
- **Sensor Data**: Collect accelerometer and sensor data during rides
- **Permission Management**: Automatic handling of camera, location, and sensor permissions
- **File Storage**: Efficient storage of recorded videos and data
- **Localization**: Multi-language support with intl package

## Technology Stack

- **Framework**: Flutter 3.0+
- **State Management**: Provider 6.1.1
- **Camera**: camera 0.12.0
- **Maps**: Mappls Maps SDK 2.0.3
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

3. **Configure API Keys**:
   - Mappls Maps: Add your API key to the Android and iOS configuration files

4. **Run the app**:
   ```bash
   flutter run
   ```

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
- [Mappls Maps SDK Documentation](https://mappls.com/docs/)
- [Geolocator Plugin](https://pub.dev/packages/geolocator)
- [Camera Plugin](https://pub.dev/packages/camera)
