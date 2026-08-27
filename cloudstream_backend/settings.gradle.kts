pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}

rootProject.name = "SkyStreamCloudStreamBackend"

val cloudstreamSource = providers.gradleProperty("cloudstreamSourceDir").orNull
    ?: System.getenv("CLOUDSTREAM_SOURCE_DIR")
    ?: "../.cloudstream-upstream"

includeBuild(cloudstreamSource) {
    dependencySubstitution {
        substitute(module("com.lagradost.api:library")).using(project(":library"))
    }
}
