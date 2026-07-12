package com.follow.clash.service

import android.content.Intent
import android.net.ConnectivityManager
import android.net.ProxyInfo
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.Parcel
import android.os.RemoteException
import android.util.Log
import androidx.core.content.getSystemService
import com.follow.clash.common.AccessControlMode
import com.follow.clash.common.GlobalState
import com.follow.clash.core.Core
import com.follow.clash.service.models.VpnOptions
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.SharedState
import com.follow.clash.service.models.getIpv4RouteAddress
import com.follow.clash.service.models.getIpv6RouteAddress
import com.follow.clash.service.models.sharedState
import com.follow.clash.service.models.toCIDR
import com.follow.clash.service.models.vpnRunning
import com.follow.clash.service.modules.NetworkObserveModule
import com.follow.clash.service.modules.NotificationModule
import com.follow.clash.service.modules.SuspendModule
import com.follow.clash.service.modules.moduleLoader
import com.follow.clash.service.modules.startInitialForeground
import com.google.gson.Gson
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicBoolean
import android.net.VpnService as SystemVpnService

class VpnService : SystemVpnService(), IBaseService,
    CoroutineScope by CoroutineScope(Dispatchers.Default) {

    private val self: VpnService
        get() = this

    private val loader = moduleLoader {
        install(NetworkObserveModule(self))
        install(NotificationModule(self))
        install(SuspendModule(self))
    }

    private val started = AtomicBoolean(false)
    private val restoreLock = Mutex()
    private var restoreJob: Job? = null

    override fun onCreate() {
        super.onCreate()
        State.alwaysOn = false
        State.vpnService = this
        GlobalState.log("VpnService create")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        restoreService()
        return START_STICKY
    }

    private fun restoreService() {
        val persistedState = applicationContext.sharedState
        State.alwaysOn = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            isAlwaysOn
        } else {
            false
        }
        val notificationParams = persistedState.notificationParams
        State.notificationParamsFlow.tryEmit(notificationParams)
        startInitialForeground(notificationParams, persistedState.startTip)
        restoreAlwaysOn(persistedState)
    }

    override fun onDestroy() {
        restoreJob?.cancel()
        restoreJob = null
        cleanup()
        State.runTime = 0L
        if (State.vpnService === this) {
            State.vpnService = null
        }
        GlobalState.log("VpnService destroy")
        super.onDestroy()
    }

    override fun onRevoke() {
        GlobalState.log("VpnService revoked")
        applicationContext.vpnRunning = false
        stop()
    }

    private val connectivity by lazy {
        getSystemService<ConnectivityManager>()
    }
    private val uidPageNameMap = mutableMapOf<Int, String>()

    private fun resolverProcess(
        protocol: Int,
        source: InetSocketAddress,
        target: InetSocketAddress,
        uid: Int,
    ): String {
        val nextUid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            connectivity?.getConnectionOwnerUid(protocol, source, target) ?: -1
        } else {
            uid
        }
        if (nextUid == -1) {
            return ""
        }
        if (!uidPageNameMap.containsKey(nextUid)) {
            uidPageNameMap[nextUid] = this.packageManager?.getPackagesForUid(nextUid)?.first() ?: ""
        }
        return uidPageNameMap[nextUid] ?: ""
    }

    val VpnOptions.address
        get(): String = buildString {
            append(IPV4_ADDRESS)
            if (ipv6) {
                append(",")
                append(IPV6_ADDRESS)
            }
        }

    val VpnOptions.dns
        get(): String {
            if (dnsHijacking) {
                return NET_ANY
            }
            return buildString {
                append(DNS)
                if (ipv6) {
                    append(",")
                    append(DNS6)
                }
            }
        }


    override fun onLowMemory() {
        Core.forceGC()
        super.onLowMemory()
    }

    private val binder = LocalBinder()

    inner class LocalBinder : Binder() {
        fun getService(): VpnService = this@VpnService

        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            try {
                val isSuccess = super.onTransact(code, data, reply, flags)
                if (!isSuccess) {
                    GlobalState.log("VpnService disconnected")
                    handleDestroy()
                }
                return isSuccess
            } catch (e: RemoteException) {
                GlobalState.log("VpnService onTransact $e")
                return false
            }
        }
    }

    override fun onBind(intent: Intent): IBinder? {
        return if (intent.action == SERVICE_INTERFACE) {
            GlobalState.log("VpnService system bind")
            restoreService()
            super.onBind(intent)
        } else {
            binder
        }
    }

    private val SharedState.notificationParams: NotificationParams
        get() = NotificationParams(
            title = currentProfileName,
            stopText = stopText,
            onlyStatisticsProxy = onlyStatisticsProxy,
        )

    private fun restoreAlwaysOn(persistedState: SharedState) {
        if (restoreJob?.isActive == true) {
            return
        }
        restoreJob = launch {
            restoreLock.withLock {
                if (started.get()) {
                    return@withLock
                }
                val options = persistedState.vpnOptions
                val setupParams = persistedState.setupParams
                if (options == null || setupParams == null) {
                    GlobalState.log("Always-on restore skipped: configuration is missing")
                    return@withLock
                }
                State.options = options.copy(enable = true)
                val initParams = mapOf(
                    "home-dir" to filesDir.path,
                    "version" to Build.VERSION.SDK_INT,
                )
                val gson = Gson()
                val message = withTimeoutOrNull(15_000) {
                    Core.quickSetupAwait(
                        gson.toJson(initParams),
                        gson.toJson(setupParams),
                    )
                }
                when {
                    message == null -> {
                        GlobalState.log("Always-on restore failed: core setup timed out")
                        return@withLock
                    }

                    message.isNotEmpty() -> {
                        GlobalState.log("Always-on restore failed: $message")
                        return@withLock
                    }
                }
                State.runTime = System.currentTimeMillis()
                if (!start()) {
                    State.runTime = 0L
                    GlobalState.log("Always-on restore failed: VPN could not start")
                    return@withLock
                }
                GlobalState.log("Always-on VPN restored")
            }
        }
    }

    private fun handleStart(options: VpnOptions) {
        val fd = with(Builder()) {
            val cidr = IPV4_ADDRESS.toCIDR()
            addAddress(cidr.address, cidr.prefixLength)
            Log.d(
                "addAddress", "address: ${cidr.address} prefixLength:${cidr.prefixLength}"
            )
            val routeAddress = options.getIpv4RouteAddress()
            if (routeAddress.isNotEmpty()) {
                try {
                    routeAddress.forEach { i ->
                        Log.d(
                            "addRoute4", "address: ${i.address} prefixLength:${i.prefixLength}"
                        )
                        addRoute(i.address, i.prefixLength)
                    }
                } catch (_: Exception) {
                    addRoute(NET_ANY, 0)
                }
            } else {
                addRoute(NET_ANY, 0)
            }
            if (options.ipv6) {
                try {
                    val cidr = IPV6_ADDRESS.toCIDR()
                    Log.d(
                        "addAddress6", "address: ${cidr.address} prefixLength:${cidr.prefixLength}"
                    )
                    addAddress(cidr.address, cidr.prefixLength)
                } catch (_: Exception) {
                    Log.d(
                        "addAddress6", "IPv6 is not supported."
                    )
                }

                try {
                    val routeAddress = options.getIpv6RouteAddress()
                    if (routeAddress.isNotEmpty()) {
                        try {
                            routeAddress.forEach { i ->
                                Log.d(
                                    "addRoute6",
                                    "address: ${i.address} prefixLength:${i.prefixLength}"
                                )
                                addRoute(i.address, i.prefixLength)
                            }
                        } catch (_: Exception) {
                            addRoute("::", 0)
                        }
                    } else {
                        addRoute(NET_ANY6, 0)
                    }
                } catch (_: Exception) {
                    addRoute(NET_ANY6, 0)
                }
            }
            addDnsServer(DNS)
            if (options.ipv6) {
                addDnsServer(DNS6)
            }
            setMtu(9000)
            options.accessControlProps.let { accessControl ->
                if (accessControl.enable) {
                    when (accessControl.mode) {
                        AccessControlMode.ACCEPT_SELECTED -> {
                            (accessControl.acceptList + packageName).forEach {
                                addAllowedApplication(it)
                            }
                        }

                        AccessControlMode.REJECT_SELECTED -> {
                            (accessControl.rejectList - packageName).forEach {
                                addDisallowedApplication(it)
                            }
                        }
                    }
                }
            }
            setSession("FlClash")
            setBlocking(false)
            if (Build.VERSION.SDK_INT >= 29) {
                setMetered(false)
            }
            if (options.allowBypass) {
                allowBypass()
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && options.systemProxy) {
                GlobalState.log("Open http proxy")
                setHttpProxy(
                    ProxyInfo.buildDirectProxy(
                        "127.0.0.1", options.port, options.bypassDomain
                    )
                )
            }
            establish()?.detachFd()
                ?: throw NullPointerException("Establish VPN rejected by system")
        }
        Core.startTun(
            fd,
            protect = this::protect,
            resolverProcess = this::resolverProcess,
            options.stack,
            options.address,
            options.dns
        )
    }

    override fun start(): Boolean {
        val options = State.options ?: return false
        if (!started.compareAndSet(false, true)) {
            return true
        }
        return try {
            loader.load()
            handleStart(options)
            applicationContext.vpnRunning = true
            true
        } catch (exception: Exception) {
            GlobalState.log("VpnService start failed: $exception")
            stop()
            false
        }
    }

    override fun stop() {
        applicationContext.vpnRunning = false
        cleanup()
        State.runTime = 0L
        stopSelf()
    }

    private fun cleanup() {
        if (started.compareAndSet(true, false)) {
            loader.cancel()
            Core.stopTun()
        }
    }

    companion object {
        private const val IPV4_ADDRESS = "172.19.0.1/30"
        private const val IPV6_ADDRESS = "fdfe:dcba:9876::1/126"
        private const val DNS = "172.19.0.2"
        private const val DNS6 = "fdfe:dcba:9876::2"
        private const val NET_ANY = "0.0.0.0"
        private const val NET_ANY6 = "::"
    }
}
