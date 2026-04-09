package com.talkvee.reactnativeveecliprecorder

import android.util.Log
import android.view.View
import com.facebook.react.bridge.*
import com.facebook.react.module.annotations.ReactModule
import com.facebook.react.uimanager.UIManagerModule
import org.webrtc.VideoTrack

@ReactModule(name = VeeclipRecorderModule.NAME)
class VeeclipRecorderModule(reactContext: ReactApplicationContext) : ReactContextBaseJavaModule(reactContext) {
    
    private var compositor: VeeclipCompositor? = null

    companion object {
        const val NAME = "VeeclipRecorder"
    }

    override fun getName(): String = NAME

    @ReactMethod
    fun isSupported(promise: Promise) {
        promise.resolve(true)
    }

    @ReactMethod
    fun startRecording(localViewTag: Int, remoteViewTag: Int, options: ReadableMap, promise: Promise) {
        if (compositor != null) {
            promise.reject("ALREADY_RECORDING", "A recording session is already active.")
            return
        }

        val activity = reactApplicationContext.currentActivity
        if (activity == null) {
            promise.reject("ACTIVITY_ERROR", "Could not find current Android Activity.")
            return
        }

        // We MUST access UI components on the main Android UI thread
        activity.runOnUiThread {
            try {
                // 1. Get the layout from JS options (e.g., "vertical" or "horizontal")
                val layout = if (options.hasKey("layout")) options.getString("layout") ?: "vertical" else "vertical"

                // 2. Ask Android directly for the views using the React Tags
                var localView: View? = activity.findViewById(localViewTag)
                var remoteView: View? = activity.findViewById(remoteViewTag)

                // Fallback for older RN architectures or Fabric
                if (localView == null || remoteView == null) {
                    try {
                        val uiManager = reactApplicationContext.getNativeModule(UIManagerModule::class.java)
                        if (localView == null) localView = uiManager?.resolveView(localViewTag)
                        if (remoteView == null) remoteView = uiManager?.resolveView(remoteViewTag)
                    } catch (e: Exception) {
                        Log.w("VeeClip", "UIManager fallback ignored: ${e.message}")
                    }
                }

                if (localView == null || remoteView == null) {
                    promise.reject("VIEW_ERROR", "Could not find the RTCViews on the screen.")
                    return@runOnUiThread
                }

                // 3. Extract the tracks directly from the UI component!
                val localTrack = extractTrackFromView(localView)
                val remoteTrack = extractTrackFromView(remoteView)

                if (localTrack == null || remoteTrack == null) {
                    promise.reject("TRACK_ERROR", "Found the views, but no VideoTracks were attached.")
                    return@runOnUiThread
                }

                // 4. Start composing!
                val outputPath = "${reactApplicationContext.cacheDir.absolutePath}/veeclip.mp4"
                
                compositor = VeeclipCompositor(outputPath)
                
                // 🔥 THE FIX: Pass the layout here so the compositor draws the remote video correctly
                compositor?.start(localTrack, remoteTrack, layout)
                
                promise.resolve(null)

            } catch (e: Exception) {
                Log.e("VeeClip", "Start Recording Error", e)
                promise.reject("START_ERROR", e.message)
            }
        }
    }

    private fun extractTrackFromView(view: View): VideoTrack? {
        try {
            // The view is a com.oney.WebRTCModule.WebRTCView
            // We use reflection to grab the "videoTrack" variable right out of it!
            val trackField = view.javaClass.getDeclaredField("videoTrack")
            trackField.isAccessible = true
            val track = trackField.get(view) as? VideoTrack
            
            if (track != null) {
                Log.d("VeeClip", "✅ Successfully extracted track from screen UI!")
                return track
            }
        } catch (e: Exception) {
            Log.e("VeeClip", "Could not find videoTrack field in RTCView", e)
        }
        return null
    }

    @ReactMethod
    fun stopRecording(promise: Promise) {
        if (compositor == null) {
            promise.reject("NOT_RECORDING", "Recording is not currently active.")
            return
        }

        compositor?.stop { uri ->
            val result = Arguments.createMap()
            result.putString("videoUri", "file://$uri")
            result.putString("mimeType", "video/mp4")
            promise.resolve(result)
            compositor = null
        }
    }
}