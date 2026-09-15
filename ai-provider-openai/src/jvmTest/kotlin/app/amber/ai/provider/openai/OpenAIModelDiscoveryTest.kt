package app.amber.ai.provider.openai

import app.amber.ai.provider.ModelType
import app.amber.ai.provider.ProviderSetting
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals

class OpenAIModelDiscoveryTest {
    @Test
    fun apiKeyDiscoveryClassifiesAllOpenAIImageModelPrefixes() = runBlocking {
        val engine = MockEngine {
            respond(
                content = """
                    {"data":[
                      {"id":"gpt-5.4"},
                      {"id":"gpt-image-2.5"},
                      {"id":"gpt-image-2.5-sunburst"},
                      {"id":"gpt-image-2.5-flare"},
                      {"id":"chatgpt-image-2.5"},
                      {"id":"legacy-model"}
                    ]}
                """.trimIndent(),
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, ContentType.Application.Json.toString()),
            )
        }
        val client = HttpClient(engine)
        try {
            val models = OpenAIKmpProvider(client, client).listModelsWithHeadersOrThrow(
                ProviderSetting.OpenAI(
                    apiKey = "sk-test",
                    baseUrl = "https://api.openai.com/v1",
                ),
                emptyList(),
            )

            assertEquals(ModelType.CHAT, models.single { it.modelId == "gpt-5.4" }.type)
            assertEquals(
                setOf(
                    "gpt-image-2.5",
                    "gpt-image-2.5-sunburst",
                    "gpt-image-2.5-flare",
                    "chatgpt-image-2.5",
                ),
                models.filter { it.type == ModelType.IMAGE }.map { it.modelId }.toSet(),
            )
            assertEquals(ModelType.CHAT, models.single { it.modelId == "legacy-model" }.type)
        } finally {
            client.close()
        }
    }
}
