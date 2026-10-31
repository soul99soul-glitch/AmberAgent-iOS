import org.gradle.api.tasks.JavaExec
import org.gradle.jvm.tasks.Jar

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvm()

    sourceSets {
        all {
            languageSettings.optIn("kotlin.time.ExperimentalTime")
            languageSettings.optIn("kotlin.uuid.ExperimentalUuidApi")
        }

        val jvmMain by getting {
            dependencies {
                api(project(":cloud-channels"))
                api(project(":cloud-proactive"))
                implementation(project(":ai-core"))
                implementation(project(":ai-provider-claude"))
                implementation(project(":ai-provider-openai"))
                implementation(project(":core:agent-runtime"))
                implementation(project(":core:conversation-storage"))
                implementation(project(":core:native"))
                implementation(project(":core:memory:api"))
                implementation(project(":core:context:api"))
                implementation(project(":core:types"))
                implementation(project(":core:agent-utils"))
                implementation(libs.kotlinx.coroutines.core)
                implementation(libs.kotlinx.serialization.json)
                implementation(libs.kotlinx.datetime)
                implementation(libs.ktor.client.core)
                implementation(libs.ktor.client.okhttp)
                implementation(libs.ktor.client.content.negotiation)
                implementation(libs.ktor.serialization.kotlinx.json)
                implementation("io.ktor:ktor-server-core-jvm:${libs.versions.ktor.get()}")
                implementation("io.ktor:ktor-server-cio-jvm:${libs.versions.ktor.get()}")
                implementation("io.ktor:ktor-server-netty-jvm:${libs.versions.ktor.get()}")
                implementation("io.ktor:ktor-server-content-negotiation-jvm:${libs.versions.ktor.get()}")
            }
        }

        val jvmTest by getting {
            dependencies {
                implementation(kotlin("test"))
                implementation(kotlin("test-junit"))
                implementation(libs.junit)
                implementation(libs.kotlinx.coroutines.test)
                implementation("io.ktor:ktor-server-test-host-jvm:${libs.versions.ktor.get()}")
            }
        }
    }
}

tasks.register<JavaExec>("run") {
    group = "application"
    description = "Run amberd cloud daemon"
    val jvmCompilation = kotlin.jvm().compilations.getByName("main")
    classpath(jvmCompilation.output.allOutputs, jvmCompilation.runtimeDependencyFiles)
    mainClass.set("app.amber.cloud.MainKt")
}

tasks.register<JavaExec>("runCli") {
    group = "application"
    description = "Run amber-cli management tool"
    val jvmCompilation = kotlin.jvm().compilations.getByName("main")
    classpath(jvmCompilation.output.allOutputs, jvmCompilation.runtimeDependencyFiles)
    mainClass.set("app.amber.cloud.CliMainKt")
}

tasks.register<Jar>("fatJar") {
    group = "build"
    description = "Assembles a runnable fat JAR for amberd and amber-cli"
    archiveBaseName.set("amberd")
    archiveClassifier.set("all")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    manifest {
        attributes["Main-Class"] = "app.amber.cloud.MainKt"
    }
    val jvmCompilation = kotlin.jvm().compilations.getByName("main")
    from(jvmCompilation.output.allOutputs)
    from({
        jvmCompilation.runtimeDependencyFiles
            .filter { it.name.endsWith(".jar") }
            .map { zipTree(it) }
    })
}
