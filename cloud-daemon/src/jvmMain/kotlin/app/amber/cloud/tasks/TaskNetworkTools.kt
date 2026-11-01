package app.amber.cloud.tasks

import app.amber.cloud.runtime.*
import kotlinx.serialization.json.*
import org.jsoup.Jsoup

class TaskNetworkTools(private val http: PublicHttp, private val workspace: TaskWorkspace) {
    fun register(registry: CloudToolRegistry) {
        fun tool(name:String,description:String,parameters:app.amber.ai.core.InputSchema,action:suspend(JsonObject,TaskCallContext)->JsonElement) =
            registry.register(CloudToolDefinition(name,description,false,ToolEffect.NETWORK_READ,requiredCapability="network_tools",parameters=parameters,taskHandler=action))
        val urlSchema=schema("""{"url":{"type":"string"},"method":{"type":"string","enum":["GET","HEAD"]}}""","url")
        tool("http_request","请求公网HTTP GET/HEAD，返回状态码和正文；拒绝私网/云元数据/凭据，正文最多2MB",urlSchema) { a,_ ->
            val method=a.string("method").ifBlank { "GET" };require(method in setOf("GET","HEAD"))
            val r=http.request(a.string("url"),method)
            buildJsonObject {put("status",r.status);put("url",r.url);put("contentType",r.contentType);put("text",r.text().take(100_000))}
        }
        tool("scrape_web","读取公网网页正文/标题/链接，页面脚本不会执行",urlSchema) { a,_ ->
            val r=http.request(a.string("url"));require(r.status in 200..299) { "HTTP ${r.status}" }
            val doc=Jsoup.parse(r.text(),r.url);doc.select("script,style,nav,footer,noscript").remove()
            buildJsonObject {put("url",r.url);put("title",doc.title());put("text",doc.selectFirst("article,main")?.text()?.take(60_000) ?:doc.body().text().take(60_000))
                put("links",buildJsonArray {doc.select("a[href]").take(40).forEach {add(it.absUrl("href"))}})}
        }
        tool("download_file","从公网下载到当前任务文件，最多32MiB，返回SHA256和大小",schema("""{"url":{"type":"string"},"path":{"type":"string"}}""","url","path")) { a,c ->
            require(registry.capabilities.isEnabled("workspace_files")) {"任务文件能力未启用"}
            val r=http.request(a.string("url"),maxBytes=32*1024*1024);require(r.status in 200..299) {"HTTP ${r.status}"}
            Json.encodeToJsonElement(workspace.writeBytes(c.workItemId,a.string("path"),r.bytes))
        }
    }
}
