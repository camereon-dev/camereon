plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val betaKeystorePath = System.getenv("CAMEREON_BETA_KEYSTORE")
val betaPassword = System.getenv("CAMEREON_BETA_PASSWORD")
val isBetaBuild = !betaKeystorePath.isNullOrBlank()
// Opt-in install for physical AI verification, without replacing a beta app.
val isAiPreview = System.getenv("CAMEREON_AI_PREVIEW") == "1"
require(!(isBetaBuild && isAiPreview)) { "AI preview cannot be published as a beta" }

if (isBetaBuild) {
    require(!betaPassword.isNullOrBlank()) { "Beta signing password is required" }
    require(file(betaKeystorePath!!).isFile) { "Beta signing keystore is missing" }
}

// Match every packaged JNI dependency to the Flutter engines in this build.
val flutterAbis = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
    "android-x86" to "x86",
)
val targetAbis = providers.gradleProperty("target-platform")
    .orElse("android-arm,android-arm64,android-x64").get().split(",")
    .map { flutterAbis.getValue(it) }
val splitPerAbi = providers.gradleProperty("split-per-abi").orElse("false").get().toBoolean()

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
        applicationId = if (isAiPreview) "dev.camereon.camereon.demo.ai_preview" else "dev.camereon.camereon.demo"
        manifestPlaceholders["appName"] = when {
            isAiPreview -> "camereon AI preview"
            isBetaBuild -> "camereon beta"
            else -> "camereon demo"
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // LiteRT-LM requires Android 11. AI is enabled only on ARM64 at runtime.
        minSdk = 30
        if (!splitPerAbi) {
            ndk {
                abiFilters.clear()
                abiFilters.addAll(targetAbis)
            }
        }
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
