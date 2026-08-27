plugins {
    kotlin("jvm") version "2.4.0"
    application
}

group = "dev.akash.skystream"
version = "0.1.0"

kotlin {
    jvmToolchain(17)
}

repositories {
    google()
    mavenCentral()
    maven("https://jitpack.io")
}

dependencies {
    implementation("com.lagradost.api:library")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.13.1")
}

application {
    mainClass.set("dev.akash.skystream.cloudstream.MainKt")
}

tasks.register<Jar>("fatJar") {
    group = "build"
    description = "Builds a self-contained SkyStream CloudStream backend JAR"
    archiveBaseName.set("skystream-cloudstream-backend")
    archiveClassifier.set("all")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE

    manifest {
        attributes["Main-Class"] = "dev.akash.skystream.cloudstream.MainKt"
    }

    from(sourceSets.main.get().output)
    dependsOn(configurations.runtimeClasspath)
    from({
        configurations.runtimeClasspath.get()
            .filter { it.name.endsWith(".jar") }
            .map { zipTree(it) }
    })

    exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA")
}

tasks.test {
    useJUnitPlatform()
}
