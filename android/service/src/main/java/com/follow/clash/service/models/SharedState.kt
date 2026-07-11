package com.follow.clash.service.models

import android.content.Context
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName

data class SharedState(
    val startTip: String = "Starting VPN...",
    val stopTip: String = "Stopping VPN...",
    val currentProfileName: String = "FlClash",
    val stopText: String = "Stop",
    val onlyStatisticsProxy: Boolean = false,
    val vpnOptions: VpnOptions? = null,
    val setupParams: SetupParams? = null,
)

data class SetupParams(
    @SerializedName("test-url")
    val testUrl: String = "",
    @SerializedName("selected-map")
    val selectedMap: Map<String, String> = emptyMap(),
)

val Context.sharedState: SharedState
    get() {
        val preferences = getSharedPreferences(
            "FlutterSharedPreferences",
            Context.MODE_PRIVATE,
        )
        val raw = preferences.getString("flutter.sharedState", null)
        if (raw.isNullOrBlank()) {
            return SharedState()
        }
        return runCatching {
            Gson().fromJson(raw, SharedState::class.java) ?: SharedState()
        }.getOrDefault(SharedState())
    }

private const val SERVICE_STATE_PREFERENCES = "serviceState"
private const val VPN_RUNNING_KEY = "vpnRunning"

var Context.vpnRunning: Boolean
    get() = getSharedPreferences(
        SERVICE_STATE_PREFERENCES,
        Context.MODE_PRIVATE,
    ).getBoolean(VPN_RUNNING_KEY, false)
    set(value) {
        getSharedPreferences(
            SERVICE_STATE_PREFERENCES,
            Context.MODE_PRIVATE,
        ).edit().putBoolean(VPN_RUNNING_KEY, value).commit()
    }
