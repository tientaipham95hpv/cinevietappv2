package live.cineviet.cineviet_app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val brightnessChannel = "live.cineviet/brightness"
    private val oauthChannel = "live.cineviet/oauth"
    private val installerChannel = "live.cineviet/installer"
    private val externalPlayerChannel = "live.cineviet/external_player"
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, externalPlayerChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> {
                    val url = call.argument<String>("url")
                    val title = call.argument<String>("title") ?: "CineViet"
                    val packageName = call.argument<String>("packageName")
                    if (url.isNullOrBlank()) {
                        result.error("missing_url", "Playback URL is required", null)
                    } else {
                        try {
                            openExternalPlayer(url, title, packageName)
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("player_unavailable", error.localizedMessage ?: "Cannot open external player", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("missing_path", "APK path is required", null)
                    } else {
                        try {
                            validateApkForUpdate(path)
                            installApk(path)
                            result.success(null)
                        } catch (e: IllegalStateException) {
                            result.error(e.message ?: "invalid_apk", updateErrorMessage(e.message), null)
                        } catch (e: Exception) {
                            result.error("install_failed", e.localizedMessage ?: "Cannot open installer", null)
                        }
                    }
                }
                "inspectApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("missing_path", "APK path is required", null)
                    } else {
                        try {
                            result.success(inspectApk(path))
                        } catch (e: IllegalStateException) {
                            result.error(e.message ?: "invalid_apk", updateErrorMessage(e.message), null)
                        } catch (e: Exception) {
                            result.error("inspect_failed", e.localizedMessage ?: "Cannot inspect APK", null)
                        }
                    }
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

    private fun openExternalPlayer(url: String, title: String, preferredPackage: String?) {
        val playbackIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse(url), "video/*")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_TITLE, title)
            putExtra("title", title)
            if (!preferredPackage.isNullOrBlank()) setPackage(preferredPackage)
        }
        if (playbackIntent.resolveActivity(packageManager) == null) {
            throw IllegalStateException("Không tìm thấy trình phát đã chọn")
        }
        if (preferredPackage.isNullOrBlank()) {
            startActivity(Intent.createChooser(playbackIntent, "Mở bằng trình phát"))
        } else {
            startActivity(playbackIntent)
        }
    }

    private fun captureOAuthCallback(intent: Intent?) {
        val uri = intent?.data?.toString() ?: return
        if (uri.startsWith("cineviet://auth/callback")) {
            latestOAuthCallback = uri
        }
    }

    private fun installApk(path: String) {
        val apk = File(path)
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
        }
        startActivity(intent)
    }

    private fun inspectApk(path: String): Map<String, Any?> {
        val archiveInfo = archivePackageInfo(path)
        val installedInfo = installedPackageInfo()
        val archiveSignatures = apkSignatures(archiveInfo)
        val installedSignatures = apkSignatures(installedInfo)
        val samePackage = archiveInfo.packageName == packageName
        val sameSignature = archiveSignatures.isNotEmpty() &&
            installedSignatures.isNotEmpty() &&
            archiveSignatures == installedSignatures
        val versionCode = packageVersionCode(archiveInfo)

        return mapOf(
            "packageName" to archiveInfo.packageName,
            "currentPackageName" to packageName,
            "versionName" to archiveInfo.versionName,
            "versionCode" to versionCode,
            "samePackage" to samePackage,
            "sameSignature" to sameSignature,
            "canUpdateCurrentApp" to (samePackage && sameSignature),
        )
    }

    private fun validateApkForUpdate(path: String) {
        val info = inspectApk(path)
        if (info["samePackage"] != true) {
            throw IllegalStateException("package_mismatch")
        }
        if (info["sameSignature"] != true) {
            throw IllegalStateException("signature_mismatch")
        }
    }

    private fun archivePackageInfo(path: String): PackageInfo {
        val apk = File(path)
        if (!apk.exists() || apk.length() <= 0L) {
            throw IllegalStateException("empty_apk")
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        @Suppress("DEPRECATION")
        val info = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw IllegalStateException("invalid_apk")
        return info
    }

    private fun installedPackageInfo(): PackageInfo {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong()))
        } else {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                @Suppress("DEPRECATION")
                PackageManager.GET_SIGNATURES
            }
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, flags)
        }
    }

    private fun apkSignatures(info: PackageInfo): Set<String> {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = info.signingInfo ?: return emptySet()
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            info.signatures ?: emptyArray()
        }
        return signatures.map { it.toCharsString() }.toSet()
    }

    private fun packageVersionCode(info: PackageInfo): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
    }

    private fun updateErrorMessage(code: String?): String {
        return when (code) {
            "empty_apk" -> "File cập nhật tải về bị rỗng."
            "invalid_apk" -> "File cập nhật không phải APK hợp lệ."
            "package_mismatch" -> "APK tải về không cùng gói ứng dụng với CineViet đang cài."
            "signature_mismatch" -> "APK tải về khác chữ ký với CineViet đang cài. Cần build lại bằng đúng release keystore."
            else -> "Không thể kiểm tra file cập nhật."
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
