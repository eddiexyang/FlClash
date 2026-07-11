package com.follow.clash

import android.net.VpnService
import com.follow.clash.common.GlobalState
import com.follow.clash.plugins.AppPlugin
import com.follow.clash.plugins.TilePlugin
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.SharedState
import com.follow.clash.service.models.VpnOptions
import com.follow.clash.service.models.sharedState
import com.google.gson.Gson
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class RunState {
    START, PENDING, STOP
}


object State {

    val runLock = Mutex()

    var runTime: Long = 0

    var sharedState: SharedState = SharedState()

    val runStateFlow: MutableStateFlow<RunState> = MutableStateFlow(RunState.STOP)

    var flutterEngine: FlutterEngine? = null

    val appPlugin: AppPlugin?
        get() = flutterEngine?.plugin<AppPlugin>()

    val tilePlugin: TilePlugin?
        get() = flutterEngine?.plugin<TilePlugin>()

    suspend fun handleToggleAction() {
        var action: (suspend () -> Unit)?
        runLock.withLock {
            action = when (runStateFlow.value) {
                RunState.PENDING -> null
                RunState.START -> ::handleStopServiceAction
                RunState.STOP -> ::handleStartServiceAction
            }
        }
        action?.invoke()
    }

    suspend fun handleSyncState() {
        runLock.withLock {
            try {
                Service.bind()
                runTime = Service.getRunTime()
                val runState = when (runTime == 0L) {
                    true -> RunState.STOP
                    false -> RunState.START
                }
                runStateFlow.tryEmit(runState)
            } catch (_: Exception) {
                runStateFlow.tryEmit(RunState.STOP)
            }
        }
    }

    suspend fun handleStartServiceAction() {
        runLock.withLock {
            if (runStateFlow.value != RunState.STOP) {
                return
            }
            tilePlugin?.handleStart()
            if (flutterEngine != null) {
                return
            }
            startServiceWithPref()
        }

    }

    suspend fun handleStopServiceAction() {
        runLock.withLock {
            if (runStateFlow.value != RunState.START) {
                return
            }
            tilePlugin?.handleStop()
            if (flutterEngine != null) {
                return
            }
            GlobalState.application.showToast(sharedState.stopTip)
            handleStopService()
        }
    }

    fun handleStartService(onResult: (Boolean) -> Unit = {}) {
        val appPlugin = flutterEngine?.plugin<AppPlugin>()
        if (appPlugin != null) {
            appPlugin.requestNotificationsPermission {
                startService(onResult)
            }
            return
        }
        startService(onResult)
    }

    private fun startServiceWithPref() {
        GlobalState.launch {
            runLock.withLock {
                if (runStateFlow.value != RunState.STOP) {
                    return@launch
                }
                sharedState = GlobalState.application.sharedState
                setupAndStart()
            }
        }
    }

    suspend fun syncState() {
        Service.updateNotificationParams(
            NotificationParams(
                title = sharedState.currentProfileName,
                stopText = sharedState.stopText,
                onlyStatisticsProxy = sharedState.onlyStatisticsProxy
            )
        )
    }

    private suspend fun setupAndStart() {
        Service.bind()
        syncState()
        GlobalState.application.showToast(sharedState.startTip)
        val initParams = mutableMapOf<String, Any>()
        initParams["home-dir"] = GlobalState.application.filesDir.path
        initParams["version"] = android.os.Build.VERSION.SDK_INT
        val initParamsString = Gson().toJson(initParams)
        val setupParamsString = Gson().toJson(sharedState.setupParams)
        Service.quickSetup(
            initParamsString,
            setupParamsString,
            onStarted = {
                startService()
            },
            onResult = {
                if (it.isNotEmpty()) {
                    GlobalState.application.showToast(it)
                }
            },
        )
    }

    private fun startService(onResult: (Boolean) -> Unit = {}) {
        GlobalState.launch {
            val options = runLock.withLock {
                if (runStateFlow.value != RunState.STOP) {
                    onResult(runStateFlow.value == RunState.START)
                    return@launch
                }
                val nextOptions = sharedState.vpnOptions
                if (nextOptions == null) {
                    onResult(false)
                    return@launch
                }
                runStateFlow.tryEmit(RunState.PENDING)
                nextOptions
            }
            appPlugin?.let {
                it.prepare(
                    needPrepare = options.enable,
                    callBack = { completeStartService(options, onResult) },
                    rejectCallback = { rejectStartService(onResult) },
                )
            } ?: run {
                val intent = VpnService.prepare(GlobalState.application)
                if (intent != null) {
                    rejectStartService(onResult)
                    return@launch
                }
                completeStartService(options, onResult)
            }
        }
    }

    private suspend fun completeStartService(
        options: VpnOptions,
        onResult: (Boolean) -> Unit,
    ) {
        runLock.withLock {
            if (runStateFlow.value != RunState.PENDING) {
                onResult(runStateFlow.value == RunState.START)
                return@withLock
            }
            runTime = Service.startService(options, runTime)
            val didStart = runTime != 0L
            runStateFlow.tryEmit(if (didStart) RunState.START else RunState.STOP)
            onResult(didStart)
        }
    }

    private suspend fun rejectStartService(onResult: (Boolean) -> Unit) {
        runLock.withLock {
            if (runStateFlow.value == RunState.PENDING) {
                runTime = 0L
                runStateFlow.tryEmit(RunState.STOP)
            }
            onResult(false)
        }
    }

    fun handleStopService(onResult: (Boolean) -> Unit = {}) {
        GlobalState.launch {
            runLock.withLock {
                if (runStateFlow.value != RunState.START) {
                    onResult(runStateFlow.value == RunState.STOP)
                    return@launch
                }
                try {
                    runStateFlow.tryEmit(RunState.PENDING)
                    runTime = Service.stopService()
                    val didStop = runTime == 0L
                    runStateFlow.tryEmit(if (didStop) RunState.STOP else RunState.START)
                    onResult(didStop)
                } finally {
                    if (runStateFlow.value == RunState.PENDING) {
                        runStateFlow.tryEmit(RunState.START)
                        onResult(false)
                    }
                }
            }
        }
    }
}
