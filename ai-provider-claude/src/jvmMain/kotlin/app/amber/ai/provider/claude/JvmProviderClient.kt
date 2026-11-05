package app.amber.ai.provider.claude

import io.ktor.client.HttpClient

/** The host supplies a client with SSE installed if it also uses streaming generation. */
fun claudeProviderWithClient(client: HttpClient): ClaudeKmpProvider = ClaudeKmpProvider(client, client)
