# Keep MediaPipe / LiteRT-LM classes used by flutter_gemma
-keep class com.google.mediapipe.** { *; }
-keep class com.google.mediapipe.proto.** { *; }
-dontwarn com.google.mediapipe.**

# Keep LiteRT / TFLite classes
-keep class com.google.flatbuffers.** { *; }
-dontwarn com.google.flatbuffers.**

# Keep flutter_gemma JNI interface
-keep class dev.fluttercommunity.fluttergemma.** { *; }
