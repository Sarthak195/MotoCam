import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) {
        propertiesFile.inputStream().use { load(it) }
    }
}

val localProperties = Properties().apply {
    val propertiesFile = rootProject.file("local.properties")
    if (propertiesFile.exists()) {
        propertiesFile.inputStream().use { load(it) }
    }
}

val flutterVersionCode = (localProperties.getProperty("flutter.versionCode") ?: "1")
    .toIntOrNull()
    ?: 1
val flutterVersionName = localProperties.getProperty("flutter.versionName") ?: "1.0"

fun resolveSigningValue(propertyName: String, envName: String): String? {
    val envValue = System.getenv(envName)?.trim().orEmpty()
    if (envValue.isNotEmpty()) {
        return envValue
    }

    val propertyValue = (keystoreProperties[propertyName] as String?)?.trim().orEmpty()
    return propertyValue.ifEmpty { null }
}

val releaseStoreFilePath = resolveSigningValue("storeFile", "MOTOCAM_KEYSTORE_FILE")
val releaseStorePassword = resolveSigningValue("storePassword", "MOTOCAM_KEYSTORE_PASSWORD")
val releaseKeyAlias = resolveSigningValue("keyAlias", "MOTOCAM_KEY_ALIAS")
val releaseKeyPassword = resolveSigningValue("keyPassword", "MOTOCAM_KEY_PASSWORD")

val hasReleaseSigningConfig =
    !releaseStoreFilePath.isNullOrBlank() &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()

val releaseBuildRequested = gradle.startParameter.taskNames.any { task ->
    val normalized = task.lowercase()
    normalized.contains("release") || normalized.contains("bundle")
}

if (releaseBuildRequested && !hasReleaseSigningConfig) {
    throw GradleException(
        "Release signing config missing. Provide android/key.properties or MOTOCAM_KEYSTORE_* environment variables.",
    )
}

android {
    namespace = "com.example.motocam"
    compileSdk = 36
    ndkVersion = "28.1.13356709"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        applicationId = "com.example.motocam"
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = flutterVersionCode
        versionName = flutterVersionName
    }

    signingConfigs {
        create("release") {
            if (!releaseStoreFilePath.isNullOrBlank()) {
                storeFile = file(releaseStoreFilePath)
            }
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    implementation("androidx.concurrent:concurrent-futures:1.1.0")
}

flutter {
    source = "../.."
}
