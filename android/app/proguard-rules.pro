# Keep kotlinx.serialization generated companions; required for runtime decode.
-keep,includedescriptorclasses class app.roamsocket.**$$serializer { *; }
-keepclassmembers class app.roamsocket.** {
    *** Companion;
}
-keepclasseswithmembers class app.roamsocket.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# OkHttp / Okio commonly play badly with R8 without these.
-dontwarn org.codehaus.mojo.animal_sniffer.*
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-dontwarn org.bouncycastle.**

# Compose / Material 3 — R8 handles these well but the recomposer is reflective.
-keep class androidx.compose.runtime.** { *; }
