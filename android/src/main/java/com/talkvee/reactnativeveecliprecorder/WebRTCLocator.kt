package com.talkvee.reactnativeveecliprecorder

import android.util.Log
import com.facebook.react.bridge.ReactApplicationContext
import org.webrtc.PeerConnection
import org.webrtc.VideoTrack

object WebRTCLocator {

    fun findTrack(context: ReactApplicationContext, trackId: String, isLocal: Boolean): VideoTrack? {
        try {
            val webrtcClass = Class.forName("com.oney.WebRTCModule.WebRTCModule")
            val webrtcModule = context.getNativeModule(webrtcClass as Class<out com.facebook.react.bridge.NativeModule>) ?: return null

            // 🌟 1. YASSER'S TRICK: Try the hidden module.getTrack(-1, trackId)
            try {
                // He passed -1 (an Integer) and the trackId (a String)
                val getTrackMethod = webrtcClass.getMethod("getTrack", Int::class.javaPrimitiveType, String::class.java)
                val track = getTrackMethod.invoke(webrtcModule, -1, trackId)
                
                if (track is VideoTrack) {
                    Log.d("VeeClip", "✅ FOUND TRACK via Yasser's getTrack method: $trackId")
                    return track
                }
            } catch (e: Exception) {
                Log.d("VeeClip", "⚠️ Yasser's getTrack(-1, id) method not found or failed.")
            }

            // 🌟 2. FALLBACK: Try getTrackForId(String) (Used in other RN-WebRTC versions)
            try {
                val getTrackForIdMethod = webrtcClass.getMethod("getTrackForId", String::class.java)
                val track = getTrackForIdMethod.invoke(webrtcModule, trackId)
                
                if (track is VideoTrack) {
                    Log.d("VeeClip", "✅ FOUND TRACK via getTrackForId method: $trackId")
                    return track
                }
            } catch (e: Exception) {}

            // 🌟 3. BRUTE FORCE FALLBACK (Our previous code, kept just in case)
            var fallbackTrack: VideoTrack? = null
            for (field in webrtcClass.declaredFields) {
                if (Map::class.java.isAssignableFrom(field.type)) {
                    field.isAccessible = true
                    val map = field.get(webrtcModule) as? Map<*, *> ?: continue
                    for (value in map.values) {
                        if (value == null) continue
                        if (isLocal && value is VideoTrack) fallbackTrack = value
                        
                        try {
                            val getPcMethod = value.javaClass.getMethod("getPeerConnection")
                            val pc = getPcMethod.invoke(value) as? PeerConnection
                            pc?.receivers?.forEach { receiver ->
                                val receiverTrack = receiver.track()
                                if (!isLocal && receiverTrack is VideoTrack) fallbackTrack = receiverTrack
                            }
                        } catch (e: Exception) {}
                    }
                }
            }
            if (fallbackTrack != null) return fallbackTrack

        } catch (e: Exception) {
            Log.e("VeeClip", "❌ CRASH during track search", e)
        }
        return null
    }
}