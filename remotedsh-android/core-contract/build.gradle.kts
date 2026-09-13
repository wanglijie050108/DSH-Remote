plugins { id("com.android.library"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "dsh.mobile.contract"
    compileSdk = 34
    defaultConfig { minSdk = 26 }
}
dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
