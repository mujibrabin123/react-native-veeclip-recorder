package com.talkvee.reactnativeveecliprecorder

import android.annotation.SuppressLint
import android.graphics.Matrix
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import org.webrtc.*
import java.nio.ByteBuffer

class VeeclipCompositor(private val outputPath: String) {
    private var isRecording = false
    private var layout = "vertical"

    // Video Variables
    private var encoder: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var eglBase: EglBase? = null
    private var drawer: GlRectDrawer? = null
    private var frameDrawer: VideoFrameDrawer? = null

    // Audio Variables
    private var audioEncoder: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var audioThread: Thread? = null
    @Volatile private var isAudioRecording = false

    // Muxer Sync Variables
    private var muxer: MediaMuxer? = null
    private var muxerStarted = false
    private val muxerLock = Any()
    private var expectedTracks = 2
    private var addedTracks = 0
    private var videoTrackIndex = -1
    private var audioTrackIndex = -1

    private var WIDTH = 720
    private var HEIGHT = 1280
    private val FPS = 30
    
    // Counters for flawless MP4 Timestamps
    private var frameCount: Long = 0
    private var audioSamplesCount: Long = 0

    // Pending Buffers to catch the early Video Keyframe
    private data class PendingBuffer(val isVideo: Boolean, val info: MediaCodec.BufferInfo, val data: ByteArray)
    private val pendingBuffers = mutableListOf<PendingBuffer>()

    @Volatile private var lastLocalFrame: VideoFrame? = null
    @Volatile private var lastRemoteFrame: VideoFrame? = null

    private var localTrack: VideoTrack? = null
    private var remoteTrack: VideoTrack? = null

    private val localLock = Any()
    private val remoteLock = Any()

    private val localSink = VideoSink { frame ->
        val i420Buffer = frame.buffer.toI420() ?: return@VideoSink
        val cpuFrame = VideoFrame(i420Buffer, frame.rotation, frame.timestampNs)
        synchronized(localLock) {
            val old = lastLocalFrame
            lastLocalFrame = cpuFrame
            old?.release()
        }
    }

    private val remoteSink = VideoSink { frame ->
        val i420Buffer = frame.buffer.toI420() ?: return@VideoSink
        val cpuFrame = VideoFrame(i420Buffer, frame.rotation, frame.timestampNs)
        synchronized(remoteLock) {
            val old = lastRemoteFrame
            lastRemoteFrame = cpuFrame
            old?.release()
        }
    }

    private var renderThread: HandlerThread? = null
    private var renderHandler: Handler? = null

    fun start(local: VideoTrack, remote: VideoTrack, layout: String = "vertical") {
        this.localTrack = local
        this.remoteTrack = remote
        this.layout = layout

        if (layout == "horizontal") {
            WIDTH = 1280
            HEIGHT = 720
        } else {
            WIDTH = 720
            HEIGHT = 1280
        }

        addedTracks = 0
        expectedTracks = 2
        muxerStarted = false
        frameCount = 0
        audioSamplesCount = 0
        pendingBuffers.clear()

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, WIDTH, HEIGHT)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        format.setInteger(MediaFormat.KEY_BIT_RATE, 3500000)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, FPS)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)

        encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        encoder?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = encoder?.createInputSurface()
        encoder?.start()

        muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

        localTrack?.addSink(localSink)
        remoteTrack?.addSink(remoteSink)

        isRecording = true

        startAudioRecording()

        renderThread = HandlerThread("VeeclipRenderThread").apply { start() }
        renderHandler = Handler(renderThread!!.looper)
        
        renderHandler?.post(object : Runnable {
            var isGlInitialized = false

            override fun run() {
                if (!isRecording) return
                
                if (!isGlInitialized) {
                    try {
                        eglBase = EglBase.create(null, EglBase.CONFIG_RECORDABLE)
                        eglBase?.createSurface(inputSurface)
                        eglBase?.makeCurrent()
                        drawer = GlRectDrawer()
                        frameDrawer = VideoFrameDrawer()
                        isGlInitialized = true
                    } catch (e: Exception) {
                        return
                    }
                }

                if (lastLocalFrame != null || lastRemoteFrame != null) {
                    composeFrame()
                    drainVideoEncoder(false)
                }
                
                renderHandler?.postDelayed(this, (1000 / FPS).toLong())
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun startAudioRecording() {
        try {
            val sampleRate = 44100
            val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            
            // 🌟 THE PARTNER AUDIO FIX:
            // AVOID "VOICE_COMMUNICATION" as first choice because it uses hardware Echo Cancellation (AEC)
            // which actively deletes the partner's voice.
            // "CAMCORDER" and "MIC" grab the raw room audio, which captures the loudspeaker!
            val audioSources = intArrayOf(
                MediaRecorder.AudioSource.CAMCORDER,
                MediaRecorder.AudioSource.MIC,
                MediaRecorder.AudioSource.DEFAULT,
                MediaRecorder.AudioSource.VOICE_COMMUNICATION
            )

            for (source in audioSources) {
                try {
                    audioRecord = AudioRecord(source, sampleRate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, minBufferSize * 2)
                    if (audioRecord?.state == AudioRecord.STATE_INITIALIZED) break
                } catch (e: Exception) {}
            }

            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                Log.e("VeeClip", "Audio locked, falling back to silent video.")
                expectedTracks = 1
                return
            }

            val audioFormat = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, 1)
            audioFormat.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            audioFormat.setInteger(MediaFormat.KEY_BIT_RATE, 64000)
            audioFormat.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, minBufferSize * 2)

            audioEncoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            audioEncoder?.configure(audioFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            audioEncoder?.start()

            isAudioRecording = true
            audioRecord?.startRecording()

            audioThread = Thread {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
                
                val buffer = ByteArray(4096)
                while (isAudioRecording) {
                    var readResult = 0
                    if (audioRecord?.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                        readResult = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                    }
                    
                    // 🌟 WEB-FREEZE FIX: Match the fake audio to EXACT real-world time
                    if (readResult <= 0) {
                        buffer.fill(0)
                        readResult = buffer.size
                        // 4096 bytes / 2 (16-bit) = 2048 samples. 2048 / 44100Hz = 0.046 seconds
                        Thread.sleep(46) 
                    }

                    val sampleCount = readResult / 2
                    val ptsUs = audioSamplesCount * 1000000L / sampleRate.toLong()
                    audioSamplesCount += sampleCount
                    
                    encodeAudio(buffer, readResult, ptsUs)
                }
                audioEncoder?.let { drainAudioEncoder(it, true) }
            }
            audioThread?.start()

        } catch (e: Exception) {
            expectedTracks = 1
            Log.e("VeeClip", "Audio crash, falling back to silent video", e)
        }
    }

    private fun encodeAudio(data: ByteArray, length: Int, ptsUs: Long) {
        val enc = audioEncoder ?: return
        try {
            val inputBufferIndex = enc.dequeueInputBuffer(10000)
            if (inputBufferIndex >= 0) {
                val inputBuffer = enc.getInputBuffer(inputBufferIndex)
                inputBuffer?.clear()
                inputBuffer?.put(data, 0, length)
                enc.queueInputBuffer(inputBufferIndex, 0, length, ptsUs, 0)
            }
            drainAudioEncoder(enc, false)
        } catch (e: Exception) {}
    }

    private fun composeFrame() {
        GLES20.glClearColor(0.0f, 0.0f, 0.0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        if (layout == "horizontal") {
            drawFrameSafely(isLocal = true, x = 0, y = 0, w = WIDTH / 2, h = HEIGHT, mirror = true)
            drawFrameSafely(isLocal = false, x = WIDTH / 2, y = 0, w = WIDTH / 2, h = HEIGHT, mirror = false)
        } else {
            drawFrameSafely(isLocal = false, x = 0, y = HEIGHT / 2, w = WIDTH, h = HEIGHT / 2, mirror = false)
            drawFrameSafely(isLocal = true, x = 0, y = 0, w = WIDTH, h = HEIGHT / 2, mirror = true)
        }

        val ptsNs = frameCount * (1000000000L / FPS)
        eglBase?.swapBuffers(ptsNs)
        frameCount++
    }

    private fun drawFrameSafely(isLocal: Boolean, x: Int, y: Int, w: Int, h: Int, mirror: Boolean) {
        var frameToDraw: VideoFrame? = null

        if (isLocal) {
            synchronized(localLock) {
                lastLocalFrame?.retain()
                frameToDraw = lastLocalFrame
            }
        } else {
            synchronized(remoteLock) {
                lastRemoteFrame?.retain()
                frameToDraw = lastRemoteFrame
            }
        }

        frameToDraw?.let { frame ->
            val drawMatrix = calculateCropMatrix(frame, w, h, mirror)
            frameDrawer?.drawFrame(frame, drawer, drawMatrix, x, y, w, h)
            frame.release() 
        }
    }

    private fun calculateCropMatrix(frame: VideoFrame, destW: Int, destH: Int, mirror: Boolean): Matrix {
        val renderMatrix = Matrix()
        renderMatrix.preTranslate(0.5f, 0.5f)
        if (mirror) renderMatrix.preScale(-1f, 1f)

        val isPortrait = frame.rotation % 180 != 0
        val frameW = (if (isPortrait) frame.buffer.height else frame.buffer.width).toFloat()
        val frameH = (if (isPortrait) frame.buffer.width else frame.buffer.height).toFloat()

        val frameAspect = frameW / frameH
        val destAspect = destW.toFloat() / destH.toFloat()

        var scaleX = 1f
        var scaleY = 1f

        if (frameAspect > destAspect) {
            scaleX = destAspect / frameAspect
        } else {
            scaleY = frameAspect / destAspect
        }

        renderMatrix.preScale(scaleX, scaleY)
        renderMatrix.preTranslate(-0.5f, -0.5f)

        return renderMatrix
    }

    private fun writeEncodedData(isVideo: Boolean, encodedData: ByteBuffer, bufferInfo: MediaCodec.BufferInfo) {
        synchronized(muxerLock) {
            if (!muxerStarted) {
                val data = ByteArray(bufferInfo.size)
                encodedData.position(bufferInfo.offset)
                encodedData.limit(bufferInfo.offset + bufferInfo.size)
                encodedData.get(data)

                val infoCopy = MediaCodec.BufferInfo()
                infoCopy.set(0, bufferInfo.size, bufferInfo.presentationTimeUs, bufferInfo.flags)

                pendingBuffers.add(PendingBuffer(isVideo, infoCopy, data))
            } else {
                if (pendingBuffers.isNotEmpty()) {
                    pendingBuffers.sortBy { it.info.presentationTimeUs }
                    for (pb in pendingBuffers) {
                        val trackIdx = if (pb.isVideo) videoTrackIndex else audioTrackIndex
                        if (trackIdx >= 0) {
                            val byteBuf = ByteBuffer.wrap(pb.data)
                            try { muxer?.writeSampleData(trackIdx, byteBuf, pb.info) } catch (e: Exception) {}
                        }
                    }
                    pendingBuffers.clear()
                }

                val trackIdx = if (isVideo) videoTrackIndex else audioTrackIndex
                if (trackIdx >= 0) {
                    try { 
                        // 🌟 THE FIX: Strictly enforce boundaries before giving it to MediaMuxer
                        encodedData.position(bufferInfo.offset)
                        encodedData.limit(bufferInfo.offset + bufferInfo.size)
                        muxer?.writeSampleData(trackIdx, encodedData, bufferInfo) 
                    } catch (e: Exception) {
                        Log.e("VeeClip", "Failed to write sample data for web", e)
                    }
                }
            }
        }
    }

    private fun drainVideoEncoder(endOfStream: Boolean) {
        val enc = encoder ?: return
        if (endOfStream) { try { enc.signalEndOfInputStream() } catch (e: Exception) {} }

        val bufferInfo = MediaCodec.BufferInfo()
        while (true) {
            // 🌟 THE FIX: Use 0 timeout if actively recording so the WebRTC thread doesn't lag/stutter
            val timeoutUs = if (endOfStream) 10000L else 0L
            val status = enc.dequeueOutputBuffer(bufferInfo, timeoutUs)
            
            if (status == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!endOfStream) break
            } else if (status == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                synchronized(muxerLock) {
                    videoTrackIndex = muxer?.addTrack(enc.outputFormat) ?: -1
                    addedTracks++
                    if (addedTracks == expectedTracks && !muxerStarted) {
                        muxer?.start()
                        muxerStarted = true
                    }
                }
            } else if (status >= 0) {
                val encodedData = enc.getOutputBuffer(status)
                if (encodedData != null && bufferInfo.size != 0) {
                    
                    // 🌟 THE FIX: Strip out the Codec Config (SPS/PPS) buffer inline
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        bufferInfo.size = 0 
                    }

                    if (bufferInfo.size != 0) {
                        encodedData.position(bufferInfo.offset)
                        encodedData.limit(bufferInfo.offset + bufferInfo.size)
                        writeEncodedData(true, encodedData, bufferInfo)
                    }
                }
                enc.releaseOutputBuffer(status, false)
                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            }
        }
    }

    private fun drainAudioEncoder(enc: MediaCodec, endOfStream: Boolean) {
        if (endOfStream) {
            try {
                val inputBufferIndex = enc.dequeueInputBuffer(10000)
                if (inputBufferIndex >= 0) {
                    enc.queueInputBuffer(inputBufferIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                }
            } catch (e: Exception) {}
        }

        val bufferInfo = MediaCodec.BufferInfo()
        while (true) {
            val status = enc.dequeueOutputBuffer(bufferInfo, 10000)
            if (status == MediaCodec.INFO_TRY_AGAIN_LATER) {
                break
            } else if (status == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                synchronized(muxerLock) {
                    audioTrackIndex = muxer?.addTrack(enc.outputFormat) ?: -1
                    addedTracks++
                    if (addedTracks == expectedTracks && !muxerStarted) {
                        muxer?.start()
                        muxerStarted = true
                    }
                }
            } else if (status >= 0) {
                val encodedData = enc.getOutputBuffer(status)
                if (encodedData != null && bufferInfo.size != 0) {
                    
                    // 🌟 THE FIX: Strip out the Codec Config inline
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        bufferInfo.size = 0 
                    }

                    if (bufferInfo.size != 0) {
                        encodedData.position(bufferInfo.offset)
                        encodedData.limit(bufferInfo.offset + bufferInfo.size)
                        writeEncodedData(false, encodedData, bufferInfo)
                    }
                }
                enc.releaseOutputBuffer(status, false)
                if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break
            }
        }
    }

    fun stop(onFinished: (String) -> Unit) {
        if (!isRecording) return
        isRecording = false
        isAudioRecording = false
        
        // 🌟 WEBRTC DISCONNECT FIX: Instantly detach the WebRTC tracks so the network thread never blocks
        try {
            localTrack?.removeSink(localSink)
            remoteTrack?.removeSink(remoteSink)
        } catch (e: Exception) {}
        
        // 🌟 WEBRTC DISCONNECT FIX: Do all heavy teardown on a completely separate background thread
        Thread {
            try { audioThread?.join(1000) } catch (e: Exception) {}

            renderHandler?.post {
                drainVideoEncoder(true)
                
                try { audioEncoder?.stop(); audioEncoder?.release() } catch(e: Exception) {}
                try { audioRecord?.stop(); audioRecord?.release() } catch(e: Exception) {}

                try {
                    encoder?.stop()
                    encoder?.release()
                    if (muxerStarted) muxer?.stop()
                    muxer?.release()
                } catch (e: Exception) {}

                synchronized(localLock) {
                    lastLocalFrame?.release()
                    lastLocalFrame = null
                }
                synchronized(remoteLock) {
                    lastRemoteFrame?.release()
                    lastRemoteFrame = null
                }

                drawer?.release()
                frameDrawer?.release()
                eglBase?.release()
                renderThread?.quitSafely()
                
                onFinished(outputPath)
            }
        }.start()
    }
}