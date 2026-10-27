package dev.camereon.camereon.demo

import android.graphics.BitmapFactory
import java.util.UUID
import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.net.Uri
import android.provider.MediaStore
import android.provider.Settings
import android.os.StatFs
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var textRegionChannel: TextRegionChannel? = null
    private var objectRegionChannel: ObjectRegionChannel? = null
    private val photoPickerRequestCode = 732
    private var pendingPhotoPick: MethodChannel.Result? = null
    private val savePermissionRequestCode = 731
    private var saveInProgress = false
    private var pendingSaveBytes: ByteArray? = null
    private var pendingSaveResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textRegionChannel = TextRegionChannel(this, flutterEngine)
        objectRegionChannel = ObjectRegionChannel(this, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.camereon/photo_picker")
            .setMethodCallHandler { call, result ->
                if (call.method != "pick") result.notImplemented()
                else if (pendingPhotoPick != null) result.error("busy", "写真を選択中です", null)
                else {
                    pendingPhotoPick = result
                    try {
                        // System picker grants access to one explicitly chosen
                        // image. No library-wide storage permission is requested.
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "image/*"
                        }, photoPickerRequestCode)
                    } catch (_: Exception) {
                        pendingPhotoPick = null
                        result.error("unavailable", "写真を開けませんでした", null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.camereon/analysis_device")
            .setMethodCallHandler { call, result ->
                if (call.method == "availableStorageBytes") {
                    result.success(StatFs(filesDir.absolutePath).availableBytes)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.camereon/app_info")
            .setMethodCallHandler { call, result ->
                if (call.method == "version") {
                    @Suppress("DEPRECATION")
                    val info = packageManager.getPackageInfo(packageName, 0)
                    result.success(mapOf(
                        "versionName" to (info.versionName ?: ""),
                        "versionCode" to info.longVersionCode.toString(),
                    ))
                } else {
                    result.notImplemented()
                }
            }
        // カメラ権限を「今後表示しない」で拒否された場合に、アプリの設定画面へ案内する
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.camereon/app_settings")
            .setMethodCallHandler { call, result ->
                if (call.method == "open") {
                    val intent = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", packageName, null),
                    )
                    startActivity(intent)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.camereon/photo_saver")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null || !isJpeg(bytes) || saveInProgress) {
                    result.success("failed")
                    return@setMethodCallHandler
                }

                saveInProgress = true
                if (Build.VERSION.SDK_INT in Build.VERSION_CODES.M..Build.VERSION_CODES.P &&
                    checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                    PackageManager.PERMISSION_GRANTED
                ) {
                    pendingSaveBytes = bytes
                    pendingSaveResult = result
                    try {
                        requestPermissions(
                            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                            savePermissionRequestCode,
                        )
                    } catch (_: Exception) {
                        pendingSaveBytes = null
                        pendingSaveResult = null
                        finishSave(result, "failed")
                    }
                } else {
                    saveToGallery(bytes, result)
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != savePermissionRequestCode) return

        val result = pendingSaveResult ?: return
        val bytes = pendingSaveBytes
        pendingSaveResult = null
        pendingSaveBytes = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED && bytes != null) {
            saveToGallery(bytes, result)
        } else {
            finishSave(result, "permissionDenied")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != photoPickerRequestCode) return
        val result = pendingPhotoPick ?: return
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            pendingPhotoPick = null
            result.success(null)
            return
        }
        Thread {
            try {
                val bytes = requireNotNull(contentResolver.openInputStream(uri)).use { stream ->
                    // Bound transfer/memory use even for a provider with no size metadata.
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        check(output.size() + count <= 32 * 1024 * 1024)
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                runOnUiThread {
                    if (pendingPhotoPick === result) {
                        pendingPhotoPick = null
                        result.success(bytes)
                    }
                }
            } catch (_: Exception) {
                runOnUiThread {
                    if (pendingPhotoPick === result) {
                        pendingPhotoPick = null
                        result.error("failed", "写真を開けませんでした", null)
                    }
                }
            }
        }.start()
    }

    override fun onDestroy() {
        textRegionChannel?.close()
        textRegionChannel = null
        objectRegionChannel?.close()
        objectRegionChannel = null
        pendingPhotoPick?.success(null)
        pendingPhotoPick = null
        pendingSaveResult?.let { finishSave(it, "failed") }
        pendingSaveResult = null
        pendingSaveBytes = null
        super.onDestroy()
    }

    private fun isJpeg(bytes: ByteArray): Boolean {
        if (bytes.size < 4 || bytes[0] != 0xff.toByte() || bytes[1] != 0xd8.toByte() ||
            bytes[bytes.size - 2] != 0xff.toByte() || bytes.last() != 0xd9.toByte()
        ) return false
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
        return options.outWidth > 0 && options.outHeight > 0 && options.outMimeType == "image/jpeg"
    }

    private fun saveToGallery(bytes: ByteArray, result: MethodChannel.Result) {
        Thread {
            val status = try {
                insertImage(bytes)
                "saved"
            } catch (_: SecurityException) {
                "permissionDenied"
            } catch (_: Exception) {
                "failed"
            }
            runOnUiThread { finishSave(result, status) }
        }.start()
    }

    private fun insertImage(bytes: ByteArray) {
        val fileName = "camereon_${UUID.randomUUID()}.jpg"
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/camereon",
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            } else {
                val directory = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                    "camereon",
                )
                if (!directory.exists() && !directory.mkdirs()) {
                    throw IllegalStateException("Could not create gallery directory")
                }
                put(MediaStore.Images.Media.DATA, File(directory, fileName).absolutePath)
            }
        }

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val uri = contentResolver.insert(collection, values)
            ?: throw IllegalStateException("Could not create gallery entry")
        try {
            val output = contentResolver.openOutputStream(uri)
                ?: throw IllegalStateException("Could not open gallery entry")
            output.use { it.write(bytes) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val published = contentResolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) },
                    null,
                    null,
                )
                check(published == 1) { "Could not publish gallery entry" }
            }
        } catch (error: Exception) {
            try {
                contentResolver.delete(uri, null, null)
            } catch (_: Exception) {
                // Preserve the original failure even when cleanup is rejected.
            }
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                values.getAsString(MediaStore.Images.Media.DATA)?.let { File(it).delete() }
            }
            throw error
        }
    }

    private fun finishSave(result: MethodChannel.Result, status: String) {
        saveInProgress = false
        result.success(status)
    }
}
