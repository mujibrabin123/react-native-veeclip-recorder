# android/proguard-rules.pro

# Keep react-native-webrtc classes and their members so reflection works in Release mode
-keep class com.oney.WebRTCModule.** { *; }
-keepclassmembers class com.oney.WebRTCModule.WebRTCModule {
    java.util.Map localTracks;
    java.util.Map mPeerConnectionObservers;
}