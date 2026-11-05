package app.amber.ai.provider.openai

import io.ktor.client.HttpClient

/** Lets a JVM host own transport policy without changing the Darwin/Swift defaults. */
fun openAIProviderWithClient(client: HttpClient): OpenAIKmpProvider = OpenAIKmpProvider(client, client)
