plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dsh.mobile.pairing"
    compileSdk = 34
    defaultConfig { minSdk = 26 }
}
dependencies {
    implementation(project(":core-contract"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    testImplementation("junit:junit:4.13.2")
}
