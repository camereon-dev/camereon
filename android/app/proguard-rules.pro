# ONNX Runtime uses JNI. Preserve class and method names in release builds.
-keep class ai.onnxruntime.** { *; }

# ML Kit finds its component registrars through manifest meta-data and creates
# them by reflection with the default constructor. The consumer rule only keeps
# the classes, and R8 full mode then drops the constructor, so
# TextRecognition.getClient() fails with a NullPointerException in release
# builds (address detection never succeeds). Keep the constructors too.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    <init>();
}
