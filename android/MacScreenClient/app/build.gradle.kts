plugins {
    id("com.android.application")
    kotlin("android")
}

android {
    namespace = "com.macscreen.client"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.macscreen.client"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    packaging {
        resources.excludes += setOf("META-INF/AL2.0", "META-INF/LGPL2.1", "META-INF/DEPENDENCIES")
    }
}

// core 引入的 org.json:json 仅用于 JVM 单测；运行时使用 Android 平台内置的 org.json
configurations.all {
    exclude(group = "org.json", module = "json")
}

dependencies {
    implementation(project(":core"))

    // 平台标准扫码：CameraX + ML Kit Barcode
    val camerax = "1.3.4"
    implementation("androidx.camera:camera-core:$camerax")
    implementation("androidx.camera:camera-camera2:$camerax")
    implementation("androidx.camera:camera-lifecycle:$camerax")
    implementation("androidx.camera:camera-view:$camerax")
    implementation("com.google.mlkit:barcode-scanning:17.2.0")
}
