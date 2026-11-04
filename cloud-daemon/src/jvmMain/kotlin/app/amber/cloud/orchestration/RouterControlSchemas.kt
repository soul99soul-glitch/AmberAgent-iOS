package app.amber.cloud.orchestration

import app.amber.cloud.runtime.CloudToolRegistry
import app.amber.cloud.tasks.schema

internal object RouterControlSchemas {
    fun apply(registry:CloudToolRegistry) {
        val session="\"session_id\":{\"type\":\"string\"}"
        val schemas=mapOf(
            "dispatch_work" to schema("""{"tasks":{"type":"array","items":{"type":"object","properties":{"task_key":{"type":"string"},"title":{"type":"string"},"brief":{"type":"string"},"thread_keys":{"type":"array","items":{"type":"string"}}},"required":["task_key","title","brief"]}}}""","tasks"),
            "steer_worker" to schema("""{"work_item_id":{"type":"string"},"instruction":{"type":"string"}}""","work_item_id","instruction"),
            "cancel_work_item" to schema("""{"work_item_id":{"type":"string"}}""","work_item_id"),
            "async_tool_stop" to schema("""{"handle_id":{"type":"string"}}""","handle_id"),
            "read_worker_session" to schema("{$session,\"cursor\":{\"type\":\"string\"}}","session_id"),
            "read_worker_message_slice" to schema("{$session,\"message_index\":{\"type\":\"integer\"},\"message_id\":{\"type\":\"string\"},\"message_version\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"}}","session_id","message_index","message_id","message_version"),
            "diagnose_worker_session" to schema("{$session}","session_id"),
            "recall_object" to schema("""{"kind":{"type":"string"},"id":{"type":"string"}}""","kind","id"),
            "propose_agent" to schema("""{"profile":{"type":"object"}}""","profile"),
            "agent_soul_get" to schema("""{}"""),
            "agent_soul_update" to schema("""{"display_name":{"type":"string","description":"称呼或名字，如 赵匡胤 / 赵大哥"},"tagline":{"type":"string","description":"一句话个性签名"},"soul_markdown":{"type":"string","description":"完整角色人设、性格、背景与口吻设定（Markdown）"},"reset_to_default":{"type":"boolean","description":"为 true 时恢复默认 Amber 形象人设"}}"""),
        )
        schemas.forEach {(name,s)->registry.get(name)?.let {registry.register(it.copy(parameters=s))}}
    }
}
