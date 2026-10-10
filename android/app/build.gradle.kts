import java.net.URI
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Phase 17E — release signing and release server address.
//
// Signing comes ONLY from android/key.properties (git-ignored) or environment
// variables; the keystore must live outside this repository. A release build
// with incomplete signing, or without an HTTPS POS_BASE_URL, stops before
// compiling. It never falls back to the debug key. Debug builds are unchanged.
// Values are never printed: errors name the missing setting only.
// See docs/ANDROID_RELEASE_BUILD.md.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

fun signingSetting(property: String, environment: String): String? =
    (keyProperties.getProperty(property) ?: System.getenv(environment))?.trim()?.takeIf { it.isNotEmpty() }

val releaseStoreFile = signingSetting("storeFile", "THRIVEWOO_ANDROID_KEYSTORE")
val releaseStorePassword = signingSetting("storePassword", "THRIVEWOO_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = signingSetting("keyAlias", "THRIVEWOO_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingSetting("keyPassword", "THRIVEWOO_ANDROID_KEY_PASSWORD")
val repositoryRoot = rootProject.projectDir.parentFile.canonicalFile

val releaseSigningProblems: List<String> = buildList {
    if (releaseStoreFile == null) {
        add("storeFile (or THRIVEWOO_ANDROID_KEYSTORE) is not set")
    } else {
        val store = rootProject.file(releaseStoreFile).canonicalFile
        if (!store.isFile) add("the keystore file named by storeFile does not exist")
        if (store.path.startsWith(repositoryRoot.path + File.separator)) {
            add("the keystore is inside the repository; keep it outside the project folder")
        }
    }
    if (releaseStorePassword == null) add("storePassword (or THRIVEWOO_ANDROID_KEYSTORE_PASSWORD) is not set")
    if (releaseKeyAlias == null) add("keyAlias (or THRIVEWOO_ANDROID_KEY_ALIAS) is not set")
    if (releaseKeyPassword == null) add("keyPassword (or THRIVEWOO_ANDROID_KEY_PASSWORD) is not set")
}

// The --dart-define values Flutter passes to Gradle (comma-separated base64).
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.mapNotNull { encoded ->
            runCatching { String(Base64.getDecoder().decode(encoded)) }.getOrNull()
        }
        ?.mapNotNull { pair ->
            val i = pair.indexOf('=')
            if (i > 0) pair.substring(0, i) to pair.substring(i + 1) else null
        }
        ?.toMap()
        ?: emptyMap()

// Same rule as AppConfig.releaseBaseUrlProblem (lib/core/config/app_config.dart).
fun releaseBaseUrlProblem(value: String?): String? {
    val url = value?.trim().orEmpty()
    if (url.isEmpty()) return "POS_BASE_URL is not set (pass --dart-define=POS_BASE_URL=https://<server>)"
    val uri = runCatching { URI(url) }.getOrNull()
    val host = uri?.host?.lowercase()
    if (uri == null || uri.scheme == null || host.isNullOrEmpty()) return "POS_BASE_URL is not a valid URL"
    if (uri.scheme.lowercase() != "https") return "POS_BASE_URL must use https://"
    if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) {
        return "POS_BASE_URL must not contain credentials, a query or a fragment"
    }
    if (host in setOf("localhost", "10.0.2.2", "0.0.0.0", "[::1]", "::1") || host.startsWith("127.")) {
        return "POS_BASE_URL is a development address"
    }
    return null
}

android {
    namespace = "com.thrivewoo.buskit_pos"
    // Phase 17E.1: permission_handler_android 14.x requires compiling against
    // API 37 (its changelog: set the app's compileSdk to 37). Flutter's
    // default is 36. Only the compile SDK changes: targetSdk and minSdk stay
    // on Flutter's defaults, so runtime behaviour is unchanged.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.thrivewoo.buskit_pos"
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
        create("release") {
            if (releaseSigningProblems.isEmpty()) {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Phase 17E: only the release key; never the debug key. When the
            // release key is not configured the build is stopped below.
            signingConfig = if (releaseSigningProblems.isEmpty()) signingConfigs.getByName("release") else null
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

// Phase 17E: stop any release build (APK or App Bundle) before it compiles
// when signing is incomplete or the server address is not HTTPS.
tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    doFirst {
        val problems = releaseSigningProblems.map { "release signing: $it" } +
            listOfNotNull(releaseBaseUrlProblem(dartDefines["POS_BASE_URL"])?.let { "server address: $it" })
        if (problems.isNotEmpty()) {
            throw GradleException(
                "ThriveWoo POS release build refused:\n" +
                    problems.joinToString("\n") { "  - $it" } +
                    "\nSee docs/ANDROID_RELEASE_BUILD.md. Debug builds are not affected."
            )
        }
    }
}
