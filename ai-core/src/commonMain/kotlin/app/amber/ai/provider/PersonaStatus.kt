package app.amber.ai.provider

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Keep the session model's identity and credentials, without invoking its hosted tools. */
fun Model.personaStatusParams(headers: List<CustomHeader>): TextGenerationParams =
    TextGenerationParams(model = copy(tools = emptySet()), maxTokens = 24, customHeaders = headers)

/** A one-shot native provider operation. All calls are confined to the UI dispatcher. */
interface PersonaStatusRequest {
    fun start(prompt: String, reply: PersonaStatusReply)
    fun cancel()
    fun publish(phrase: String?)
}

class PersonaStatusReply internal constructor(private val result: CompletableDeferred<String?>) {
    fun submit(raw: String?) { result.complete(raw) }
}

/** Scoped to one run. Replacing a request keeps its visible word until the next result. */
class PersonaStatusController internal constructor(
    private val scope: CoroutineScope,
    private val debounceMs: Long,
    private val timeoutMs: Long,
) {
    constructor() : this(CoroutineScope(Dispatchers.Main.immediate), 150, 2500)

    private var job: Job? = null

    fun refresh(
        assistant: String, persona: String, recent: List<String>, latest: String,
        isAddition: Boolean, request: PersonaStatusRequest,
    ) {
        clear()
        job = scope.launch {
            if (isAddition) delay(debounceMs)
            val prompt = buildString {
                appendLine("以助手的人设、最新用户消息和对话语言，写一句此刻正做什么的口语状态。只输出2至8个汉字或24字符以内的英文短语，例如「在哄着呢」「理理思路」。")
                appendLine("助手：${assistant.take(80)}")
                appendLine("人设：${persona.take(300)}")
                recent.takeLast(4).forEach { appendLine(it.take(160)) }
                append(if (isAddition) "用户刚刚追加：" else "最新用户消息：")
                append(latest)
            }
            val result = CompletableDeferred<String?>()
            val raw = try {
                withTimeoutOrNull(timeoutMs) {
                    request.start(prompt, PersonaStatusReply(result))
                    result.await()
                }
            } finally {
                result.cancel()
                request.cancel()
            }
            request.publish(cleanPersonaStatus(raw))
        }
    }

    fun clear() {
        job?.cancel()
        job = null
    }
}

private val hanPhrase = Regex("[㐀-䶿一-鿿]{2,8}")
private val englishPhrase = Regex("[A-Za-z]+(?:['’ -][A-Za-z]+)*")
private val edges = " \"'‘’“”「」『』。！？!?.,，…"

internal fun cleanPersonaStatus(raw: String?): String? {
    val phrase = raw?.trim()?.trim { it in edges } ?: return null
    if (phrase in setOf("null", "true", "false")) return null
    return phrase.takeIf {
        hanPhrase.matches(it) || (it.length in 2..24 && englishPhrase.matches(it))
    }
}
