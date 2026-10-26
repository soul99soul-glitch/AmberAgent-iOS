plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvm()
    macosArm64 {
        binaries.framework {
            baseName = "Shared"
            isStatic = false
            export(project(":ai-core"))
            export(project(":ai-provider-openai"))
            export(project(":ai-provider-claude"))
            export(project(":core:types"))
            export(project(":core:conversation-storage"))
            export(project(":core:agent-runtime"))
            export(project(":core:agent-utils"))
            export(project(":feature:tools:api"))
        }
    }

    compilerOptions {
        optIn.add("kotlin.uuid.ExperimentalUuidApi")
    }

    sourceSets {
        commonMain {
            kotlin.srcDir("../shared/src/commonMain/kotlin")
            kotlin.include("desktop/**", "shared/GeminiWireToolMapper.kt", "shared/IosRuntimeJsonBridges.kt")
        }
        commonMain.dependencies {
            api(project(":ai-core"))
            api(project(":ai-provider-openai"))
            api(project(":ai-provider-claude"))
            api(project(":core:types"))
            api(project(":core:conversation-storage"))
            api(project(":core:agent-runtime"))
            api(project(":core:agent-utils"))
            api(project(":feature:tools:api"))
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
