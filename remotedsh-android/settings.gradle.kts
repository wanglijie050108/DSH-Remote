// remotedsh-android —— Gradle 骨架（03 §3；本仓库在无 Android SDK 环境下只交付源码，
// 编译验证在 Android Studio / CI 中完成）
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "remotedsh-android"
include(":core-contract", ":core-rtc", ":core-proxy", ":core-pairing", ":core-bridge", ":app")
