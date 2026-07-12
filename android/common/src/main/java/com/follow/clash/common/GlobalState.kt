package com.follow.clash.common


import android.app.Application
import android.os.Process
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import java.io.File
import java.util.UUID

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

    @Synchronized
    fun beginServiceOperation(operation: String): String {
        val token = "${Process.myPid()}-${System.currentTimeMillis()}-${UUID.randomUUID()}"
        runCatching {
            serviceOperationFile(token).writeText(operation)
        }
        return token
    }

    @Synchronized
    fun completeServiceOperation(token: String) {
        runCatching {
            serviceOperationFile(token).delete()
        }
    }

    @Synchronized
    private fun recoverInterruptedServiceOperation() {
        runCatching {
            val files = application.filesDir.listFiles { file ->
                file.name.startsWith(SERVICE_OPERATION_PREFIX) &&
                    file.name.endsWith(SERVICE_OPERATION_SUFFIX)
            } ?: return
            for (file in files) {
                val token = file.name
                    .removePrefix(SERVICE_OPERATION_PREFIX)
                    .removeSuffix(SERVICE_OPERATION_SUFFIX)
                val pid = token.substringBefore('-').toIntOrNull()
                if (pid != null && File("/proc/$pid").exists()) {
                    continue
                }
                val operation = file.readText().ifBlank {
                    "VpnService operation"
                }
                file.delete()
                logError("$operation terminated unexpectedly")
            }
        }
    }

    private fun serviceOperationFile(token: String): File {
        return File(
            application.filesDir,
            "$SERVICE_OPERATION_PREFIX$token$SERVICE_OPERATION_SUFFIX"
        )
    }

    private const val SERVICE_OPERATION_PREFIX = "android-service-operation-"
    private const val SERVICE_OPERATION_SUFFIX = ".pending"

    fun init(application: Application) {
        _application = application
    }

}
