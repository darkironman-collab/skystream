@file:Suppress("DEPRECATION_ERROR")

package dev.akash.skystream.cloudstream

import com.fasterxml.jackson.core.type.TypeReference
import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.lagradost.cloudstream3.APIHolder
import com.lagradost.cloudstream3.AnimeLoadResponse
import com.lagradost.cloudstream3.AnimeSearchResponse
import com.lagradost.cloudstream3.DubStatus
import com.lagradost.cloudstream3.Episode
import com.lagradost.cloudstream3.LiveSearchResponse
import com.lagradost.cloudstream3.LiveStreamLoadResponse
import com.lagradost.cloudstream3.LoadResponse
import com.lagradost.cloudstream3.MainAPI
import com.lagradost.cloudstream3.MovieLoadResponse
import com.lagradost.cloudstream3.MovieSearchResponse
import com.lagradost.cloudstream3.SearchResponse
import com.lagradost.cloudstream3.TorrentLoadResponse
import com.lagradost.cloudstream3.TvSeriesLoadResponse
import com.lagradost.cloudstream3.TvSeriesSearchResponse
import com.lagradost.cloudstream3.TvType
import com.lagradost.cloudstream3.plugins.BasePlugin
import com.lagradost.cloudstream3.utils.ExtractorLink
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URI
import java.net.URLClassLoader
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.jar.JarFile

private val json = jacksonObjectMapper()

private data class Config(
    val port: Int,
    val token: String,
    val dataDir: File,
)

private data class PluginInstallRequest(
    val name: String = "CloudStream plugin",
    val internalName: String? = null,
    val url: String? = null,
    val jarUrl: String? = null,
    val jarHash: String? = null,
)

private data class InstallResult(
    val ok: Boolean,
    val status: String,
    val message: String,
    val providers: List<Map<String, Any?>> = emptyList(),
)

private class CloudStreamRuntime(private val dataDir: File) {
    private val pluginsDir = File(dataDir, "plugins").apply { mkdirs() }
    private val http = HttpClient.newBuilder()
        .followRedirects(HttpClient.Redirect.NORMAL)
        .build()
    private val classLoaders = Collections.synchronizedList(mutableListOf<URLClassLoader>())

    init {
        loadInstalledPlugins()
    }

    fun providerMaps(): List<Map<String, Any?>> = providers().map { providerMap(it) }

    fun installPlugin(request: PluginInstallRequest): InstallResult {
        val jarUrl = request.jarUrl?.trim().orEmpty()
        if (jarUrl.isEmpty()) {
            val cs3 = request.url?.trim().orEmpty()
            return InstallResult(
                ok = false,
                status = "android_only",
                message = if (cs3.endsWith(".cs3", ignoreCase = true)) {
                    "This provider publishes only Android/Dex .cs3 bytecode. " +
                        "The local JVM backend needs a cross-platform jarUrl."
                } else {
                    "No JVM jarUrl is available for this provider."
                },
            )
        }

        return try {
            val safeName = sanitize(request.internalName ?: request.name)
            val target = File(pluginsDir, "$safeName.jar")
            val bytes = download(jarUrl)
            if (bytes.size < 200) {
                return InstallResult(false, "download_failed", "Downloaded JAR is unexpectedly small.")
            }
            if (!verifySha256(bytes, request.jarHash)) {
                return InstallResult(false, "hash_mismatch", "JAR SHA-256 verification failed.")
            }
            val temp = File(pluginsDir, "$safeName.jar.part")
            temp.writeBytes(bytes)
            if (target.exists()) target.delete()
            if (!temp.renameTo(target)) {
                temp.copyTo(target, overwrite = true)
                temp.delete()
            }

            val loaded = loadJar(target)
            InstallResult(
                ok = loaded.isNotEmpty(),
                status = if (loaded.isNotEmpty()) "installed" else "no_provider",
                message = if (loaded.isNotEmpty()) {
                    "Loaded ${loaded.size} CloudStream provider(s) locally."
                } else {
                    "The JAR was downloaded but did not register a compatible provider."
                },
                providers = loaded.map { providerMap(it) },
            )
        } catch (t: Throwable) {
            InstallResult(false, "error", t.message ?: t::class.java.simpleName)
        }
    }

    suspend fun search(query: String, requestedProvider: String?): List<Map<String, Any?>> {
        val candidates = providers().filter {
            requestedProvider.isNullOrBlank() || it.name.equals(requestedProvider, ignoreCase = true)
        }
        return coroutineScope {
            candidates.map { api ->
                async(Dispatchers.IO) {
                    val results = withTimeoutOrNull(api.searchTimeoutMs ?: 25_000L) {
                        try {
                            api.search(query) ?: emptyList()
                        } catch (_: Throwable) {
                            emptyList()
                        }
                    } ?: emptyList()
                    results.map { searchMap(it, api) }
                }
            }.awaitAll().flatten()
        }
    }

    suspend fun details(providerName: String, url: String): Map<String, Any?>? {
        val api = provider(providerName) ?: return null
        val response = withTimeoutOrNull(api.loadTimeoutMs ?: 35_000L) {
            try {
                api.load(url)
            } catch (_: Throwable) {
                null
            }
        } ?: return null
        return loadMap(response, api)
    }

    suspend fun streams(providerName: String, data: String): Map<String, Any?> {
        val api = provider(providerName)
            ?: return mapOf("ok" to false, "error" to "Provider not loaded", "streams" to emptyList<Any>())

        val links = Collections.synchronizedList(mutableListOf<Map<String, Any?>>())
        val subtitles = Collections.synchronizedList(mutableListOf<Map<String, Any?>>())

        val completed = withTimeoutOrNull(api.loadLinksTimeoutMs ?: 90_000L) {
            try {
                api.loadLinks(
                    data = data,
                    isCasting = false,
                    subtitleCallback = { sub ->
                        subtitles += mapOf(
                            "url" to sub.url,
                            "label" to sub.lang,
                            "lang" to sub.lang,
                            "headers" to sub.headers,
                        )
                    },
                    callback = { link -> links += extractorMap(link, api) },
                )
            } catch (_: Throwable) {
                false
            }
        } ?: false

        return mapOf(
            "ok" to (completed || links.isNotEmpty()),
            "provider" to api.name,
            "streams" to links.toList(),
            "subtitles" to subtitles.toList(),
        )
    }

    private fun provider(name: String): MainAPI? = providers().firstOrNull {
        it.name.equals(name, ignoreCase = true)
    }

    private fun providers(): List<MainAPI> {
        val all = mutableListOf<MainAPI>()
        try {
            all.addAll(APIHolder.apis)
        } catch (_: Throwable) {
        }
        try {
            all.addAll(APIHolder.allProviders)
        } catch (_: Throwable) {
        }
        return all.distinctBy { it.name }
            .filter { it.name.isNotBlank() && it.name != "NONE" }
    }

    private fun loadInstalledPlugins() {
        pluginsDir.listFiles { file ->
            file.isFile && file.extension.equals("jar", ignoreCase = true) && file.length() > 200
        }?.sortedBy { it.name.lowercase() }?.forEach { file ->
            try {
                loadJar(file)
            } catch (t: Throwable) {
                System.err.println("[CloudStreamBackend] Failed to load ${file.name}: ${t.message}")
            }
        }
    }

    private fun loadJar(jarFile: File): List<MainAPI> {
        val before = providers().map { it.name }.toSet()
        val loader = URLClassLoader(arrayOf(jarFile.toURI().toURL()), javaClass.classLoader)
        classLoaders += loader

        var loadedPlugin = false
        JarFile(jarFile).use { jar ->
            val manifestEntry = jar.getJarEntry("manifest.json")
            if (manifestEntry != null) {
                try {
                    val manifestText = jar.getInputStream(manifestEntry).bufferedReader().use { it.readText() }
                    val manifest = json.readValue(manifestText, object : TypeReference<Map<String, Any?>>() {})
                    val pluginClassName = manifest["pluginClassName"]?.toString()?.trim().orEmpty()
                    val requiresResources = manifest["requiresResources"] == true
                    if (requiresResources) {
                        throw IllegalStateException(
                            "Plugin requires Android resources and cannot run in the lightweight JVM backend."
                        )
                    }
                    if (pluginClassName.isNotEmpty()) {
                        loadedPlugin = instantiatePlugin(loader, pluginClassName, jarFile)
                    }
                } catch (t: Throwable) {
                    System.err.println("[CloudStreamBackend] Manifest load failed for ${jarFile.name}: ${t.message}")
                }
            }

            if (!loadedPlugin) {
                val entries = jar.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    if (!entry.name.endsWith(".class") || entry.name.contains('$')) continue
                    val className = entry.name.removeSuffix(".class").replace('/', '.')
                    try {
                        val clazz = loader.loadClass(className)
                        if (BasePlugin::class.java.isAssignableFrom(clazz) &&
                            !java.lang.reflect.Modifier.isAbstract(clazz.modifiers)
                        ) {
                            if (instantiatePlugin(loader, className, jarFile)) {
                                loadedPlugin = true
                                break
                            }
                        }
                    } catch (_: Throwable) {
                    }
                }
            }

            // Some cross-platform packages expose a MainAPI directly rather than a BasePlugin.
            if (!loadedPlugin) {
                val entries = jar.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    if (!entry.name.endsWith(".class") || entry.name.contains('$')) continue
                    val className = entry.name.removeSuffix(".class").replace('/', '.')
                    try {
                        val clazz = loader.loadClass(className)
                        if (MainAPI::class.java.isAssignableFrom(clazz) &&
                            !java.lang.reflect.Modifier.isAbstract(clazz.modifiers)
                        ) {
                            val api = clazz.getDeclaredConstructor().newInstance() as MainAPI
                            api.sourcePlugin = jarFile.absolutePath
                            APIHolder.allProviders.add(api)
                            APIHolder.addPluginMapping(api)
                        }
                    } catch (_: Throwable) {
                    }
                }
            }
        }

        try {
            APIHolder.initAll()
        } catch (_: Throwable) {
        }
        return providers().filter { it.name !in before }
    }

    private fun instantiatePlugin(loader: ClassLoader, className: String, jarFile: File): Boolean {
        return try {
            val clazz = loader.loadClass(className)
            if (!BasePlugin::class.java.isAssignableFrom(clazz)) return false
            val plugin = clazz.getDeclaredConstructor().newInstance() as BasePlugin
            plugin.filename = jarFile.absolutePath
            plugin.load()
            true
        } catch (t: Throwable) {
            System.err.println("[CloudStreamBackend] Plugin $className failed: ${t.message}")
            false
        }
    }

    private fun providerMap(api: MainAPI): Map<String, Any?> = mapOf(
        "name" to api.name,
        "mainUrl" to api.mainUrl,
        "language" to api.lang,
        "hasMainPage" to api.hasMainPage,
        "supportedTypes" to api.supportedTypes.map { typeName(it) },
        "sourcePlugin" to api.sourcePlugin,
    )

    private fun searchMap(item: SearchResponse, api: MainAPI): Map<String, Any?> {
        val year = when (item) {
            is MovieSearchResponse -> item.year
            is TvSeriesSearchResponse -> item.year
            is AnimeSearchResponse -> item.year
            else -> null
        }
        return mapOf(
            "title" to item.name,
            "url" to item.url,
            "posterUrl" to (item.posterUrl ?: ""),
            "headers" to item.posterHeaders,
            "provider" to api.name,
            "type" to typeName(item.type),
            "year" to year,
            "score" to item.score?.toDouble(10),
        )
    }

    private fun loadMap(response: LoadResponse, api: MainAPI): Map<String, Any?> {
        val episodes = when (response) {
            is TvSeriesLoadResponse -> response.episodes.map { episodeMap(it, DubStatus.None) }
            is AnimeLoadResponse -> response.episodes.flatMap { (dub, list) ->
                list.map { episodeMap(it, dub) }
            }
            else -> emptyList()
        }

        val streamData = when (response) {
            is MovieLoadResponse -> response.dataUrl
            is LiveStreamLoadResponse -> response.dataUrl
            is TorrentLoadResponse -> response.magnet ?: response.torrent ?: response.url
            else -> null
        }

        return mapOf(
            "title" to response.name,
            "url" to response.url,
            "provider" to api.name,
            "type" to typeName(response.type),
            "posterUrl" to (response.posterUrl ?: ""),
            "bannerUrl" to response.backgroundPosterUrl,
            "logoUrl" to response.logoUrl,
            "description" to response.plot,
            "year" to response.year,
            "score" to response.score?.toDouble(10),
            "duration" to response.duration,
            "tags" to response.tags,
            "contentRating" to response.contentRating,
            "headers" to response.posterHeaders,
            "streamData" to streamData,
            "episodes" to episodes,
            "syncData" to response.syncData,
        )
    }

    private fun episodeMap(episode: Episode, dubStatus: DubStatus): Map<String, Any?> = mapOf(
        "name" to (episode.name ?: "Episode ${episode.episode ?: ""}"),
        "data" to episode.data,
        "season" to (episode.season ?: 0),
        "episode" to (episode.episode ?: 0),
        "description" to episode.description,
        "posterUrl" to episode.posterUrl,
        "rating" to episode.score?.toDouble(10),
        "runtime" to episode.runTime,
        "airDate" to episode.date?.toString(),
        "dubStatus" to when (dubStatus) {
            DubStatus.Dubbed -> "dubbed"
            DubStatus.Subbed -> "subbed"
            else -> "none"
        },
    )

    private fun extractorMap(link: ExtractorLink, api: MainAPI): Map<String, Any?> = mapOf(
        "url" to link.url,
        "source" to (link.name ?: "CloudStream"),
        "providerName" to api.name,
        "quality" to link.quality,
        "headers" to link.getAllHeaders(),
    )

    private fun typeName(type: TvType?): String = when (type) {
        TvType.Movie, TvType.AnimeMovie, TvType.Torrent, TvType.Video -> "movie"
        TvType.TvSeries, TvType.Cartoon, TvType.AsianDrama -> "series"
        TvType.Anime, TvType.OVA -> "anime"
        TvType.Live -> "livestream"
        else -> "other"
    }

    private fun sanitize(value: String): String {
        val cleaned = value.replace(Regex("[^A-Za-z0-9._-]+"), "_").trim('_', '.', '-')
        return cleaned.ifBlank { "plugin" }
    }

    private fun download(url: String): ByteArray {
        val request = HttpRequest.newBuilder(URI.create(url))
            .header("User-Agent", "SkyStream-CloudStream-Backend/0.1")
            .GET()
            .build()
        val response = http.send(request, HttpResponse.BodyHandlers.ofByteArray())
        if (response.statusCode() !in 200..299) {
            throw IllegalStateException("HTTP ${response.statusCode()} while downloading plugin")
        }
        return response.body()
    }

    private fun verifySha256(bytes: ByteArray, expected: String?): Boolean {
        if (expected.isNullOrBlank()) return true
        val normalized = expected.trim().lowercase().removePrefix("sha256-")
        if (normalized.length != 64) return true
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        return digest == normalized
    }
}

private class LocalApiServer(
    private val runtime: CloudStreamRuntime,
    private val config: Config,
) {
    private val server = HttpServer.create(
        InetSocketAddress(InetAddress.getLoopbackAddress(), config.port),
        0,
    )

    init {
        server.executor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "skystream-cloudstream-http").apply { isDaemon = true }
        }
        route("/health") { exchange, _ ->
            respond(exchange, 200, mapOf(
                "ok" to true,
                "backend" to "skystream-cloudstream-local",
                "version" to "0.1.0",
                "providers" to runtime.providerMaps().size,
            ))
        }
        route("/providers") { exchange, _ ->
            respond(exchange, 200, mapOf("providers" to runtime.providerMaps()))
        }
        route("/plugins/install") { exchange, body ->
            val request = json.convertValue(body, PluginInstallRequest::class.java)
            val result = runtime.installPlugin(request)
            respond(exchange, if (result.ok) 200 else 422, result)
        }
        route("/search") { exchange, body ->
            val query = body["query"]?.toString()?.trim().orEmpty()
            val provider = body["provider"]?.toString()
            if (query.isEmpty()) {
                respond(exchange, 400, mapOf("error" to "query is required"))
            } else {
                val results = runBlocking { runtime.search(query, provider) }
                respond(exchange, 200, mapOf("results" to results))
            }
        }
        route("/details") { exchange, body ->
            val provider = body["provider"]?.toString().orEmpty()
            val url = body["url"]?.toString().orEmpty()
            if (provider.isEmpty() || url.isEmpty()) {
                respond(exchange, 400, mapOf("error" to "provider and url are required"))
            } else {
                val result = runBlocking { runtime.details(provider, url) }
                if (result == null) {
                    respond(exchange, 404, mapOf("error" to "Could not load title"))
                } else {
                    respond(exchange, 200, result)
                }
            }
        }
        route("/streams") { exchange, body ->
            val provider = body["provider"]?.toString().orEmpty()
            val data = body["data"]?.toString().orEmpty()
            if (provider.isEmpty() || data.isEmpty()) {
                respond(exchange, 400, mapOf("error" to "provider and data are required"))
            } else {
                val result = runBlocking { runtime.streams(provider, data) }
                respond(exchange, 200, result)
            }
        }
    }

    fun start(): Int {
        server.start()
        return server.address.port
    }

    private fun route(path: String, handler: (HttpExchange, Map<String, Any?>) -> Unit) {
        server.createContext(path) { exchange ->
            try {
                if (!authorized(exchange)) {
                    respond(exchange, HttpURLConnection.HTTP_UNAUTHORIZED, mapOf("error" to "unauthorized"))
                    return@createContext
                }
                if (path != "/health" && path != "/providers" && exchange.requestMethod != "POST") {
                    respond(exchange, 405, mapOf("error" to "POST required"))
                    return@createContext
                }
                val body = if (exchange.requestMethod == "POST") readBody(exchange) else emptyMap()
                handler(exchange, body)
            } catch (t: Throwable) {
                respond(exchange, 500, mapOf("error" to (t.message ?: t::class.java.simpleName)))
            }
        }
    }

    private fun authorized(exchange: HttpExchange): Boolean {
        if (config.token.isBlank()) return true
        return exchange.requestHeaders.getFirst("X-SkyStream-Token") == config.token
    }

    private fun readBody(exchange: HttpExchange): Map<String, Any?> {
        val bytes = exchange.requestBody.use { it.readBytes() }
        if (bytes.isEmpty()) return emptyMap()
        return json.readValue(bytes, object : TypeReference<Map<String, Any?>>() {})
    }

    private fun respond(exchange: HttpExchange, status: Int, value: Any) {
        val bytes = json.writeValueAsBytes(value)
        exchange.responseHeaders.set("Content-Type", "application/json; charset=utf-8")
        exchange.responseHeaders.set("Cache-Control", "no-store")
        exchange.sendResponseHeaders(status, bytes.size.toLong())
        exchange.responseBody.use { it.write(bytes) }
    }
}

fun main(args: Array<String>) {
    val config = parseConfig(args)
    config.dataDir.mkdirs()
    val runtime = CloudStreamRuntime(config.dataDir)
    val server = LocalApiServer(runtime, config)
    val port = server.start()
    println("SKYSTREAM_CLOUDSTREAM_BACKEND_READY:$port")
    System.out.flush()
    CountDownLatch(1).await()
}

private fun parseConfig(args: Array<String>): Config {
    fun value(flag: String): String? {
        val index = args.indexOf(flag)
        return if (index >= 0 && index + 1 < args.size) args[index + 1] else null
    }

    val port = value("--port")?.toIntOrNull()?.takeIf { it in 0..65535 } ?: 0
    val token = value("--token").orEmpty()
    val defaultDir = File(System.getProperty("user.home") ?: ".", ".skystream/cloudstream-backend")
    val dataDir = value("--data-dir")?.let(::File) ?: defaultDir
    return Config(port = port, token = token, dataDir = dataDir)
}
