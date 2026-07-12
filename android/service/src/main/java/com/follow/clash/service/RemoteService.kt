package com.follow.clash.service

import android.app.Service
import android.content.Intent
import android.os.IBinder
import com.follow.clash.common.GlobalState
import com.follow.clash.common.ServiceDelegate
import com.follow.clash.common.chunkedForAidl
import com.follow.clash.common.intent
import com.follow.clash.core.Core
import com.follow.clash.service.State.delegate
import com.follow.clash.service.State.intent
import com.follow.clash.service.State.runLock
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import kotlin.coroutines.resume

class RemoteService : Service(),
    CoroutineScope by CoroutineScope(SupervisorJob() + Dispatchers.Default) {
    private fun handleStopService(result: IResultInterface) {
        launch {
            runLock.withLock {
                val currentDelegate = delegate
                val stoppedThroughDelegate = currentDelegate?.useService { service ->
                    service.stop()
                }?.isSuccess == true
                currentDelegate?.unbind()
                if (!stoppedThroughDelegate) {
                    State.vpnService?.stop()
                }
                intent = null
                delegate = null
                State.runTime = 0
                result.onResult(0)
            }
        }
    }

    private fun handleServiceDisconnected(message: String) {
        GlobalState.logError("RemoteService disconnected: $message")
        intent = null
        delegate = null
    }

    private fun handleStartService(runTime: Long, result: IResultInterface) {
        launch {
            runLock.withLock {
                val nextIntent = when (State.options?.enable == true) {
                    true -> VpnService::class.intent
                    false -> CommonService::class.intent
                }
                val operation = if (State.options?.enable == true) {
                    GlobalState.beginServiceOperation("VpnService start")
                } else {
                    null
                }
                try {
                    if (intent != nextIntent) {
                        delegate?.unbind()
                        delegate = ServiceDelegate(
                            nextIntent,
                            ::handleServiceDisconnected
                        ) { binder ->
                            when (binder) {
                                is VpnService.LocalBinder -> binder.getService()
                                is CommonService.LocalBinder -> binder.getService()
                                else -> throw IllegalArgumentException("Invalid binder type")
                            }
                        }
                        intent = nextIntent
                        delegate?.bind()
                    }
                    val currentDelegate = delegate
                    val didStart = currentDelegate?.useService { service ->
                        service.start()
                    }?.getOrNull() == true
                    if (!didStart) {
                        GlobalState.logError("RemoteService failed to start")
                        currentDelegate?.unbind()
                        if (delegate === currentDelegate) {
                            intent = null
                            delegate = null
                        }
                        State.runTime = 0L
                        result.onResult(0L)
                        return@withLock
                    }
                    State.runTime = when (runTime != 0L) {
                        true -> runTime
                        false -> System.currentTimeMillis()
                    }
                    result.onResult(State.runTime)
                } finally {
                    operation?.let(GlobalState::completeServiceOperation)
                }
            }
        }
    }

    private val binder = object : IRemoteInterface.Stub() {
        override fun invokeAction(data: String, callback: ICallbackInterface) {
            Core.invokeAction(data) {
                launch {
                    runCatching {
                        val chunks = it?.chunkedForAidl() ?: listOf()
                        for ((index, chunk) in chunks.withIndex()) {
                            suspendCancellableCoroutine { cont ->
                                callback.onResult(
                                    chunk,
                                    index == chunks.lastIndex,
                                    object : IAckInterface.Stub() {
                                        override fun onAck() {
                                            cont.resume(Unit)
                                        }
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }

        override fun quickSetup(
            initParamsString: String,
            setupParamsString: String,
            callback: ICallbackInterface,
            onStarted: IVoidInterface
        ) {
            launch {
                val operation = GlobalState.beginServiceOperation(
                    "RemoteService core setup"
                )
                val message = try {
                    State.setupLock.withLock {
                        if (
                            State.coreConfigured &&
                            State.configuredSetupParams == setupParamsString
                        ) {
                            return@withLock ""
                        }
                        Core.quickSetupAwait(
                            initParamsString,
                            setupParamsString,
                        ).also {
                            if (it.isEmpty()) {
                                State.coreConfigured = true
                                State.configuredSetupParams = setupParamsString
                            }
                        }
                    }
                } finally {
                    GlobalState.completeServiceOperation(operation)
                }
                runCatching {
                    val chunks = message.chunkedForAidl().ifEmpty {
                        listOf(byteArrayOf())
                    }
                    for ((index, chunk) in chunks.withIndex()) {
                        suspendCancellableCoroutine { cont ->
                            callback.onResult(
                                chunk,
                                index == chunks.lastIndex,
                                object : IAckInterface.Stub() {
                                    override fun onAck() {
                                        cont.resume(Unit)
                                    }
                                },
                            )
                        }
                    }
                }
                if (message.isEmpty()) {
                    onStarted()
                }
            }
        }

        override fun updateNotificationParams(params: NotificationParams?) {
            State.notificationParamsFlow.tryEmit(params)
        }


        override fun startService(
            options: VpnOptions,
            runtime: Long,
            result: IResultInterface,
        ) {
            GlobalState.log("remote startService")
            State.options = options
            handleStartService(runtime, result)
        }

        override fun stopService(result: IResultInterface) {
            handleStopService(result)
        }

        override fun setEventListener(eventListener: IEventInterface?) {
            GlobalState.log("RemoveEventListener ${eventListener == null}")
            when (eventListener != null) {
                true -> Core.callSetEventListener {
                    launch {
                        runCatching {
                            val id = UUID.randomUUID().toString()
                            val chunks = it?.chunkedForAidl() ?: listOf()
                            for ((index, chunk) in chunks.withIndex()) {
                                suspendCancellableCoroutine { cont ->
                                    eventListener.onEvent(
                                        id,
                                        chunk,
                                        index == chunks.lastIndex,
                                        object : IAckInterface.Stub() {
                                            override fun onAck() {
                                                cont.resume(Unit)
                                            }
                                        },
                                    )
                                }
                            }
                        }
                    }
                }

                false -> Core.callSetEventListener(null)
            }
        }

        override fun getRunTime(): Long {
            return State.runTime
        }
    }

    override fun onBind(intent: Intent?): IBinder {
        return binder
    }

    override fun onDestroy() {
        GlobalState.log("Remote service destroy")
        super.onDestroy()
    }
}
