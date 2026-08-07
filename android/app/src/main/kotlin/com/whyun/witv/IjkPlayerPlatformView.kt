package com.whyun.witv

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.media.AudioManager
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import tv.danmaku.ijk.media.player.IjkMediaPlayer

class IjkPlayerPlatformView(
    context: Context,
    private val viewId: Int,
) : PlatformView, MethodChannel.MethodCallHandler {

    private val container = FrameLayout(context)
    private val textureView = TextureView(context)
    private val snapView = ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_XY
        visibility = View.GONE
    }

    private var mediaPlayer: IjkMediaPlayer? = null
    private var methodChannel: MethodChannel? = null
    private var currentSurface: Surface? = null
    private var isSurfaceAvailable = false

    init {
        IjkMediaPlayer.loadLibrariesOnce(null)

        container.addView(textureView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))
        container.addView(snapView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ))

        textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                currentSurface = Surface(surface)
                isSurfaceAvailable = true
                mediaPlayer?.setSurface(currentSurface)
            }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {}
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
                isSurfaceAvailable = false
                mediaPlayer?.setSurface(null)
                currentSurface?.release()
                currentSurface = null
                return true
            }
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
        }
    }

    fun setupChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        methodChannel = MethodChannel(messenger, "ijkplayer_view_$viewId")
        methodChannel?.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setUrl" -> {
                val url = call.argument<String>("url")
                if (url != null) {
                    setUrl(url)
                    result.success(null)
                } else {
                    result.error("INVALID_URL", "URL is null", null)
                }
            }
            "play" -> {
                mediaPlayer?.start()
                result.success(null)
            }
            "pause" -> {
                mediaPlayer?.pause()
                result.success(null)
            }
            "stop" -> {
                mediaPlayer?.stop()
                result.success(null)
            }
            "release" -> {
                releasePlayer()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun setUrl(url: String) {
        // 截图覆盖防黑底
        if (isSurfaceAvailable && textureView.isAvailable) {
            try {
                val bitmap: Bitmap? = textureView.bitmap
                if (bitmap != null) {
                    snapView.setImageBitmap(bitmap)
                    snapView.visibility = View.VISIBLE
                }
            } catch (_: Exception) {}
        }

        // 优先复用播放器
        val player = mediaPlayer
        if (player != null) {
            try {
                player.stop()
                player.reset()
                configurePlayer(player)
                player.setSurface(currentSurface)
                player.dataSource = url
                player.prepareAsync()
                return
            } catch (_: Exception) {
                releasePlayer()
            }
        }

        // 新建
        val newPlayer = IjkMediaPlayer()
        mediaPlayer = newPlayer
        configurePlayer(newPlayer)
        currentSurface?.let { newPlayer.setSurface(it) }

        try {
            newPlayer.dataSource = url
            newPlayer.prepareAsync()
        } catch (e: Exception) {
            e.printStackTrace()
            methodChannel?.invokeMethod("onError", mapOf("what" to -1, "extra" to -1))
        }
    }

    private fun configurePlayer(player: IjkMediaPlayer) {
        // ===== 音频输出（AudioTrack 兼容性最好）=====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "opensles", 0L)
        player.setAudioStreamType(AudioManager.STREAM_MUSIC)
        player.setScreenOnWhilePlaying(true)

        // ===== 硬解（视频）音频软解（兼容所有格式）=====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-videos", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-avc", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-hevc", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "mediacodec-all-audio", 0L)

        // ===== 核心：探测参数足够大，确保识别所有音频格式 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "probesize", (512 * 1024).toLong())          // 512KB
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzeduration", (3 * 1000 * 1000).toLong()) // 3秒
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "analyzemaxduration", (8 * 1000 * 1000).toLong()) // 8秒上限

        // TS / m3u8 专用
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "fflags", "fastseek+flush_packets")
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "flush_packets", 1L)

        // 网络优化
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "http-detect-range-support", 0L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "dns_cache_clear", 0L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "dns_cache_timeout", -1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "protocol_whitelist", "file,http,https,tcp,tls,crypto")
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "rtsp_transport", "tcp")

        // ===== 缓冲策略 =====
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "packet-buffering", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "max-buffer-size", (1024 * 1024).toLong())
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "min-frames", 3L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "start-on-prepared", 1L)
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_PLAYER, "framedrop", 5L)

        // 超时与重连
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "timeout", (10 * 1000 * 1000).toLong())
        player.setOption(IjkMediaPlayer.OPT_CATEGORY_FORMAT, "reconnect", 1L)

        // ===== 监听器 =====
        player.setOnPreparedListener { it.start() }
        player.setOnInfoListener { _, what, extra ->
            if (what == 3) { // 首帧渲染
                snapView.post {
                    snapView.visibility = View.GONE
                    snapView.setImageBitmap(null)
                }
            }
            methodChannel?.invokeMethod("onInfo", mapOf("what" to what, "extra" to extra))
            true
        }
        player.setOnErrorListener { _, what, extra ->
            snapView.post {
                snapView.visibility = View.GONE
                snapView.setImageBitmap(null)
            }
            methodChannel?.invokeMethod("onError", mapOf("what" to what, "extra" to extra))
            true
        }
    }

    fun releasePlayer() {
        try {
            mediaPlayer?.stop()
            mediaPlayer?.release()
        } catch (e: Exception) {
            e.printStackTrace()
        }
        mediaPlayer = null
        snapView.post {
            snapView.visibility = View.GONE
            snapView.setImageBitmap(null)
        }
    }

    override fun getView(): View = container

    override fun dispose() {
        methodChannel?.setMethodCallHandler(null)
        releasePlayer()
    }
}
