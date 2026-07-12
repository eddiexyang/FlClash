package com.follow.clash.common


import android.app.Application
import android.os.Process
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
            recoverInterruptedServiceOperation()
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

    private val serviceOperationFile: File
        get() = File(application.filesDir, "android-service-operation.pending")

    @Synchronized
    fun beginServiceOperation(operation: String): String {
        val token = "${Process.myPid()} ${System.currentTimeMillis()} $operation"
        runCatching {
            serviceOperationFile.writeText(token)
        }
        return token
    }

    @Synchronized
    fun completeServiceOperation(token: String) {
        runCatching {
            val file = serviceOperationFile
            if (file.exists() && file.readText() == token) {
                file.delete()
            }
        }
    }

    @Synchronized
    private fun recoverInterruptedServiceOperation() {
        runCatching {
            val file = serviceOperationFile
            if (!file.exists()) {
                return
            }
            val value = file.readText()
            val parts = value.split(' ', limit = 3)
            val pid = parts.getOrNull(0)?.toIntOrNull()
            val operation = parts.getOrNull(2)
            if (pid != null && File("/proc/$pid").exists()) {
                return
            }
            file.delete()
            logError(
                "${operation ?: "VpnService operation"} terminated unexpectedly"
            )
        }
    }

    fun init(application: Application) {
        _application = application
    }

}
