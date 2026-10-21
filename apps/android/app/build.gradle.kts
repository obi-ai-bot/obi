import java.io.OutputStream
import javax.inject.Inject

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Push needs the owner's Firebase project (README.md, "Owner's steps"). Without its
// google-services.json the app builds and runs, and simply never registers for push.
if (file("google-services.json").exists()) apply(plugin = libs.plugins.google.services.get().pluginId)

android {
    namespace = "com.deskree.oby"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.deskree.oby"
        // Android 11: Keystore keys that need a fresh biometric for every signature
        // (setUserAuthenticationParameters), as the iPhone's Face ID key does.
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions { unitTests.isReturnDefaultValues = true }
    lint {
        abortOnError = true
        // The owner keeps current versions in libs.versions.toml; lint's "newer version" nags aren't errors.
        disable += setOf("GradleDependency", "NewerVersionAvailable", "AndroidGradlePluginVersion")
    }
}

// Sangam's character, the clean copy (no playground) the iPhone bundles too: character/package/build.sh,
// then oby.html and three.js into the app's assets under character/.
abstract class BundleCharacter : DefaultTask() {
    @get:InputDirectory @get:PathSensitive(PathSensitivity.RELATIVE) abstract val source: DirectoryProperty
    @get:OutputDirectory abstract val out: DirectoryProperty
    @get:Inject abstract val exec: ExecOperations

    @TaskAction fun bundle() {
        val root = source.get().asFile.parentFile
        val dest = out.get().asFile.resolve("character")
        exec.exec { commandLine("zsh", root.resolve("character/package/build.sh").path); standardOutput = OutputStream.nullOutputStream() }
        dest.deleteRecursively()
        root.resolve("dist/oby/oby.html").copyTo(dest.resolve("oby.html"))
        root.resolve("dist/oby/vendor/three.module.js").copyTo(dest.resolve("vendor/three.module.js"))
    }
}
val character = tasks.register<BundleCharacter>("bundleCharacter") {
    source.set(rootDir.resolve("../../character").canonicalFile)
}
androidComponents {
    onVariants { variant -> variant.sources.assets?.addGeneratedSourceDirectory(character, BundleCharacter::out) }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    debugImplementation(libs.compose.tooling)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.lifecycle.compose)
    implementation(libs.coroutines.android)
    implementation(libs.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.camera.camera2)
    implementation(libs.camera.lifecycle)
    implementation(libs.camera.view)
    implementation(libs.barcode)
    implementation(libs.biometric)
    implementation(libs.webkit)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}
