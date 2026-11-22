pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
        google()
    }
}
rootProject.name = "MacScreenClient"

// 检测到 Android SDK 才纳入 :app（否则 :core 纯 JVM 模块仍可单测）
val sdkHome = System.getenv("ANDROID_HOME") ?: (System.getProperty("user.home") + "/Library/Android/sdk")
if (System.getenv("ANDROID_HOME") != null || File(sdkHome).resolve("platforms").isDirectory) {
    include(":app")
    println("检测到 Android SDK，包含 :app 模块")
} else {
    println("未检测到 Android SDK，仅构建 :core 模块")
}
include(":core")
