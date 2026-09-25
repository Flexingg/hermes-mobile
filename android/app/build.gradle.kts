import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing.
//
// Every published Mercury APK used to be signed with the Android *debug* key —
// the Flutter template's TODO was still in place — whose private half is public
// and identical on every dev machine. Anyone could build a trojaned update that
// Android installs over the real app, inheriting its vault and bridge token.
//
// The real key lives outside the repo (see README > Release signing) and is
// wired in through the gitignored android/key.properties:
//   storeFile=/home/hermes/.hermes/secrets/mercury-release.jks
//   storePassword=… / keyAlias=mercury / keyPassword=…
//
// Without that file the release build still works (debug key + a warning), so a
// fresh clone can `flutter run --release`; CI asserts the real DN is present.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.randalls.hermes_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (core library desugaring).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.randallengineering.hermes"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // firebase_core / firebase_messaging require minSdk 23.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // Without this AGP emits a v2-only APK (v1/v3 default off for
                // minSdk 24), and the CI gate that asserts the signing schemes
                // would fail on the very artifact it is meant to bless. v2+v3 is
                // the modern pair: v3 adds key-rotation support, so a future
                // keystore change can still install in place. v1 (legacy JAR
                // signing) is unnecessary — minSdk is 24.
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKey) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "Mercury: android/key.properties is missing — signing the " +
                        "release build with the DEBUG key. Do not publish this APK."
                )
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
