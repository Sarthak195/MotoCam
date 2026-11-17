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

// Each value independently prefers its environment variable and falls back to
// android/key.properties.
val missingSigningValues = listOf(
    "storeFile (MOTOCAM_KEYSTORE_FILE)" to releaseStoreFilePath,
    "storePassword (MOTOCAM_KEYSTORE_PASSWORD)" to releaseStorePassword,
    "keyAlias (MOTOCAM_KEY_ALIAS)" to releaseKeyAlias,
    "keyPassword (MOTOCAM_KEY_PASSWORD)" to releaseKeyPassword,
).filter { (_, value) -> value.isNullOrBlank() }.map { (name, _) -> name }

// Tasks that package or sign a release artifact with the release key. Matching
// the task graph (not the requested task names) means `assemble`/`build` are
// gated too, while bundleDebug, lintRelease or testReleaseUnitTest are not.
// The suffixes are anchored so that unrelated tasks which sign nothing, such as
// packageReleaseResources, do not match; a flavor name may sit before Release.
val releaseSigningTaskPattern = Regex(
    "^(validateSigning|package)\\w*Release$|^sign\\w*ReleaseBundle$|^package\\w*ReleaseUniversalApk$",
)

gradle.taskGraph.whenReady {
    val signsRelease = allTasks.any { task ->
        task.project == project && releaseSigningTaskPattern.matches(task.name)
    }
    if (!signsRelease) {
        return@whenReady
    }
    if (missingSigningValues.isNotEmpty()) {
        throw GradleException(
            "Release signing config missing: ${missingSigningValues.joinToString(", ")}. " +
                "Provide them in android/key.properties or through the environment variables " +
                "MOTOCAM_KEYSTORE_FILE, MOTOCAM_KEYSTORE_PASSWORD, MOTOCAM_KEY_ALIAS and " +
                "MOTOCAM_KEY_PASSWORD.",
        )
    }
    val releaseStoreFile = file(releaseStoreFilePath!!)
    if (!releaseStoreFile.isFile) {
        throw GradleException(
            "Release keystore not found at ${releaseStoreFile.absolutePath}. " +
                "A relative storeFile/MOTOCAM_KEYSTORE_FILE path is resolved against android/app/.",
        )
    }
}

android {
    namespace = "com.example.motocam"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    // BuildConfig.DEBUG gates the debug-only roll stall diagnostics
    // (DiagHeartbeats.kt).
    buildFeatures {
        buildConfig = true
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
