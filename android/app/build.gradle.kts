android {
    namespace = "com.example.motocam"
    compileSdk = 34  // Changed from flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    
    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }
    
    defaultConfig {
        applicationId = "com.example.motocam"
        minSdk = 21  // Changed from flutter.minSdkVersion
        targetSdk = 34  // Changed from flutter.targetSdkVersion
        versionCode = 1
        versionName = "1.0"
    }
    
    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}