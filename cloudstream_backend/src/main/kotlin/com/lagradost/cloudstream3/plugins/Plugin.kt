package com.lagradost.cloudstream3.plugins

import android.content.Context
import android.content.res.Resources

/**
 * Desktop compatibility surface for Android-built CloudStream extensions.
 *
 * Most CS3 plugins subclass the Android app's Plugin and override
 * load(Context). The official CloudStream KMP/JVM library intentionally only
 * ships BasePlugin.load(). This shim keeps the same binary class/method names
 * and forwards BasePlugin.load() into the virtual load(Context) method, letting
 * provider-only extensions register MainAPI implementations on desktop.
 */
abstract class Plugin : BasePlugin() {
    open fun load(context: Context) {
        super.load()
    }

    override fun load() {
        load(Context())
    }

    var resources: Resources? = null
    var openSettings: ((Context) -> Unit)? = null
}
