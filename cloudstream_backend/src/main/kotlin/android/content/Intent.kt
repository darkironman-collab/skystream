package android.content

/**
 * Minimal desktop type shim for Android-built CloudStream plugins whose
 * bytecode references android.content.Intent. Provider-only plugins generally
 * only need the class to exist so their Plugin subclass can be verified and
 * loaded on the JVM.
 */
open class Intent {
    var action: String? = null

    constructor()
    constructor(action: String?) {
        this.action = action
    }

    constructor(context: Context?, targetClass: Class<*>?)

    fun setAction(value: String?): Intent {
        action = value
        return this
    }

    fun putExtra(name: String?, value: String?): Intent = this
    fun putExtra(name: String?, value: Boolean): Intent = this
    fun putExtra(name: String?, value: Int): Intent = this
}
