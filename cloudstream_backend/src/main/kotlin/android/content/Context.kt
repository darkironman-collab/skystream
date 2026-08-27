package android.content

/**
 * Minimal desktop compatibility context for CloudStream plugins that only need
 * the Android Plugin.load(Context) signature. It intentionally exposes no
 * Android services; plugins that genuinely require Android framework features
 * will fail explicitly instead of silently using a remote bridge.
 */
open class Context
