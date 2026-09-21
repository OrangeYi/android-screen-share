plugins {
    id("com.android.application")
}

android {
    namespace = "dev.androidscreenshare.companion"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.androidscreenshare.companion"
        minSdk = 26
        targetSdk = 28
        versionCode = 1
        versionName = "1.0"
    }
}
