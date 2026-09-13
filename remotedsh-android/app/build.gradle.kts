plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dsh.mobile.app"
    compileSdk = 34
    defaultConfig {
        applicationId = "dsh.mobile.app"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }
    buildTypes {
        release {
            isMinifyEnabled = true        // 03 §6 交付物：release 关闭调试、签名、minify 开
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
        debug { }
        // WebContentsDebuggingEnabled 由 BuildConfig.DEBUG 控制（03 §3.4）
    }
}
dependencies {
    implementation(project(":core-contract"))
    implementation(project(":core-rtc"))
    implementation(project(":core-proxy"))
    implementation(project(":core-pairing"))
    implementation(project(":core-bridge"))
    implementation(platform("androidx.compose:compose-bom:2024.09.00"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.5")
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("io.getstream:stream-webrtc-android:1.1.3") // 待验证 AAR（03 §2；G1 门禁试一次）
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
