package com.follow.clash.common


import android.app.Application
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import java.io.File

object GlobalState : CoroutineScope by CoroutineScope(Dispatchers.Default) {

    const val NOTIFICATION_CHANNEL = "FlClash"

    const val NOTIFICATION_ID = 1

    val packageName: String
        get() = application.packageName

    val RECEIVE_BROADCASTS_PERMISSIONS: String
        get() = "${packageName}.permission.RECEIVE_BROADCASTS"


    private var _application: Application? = null

    val application: Application
        get() = _application!!


    fun log(text: String) {
        Log.d("[FlClash]", text)
    }

    fun logError(text: String) {
        Log.e("[FlClash]", text)
        runCatching {
            val file = serviceErrorLogFile
            val message = text.take(16_000)
            file.appendText("${System.currentTimeMillis()} $message\n")
            if (file.length() > 512_000) {
                file.writeText(file.readText().takeLast(256_000))
            }
        }
    }

    fun drainErrorLogs(): List<String> {
        return runCatching {
            val file = serviceErrorLogFile
            if (!file.exists()) {
                return@runCatching emptyList()
            }
            val lines = file.readLines().takeLast(200)
            file.delete()
            lines
        }.getOrDefault(emptyList())
    }

    private val serviceErrorLogFile: File
        get() = File(application.filesDir, "android-service-errors.log")

    fun init(application: Application) {
        _application = application
    }

}
