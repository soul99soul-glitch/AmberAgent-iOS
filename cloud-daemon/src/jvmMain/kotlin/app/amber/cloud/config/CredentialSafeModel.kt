package app.amber.cloud.config

import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart
import app.amber.cloud.runtime.CloudModelClient
import app.amber.cloud.security.CredentialRedactor
import kotlinx.coroutines.CancellationException

/** A provider may reflect its header in an error. Never carry configured literal keys into logs/history/model messages. */
internal fun credentialSafeModel(delegate: CloudModelClient, credentials: Collection<String?>): CloudModelClient {
    val literals = credentials.filterNotNull().filter(String::isNotBlank).sortedByDescending(String::length)
    fun safe(text: String): String = CredentialRedactor.redact(literals.fold(text) { value, key -> value.replace(key, CredentialRedactor.MASK) })
    fun part(value: UIMessagePart): UIMessagePart = when (value) {
        is UIMessagePart.Text -> value.copy(text = safe(value.text))
        is UIMessagePart.Reasoning -> value.copy(reasoning = safe(value.reasoning))
        is UIMessagePart.Tool -> value.copy(input = safe(value.input), output = value.output.map(::part))
        else -> value
    }
    fun message(value: UIMessage) = value.copy(parts = value.parts.map(::part))
    return CloudModelClient { messages, tools ->
        try { message(delegate.generateReply(messages.map(::message), tools)) }
        catch (e: CancellationException) { throw e }
        catch (e: Exception) { throw IllegalStateException(safe(e.message.orEmpty())) }
    }
}
