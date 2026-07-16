import java.io.FileInputStream
import java.util.Properties
import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import org.gradle.api.GradleException

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

fun signingValue(propertyName: String, envName: String): String? {
    return (keystoreProperties[propertyName] as String?)?.takeIf { it.isNotBlank() }
        ?: System.getenv(envName)?.takeIf { it.isNotBlank() }
}

val releaseStoreFile = signingValue("storeFile", "CM_KEYSTORE_PATH")
    ?: System.getenv("ANDROID_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }
val releaseStorePassword = signingValue("storePassword", "CM_KEYSTORE_PASSWORD")
    ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")?.takeIf { it.isNotBlank() }
val releaseKeyAlias = signingValue("keyAlias", "CM_KEY_ALIAS")
    ?: System.getenv("ANDROID_KEY_ALIAS")?.takeIf { it.isNotBlank() }
val releaseKeyPassword = signingValue("keyPassword", "CM_KEY_PASSWORD")
    ?: System.getenv("ANDROID_KEY_PASSWORD")?.takeIf { it.isNotBlank() }
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "live.cineviet.cineviet_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "live.cineviet.cineviet_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "device"
    productFlavors {
        create("mobile") {
            dimension = "device"
        }
        create("tv") {
            dimension = "device"
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (!hasReleaseSigning) {
                throw GradleException(
                    "Release signing is not configured. Set key.properties, CM_* signing variables, " +
                        "or ANDROID_* signing variables before building a release APK."
                )
            }
            signingConfig = signingConfigs.getByName("release")
        }
    }

    applicationVariants.all {
        outputs.all {
            (this as ApkVariantOutputImpl).versionCodeOverride = flutter.versionCode
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
