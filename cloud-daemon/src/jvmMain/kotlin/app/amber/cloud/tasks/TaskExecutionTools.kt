package app.amber.cloud.tasks

import app.amber.ai.core.InputSchema
import app.amber.cloud.runtime.*
import kotlinx.serialization.json.*
import java.io.File

internal fun schema(properties: String = "{}", vararg required: String) = InputSchema.Obj(
    properties = Json.parseToJsonElement(properties).jsonObject, required = required.toList(),
)
internal fun JsonObject.string(key: String) = this[key]?.jsonPrimitive?.contentOrNull.orEmpty()
internal fun JsonObject.number(key: String, default: Int) = this[key]?.jsonPrimitive?.intOrNull ?: default
internal fun JsonObject.strings(key: String) = this[key]?.jsonArray?.map { it.jsonPrimitive.content }.orEmpty()

class TaskExecutionTools(val workspace: TaskWorkspace, val processes: TaskProcessRunner) {
    private val json = Json { encodeDefaults = true }
    fun register(registry: CloudToolRegistry) {
        fun register(name: String, description: String, parameters: InputSchema, capability: String? = null,
                     action: suspend (JsonObject, TaskCallContext) -> JsonElement) {
            registry.register(CloudToolDefinition(name, description, false, ToolEffect.TASK_LOCAL, capability, parameters, action))
        }
        val path = "\"path\":{\"type\":\"string\",\"description\":\"当前任务目录内的相对路径\"}"
        register("workspace_file_list", "列举当前任务文件（最多200个，深度8）", schema(), "workspace_files") { _, c -> workspace.operation(c.workItemId,"list") }
        register("workspace_file_read", "读取当前任务UTF-8文件", schema("{$path,\"maxChars\":{\"type\":\"integer\"}}", "path"), "workspace_files") { a,c -> workspace.operation(c.workItemId,"read",a) }
        register("workspace_file_write", "真实写入当前任务文件；不会写入宿主或其他任务", schema("{$path,\"content\":{\"type\":\"string\"}}", "path","content"), "workspace_files") { a,c -> workspace.operation(c.workItemId,"write",a) }
        register("workspace_file_edit", "精确替换一次；old必须唯一匹配", schema("{$path,\"old\":{\"type\":\"string\"},\"replacement\":{\"type\":\"string\"}}", "path","old","replacement"), "workspace_files") { a,c -> workspace.operation(c.workItemId,"edit",a) }
        register("workspace_file_search", "搜索当前任务UTF-8文件内容", schema("{\"query\":{\"type\":\"string\"}}", "query"), "workspace_files") { a,c -> workspace.operation(c.workItemId,"search",a) }
        val command = schema("""{"argv":{"type":"array","items":{"type":"string"},"description":"直接argv，例如[\"/usr/bin/python3\",\"script.py\"]或[\"/bin/sh\",\"-c\",\"...\"]"},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":600},"background":{"type":"boolean"}}""", "argv")
        register("process_run", "在强制OS隔离内真实执行，默认后台立即返回id；完成事件自动投回任务。仅当前任务目录可写、无网络/凭据。exitCode=0才成功，后台用process_wait/stop；宿主管理不在此权限内", command, "terminal") { a,c ->
            val argv = a.strings("argv"); val timeout=a.number("timeoutSeconds",60)
            if (a["background"]?.jsonPrimitive?.booleanOrNull != false) buildJsonObject { put("id",processes.start(c.workItemId,workspace.directory(c.workItemId),argv,timeout,notify=true));put("state","running") }
            else json.encodeToJsonElement(processes.run(c.workItemId,workspace.directory(c.workItemId),argv,timeout))
        }
        register("process_wait", "查询当前任务后台进程及真实退出码/输出", schema("""{"id":{"type":"string"},"seconds":{"type":"integer","minimum":1,"maximum":60}}""", "id"), "terminal") { a,c -> json.encodeToJsonElement(processes.wait(c.workItemId,a.string("id"),a.number("seconds",30))) }
        register("process_stop", "取消当前任务进程及子进程", schema("""{"id":{"type":"string"}}""", "id"), "terminal") { a,c -> json.encodeToJsonElement(processes.stop(c.workItemId,a.string("id"))) }
        register("host_info", "只读采集本机CPU/内存/磁盘/负载与进程概况；含采样时间，不读环境变量/命令参数/凭据", schema()) { _,_ -> hostInfo() }
        register("runtime_info", "检测OS、Python、隔离与任务执行限制；不执行安装", schema()) { _,_ -> buildJsonObject {
            put("os",System.getProperty("os.name"));put("arch",System.getProperty("os.arch"));put("isolation",processes.isolation)
            put("python",processes.python);put("pythonExists",File(processes.python).canExecute());put("networkInScripts",false);put("fileLimitBytes",33554432);put("processTimeoutSeconds",600)
        } }
        register("task_finish", "显式结算：completed=目标已完成且已检查输出；blocked=缺少能力/权限/输入；failed=执行失败。必须给summary，只列实际存在的产物相对路径，结束前等待进程", schema("""{"outcome":{"type":"string","enum":["completed","blocked","failed"]},"summary":{"type":"string"},"artifacts":{"type":"array","items":{"type":"string"}}}""", "outcome","summary")) { a,c ->
            require(a.string("outcome") in setOf("completed","blocked","failed")); require(a.string("summary").isNotBlank())
            require(!processes.active(c.workItemId)) { "尚有执行中进程，请先等待或取消" }
            val artifacts = a.strings("artifacts").map { workspace.artifact(c.workItemId,it) }
            buildJsonObject { put("ok",true);put("outcome",a.string("outcome"));put("summary",a.string("summary"));put("artifacts",json.encodeToJsonElement(artifacts)) }
        }
    }
}
