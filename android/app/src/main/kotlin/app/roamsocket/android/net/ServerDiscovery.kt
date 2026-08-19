package app.roamsocket.android.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import app.roamsocket.core.server.Endpoint
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.onStart

/**
 * LAN discovery of the desktop server. Mirrors the iOS
 * `ServerDiscovery.swift` that listens on `_roamsocket._tcp`. The desktop
 * companion advertises the same service type.
 *
 * NOTE: Android requires the NSD API be used on a looper-backed thread;
 * the [Flow] returned here marshals callbacks onto the calling coroutine.
 */
class ServerDiscovery(context: Context) {

    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    /**
     * Discover `_roamsocket._tcp` services and yield [Endpoint]s as they
     * are found. Re-runs the discovery loop on each subscription.
     *
     * On API 26+ the registration type is "tcp." for cleartext; the bare
     * "_roamsocket._tcp" form is the more common one.
     */
    fun observe(): Flow<Endpoint> = callbackFlow {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                close(IllegalStateException("NSD start failed: $errorCode"))
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit

            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceType.contains(LEGACY_SERVICE_TYPE) ||
                    service.serviceType.contains(NEW_SERVICE_TYPE)
                ) {
                    manager.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                            val host = serviceInfo.host?.hostAddress ?: return
                            val port = serviceInfo.port
                            // Prefer http:// for the LAN; the desktop serves cleartext.
                            trySend(Endpoint(baseURL = "http://$host:$port"))
                        }
                    })
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) = Unit
        }
        manager.discoverServices(LEGACY_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        awaitClose { manager.stopServiceDiscovery(listener) }
    }.onStart { /* triggers discovery when first collector subscribes */ }

    private companion object {
        const val LEGACY_SERVICE_TYPE = "_roamsocket._tcp."
        const val NEW_SERVICE_TYPE = "_roamsocket._tcp"
    }
}
