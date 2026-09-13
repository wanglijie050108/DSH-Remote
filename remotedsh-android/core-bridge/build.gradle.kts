plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dsh.mobile.bridge"
    compileSdk = 34
    defaultConfig { minSdk = 26 }
}
dependencies {
    implementation(project(":core-contract"))
    implementation(project(":core-pairing"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    testImplementation("junit:junit:4.13.2")
}
