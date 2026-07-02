package live.cineviet.cineviet_app

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val brightnessChannel = "live.cineviet/brightness"
    private val oauthChannel = "live.cineviet/oauth"
    private var latestOAuthCallback: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
        captureOAuthCallback(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureOAuthCallback(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, oauthChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "getLatestCallback" -> {
                    result.success(latestOAuthCallback)
                    latestOAuthCallback = null
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, brightnessChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> result.success(currentBrightness())
                "set" -> {
                    val value = (call.argument<Double>("value") ?: 0.5).coerceIn(0.0, 1.0)
                    applyBrightness(value)
                    result.success(currentAppliedBrightness())
                }
                "canWriteSettings" -> result.success(canWriteSystemSettings())
                "requestWriteSettings" -> {
                    requestWriteSettings()
                    result.success(canWriteSystemSettings())
                }
                "reset" -> {
                    resetBrightness()
                    result.success(currentBrightness())
                }
                "setKeepScreenOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    setKeepScreenOn(enabled)
                    result.success(null)
                }
                "getVolume" -> result.success(currentMusicVolume())
                "setVolume" -> {
                    val value = (call.argument<Double>("value") ?: 1.0).coerceIn(0.0, 1.0)
                    val showUi = call.argument<Boolean>("showUi") ?: false
                    applyMusicVolume(value, showUi)
                    result.success(currentMusicVolume())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun captureOAuthCallback(intent: Intent?) {
        val uri = intent?.data?.toString() ?: return
        if (uri.startsWith("cineviet://auth/callback")) {
            latestOAuthCallback = uri
        }
    }

    private fun currentBrightness(): Double {
        return try {
            Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS).toDouble()
                .div(255.0)
                .coerceIn(0.0, 1.0)
        } catch (_: Exception) {
            1.0
        }
    }

    private fun currentAppliedBrightness(): Double {
        val applied = window.attributes.screenBrightness
        return if (applied >= 0f) applied.toDouble().coerceIn(0.0, 1.0) else currentBrightness()
    }

    private fun applyBrightness(value: Double) {
        if (canWriteSystemSettings()) {
            try {
                Settings.System.putInt(
                    contentResolver,
                    Settings.System.SCREEN_BRIGHTNESS,
                    (value.coerceIn(0.0, 1.0) * 255.0).roundToInt().coerceIn(0, 255),
                )
            } catch (_: Exception) {
                // Keep the per-window fallback below.
            }
        }
        val params = window.attributes
        params.screenBrightness = value.toFloat().coerceIn(0.01f, 1f)
        window.attributes = params
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun canWriteSystemSettings(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.System.canWrite(this)
    }

    private fun requestWriteSettings() {
        if (canWriteSystemSettings() || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            val intent = Intent(
                Settings.ACTION_MANAGE_WRITE_SETTINGS,
                Uri.parse("package:$packageName"),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    private fun resetBrightness() {
        val params = window.attributes
        params.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
        window.attributes = params
    }

    private fun setKeepScreenOn(enabled: Boolean) {
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun currentMusicVolume(): Double {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val current = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
        return current.toDouble() / max.toDouble()
    }

    private fun applyMusicVolume(value: Double, showUi: Boolean) {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
        val target = Math.round((value * max).toFloat()).coerceIn(0, max)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && target > 0) {
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
        }
        val flags = if (showUi) {
            AudioManager.FLAG_SHOW_UI
        } else {
            AudioManager.FLAG_REMOVE_SOUND_AND_VIBRATE
        }
        audio.setStreamVolume(
            AudioManager.STREAM_MUSIC,
            target,
            flags,
        )
    }
}
