package com.follow.clash.service

import com.follow.clash.core.Core
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

suspend fun Core.quickSetupAwait(
    initParamsString: String,
    setupParamsString: String,
): String = suspendCancellableCoroutine { continuation ->
    quickSetup(initParamsString, setupParamsString) { result ->
        if (continuation.isActive) {
            continuation.resume(result.orEmpty())
        }
    }
}
