import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val islandSigningFile = rootProject.file("key.properties")
val islandSigning = Properties()
if (islandSigningFile.exists()) FileInputStream(islandSigningFile).use { islandSigning.load(it) }

android {
    namespace = "dev.islandtable.island_table"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "dev.islandtable.island_table"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (islandSigningFile.exists()) create("release") {
            keyAlias = islandSigning.getProperty("keyAlias")
            keyPassword = islandSigning.getProperty("keyPassword")
            storeFile = file(islandSigning.getProperty("storeFile"))
            storePassword = islandSigning.getProperty("storePassword")
        }
    }
    buildTypes {
        release {
            if (islandSigningFile.exists()) signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

// Release distribution must never silently fall back to a debug key or unsigned APK.
gradle.taskGraph.whenReady {
    if (!islandSigningFile.exists() && allTasks.any { it.name.contains("Release") }) {
        throw GradleException("Release signing requires ignored android/key.properties; see docs/deployment.md")
    }
}
