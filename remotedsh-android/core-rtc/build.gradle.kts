plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dsh.mobile.rtc"
    compileSdk = 34
    defaultConfig { minSdk = 26 }
}
dependencies {
    implementation(project(":core-contract"))
    implementation(project(":core-proxy"))
    implementation("io.getstream:stream-webrtc-android:1.1.3") // G1 门禁验证后决定是否替换为 org.webrtc:google-webrtc
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    testImplementation("junit:junit:4.13.2")
}
