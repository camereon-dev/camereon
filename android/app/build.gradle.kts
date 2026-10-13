plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val betaKeystorePath = System.getenv("CAMEREON_BETA_KEYSTORE")
val betaPassword = System.getenv("CAMEREON_BETA_PASSWORD")
val isBetaBuild = !betaKeystorePath.isNullOrBlank()

if (isBetaBuild) {
    require(!betaPassword.isNullOrBlank()) { "Beta signing password is required" }
    require(file(betaKeystorePath!!).isFile) { "Beta signing keystore is missing" }
}

android {
    namespace = "dev.camereon.camereon.demo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Keep the demo separate from a future production app.
        applicationId = "dev.camereon.camereon.demo"
        manifestPlaceholders["appName"] = if (isBetaBuild) "camereon beta" else "camereon demo"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (isBetaBuild) {
            create("beta") {
                storeFile = file(betaKeystorePath!!)
                storePassword = betaPassword
                keyAlias = "camereon-beta"
                keyPassword = betaPassword
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (isBetaBuild) "beta" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
