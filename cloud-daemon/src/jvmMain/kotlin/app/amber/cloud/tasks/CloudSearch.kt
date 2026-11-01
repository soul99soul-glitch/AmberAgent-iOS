package app.amber.cloud.tasks

import app.amber.cloud.runtime.*
import app.amber.cloud.security.EnvelopeCredentialVault
import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.jsoup.Jsoup
import org.jsoup.parser.Parser
import java.net.URI

@Serializable data class SearchHit(val title:String,val url:String,val snippet:String,val sources:List<String>,val images:List<String> = emptyList(),val publishedDate:String?=null)
@Serializable data class SearchSourceReport(val source:String,val status:String,val count:Int=0,val httpStatus:Int?=null,val error:String?=null)
@Serializable data class SearchResults(val query:String,val results:List<SearchHit>,val sources:List<SearchSourceReport>)

/** Provider protocols stay native; only the result shape/URL identity is shared across sources. */
class CloudSearch(
    private val http:PublicHttp, private val vault:EnvelopeCredentialVault,
    private val enabled:List<String> = listOf("bing","duckduckgo"), private val defaultMode:String = "fallback",
    private val endpoints:Map<String,String> = emptyMap(),
    private val workspace:TaskWorkspace? = null,
) {
    private val json=Json { ignoreUnknownKeys=true;encodeDefaults=true }
    init {require(enabled.isNotEmpty() && enabled.all {it in setOf("bing","duckduckgo","exa","brave")});require(defaultMode in setOf("fallback","aggregate"))}
    fun register(registry:CloudToolRegistry) {
        registry.register(CloudToolDefinition("search_web","聚合免费搜索和已配置的Exa/Brave；mode=fallback按顺序兜底，aggregate并发。返回来源诊断/标题/URL/摘要/图片；无Key可免费检索。仅可选管理员启用源",false,ToolEffect.NETWORK_READ, requiredCapability="network_tools",
            parameters=schema("""{"query":{"type":"string"},"mode":{"type":"string","enum":["fallback","aggregate"]},"sources":{"type":"array","items":{"type":"string"}},"count":{"type":"integer","minimum":1,"maximum":20},"exa":{"type":"object","description":"原生type/category/includeDomains/excludeDomains/startPublishedDate/endPublishedDate/contents"},"brave":{"type":"object","description":"原生country/search_lang/ui_lang/freshness/safesearch/extra_snippets"}}""","query"),
            taskHandler={a,c ->
                val result=json.encodeToJsonElement(search(a)).jsonObject
                if(workspace==null) result else try {
                    require(registry.capabilities.isEnabled("workspace_files")) {"任务文件能力未启用"}
                    val artifact=workspace.operation(c.workItemId,"write",buildJsonObject {put("path","search-results.json");put("content",result.toString())})
                    JsonObject(result+("artifact" to artifact))
                } catch(e:CancellationException) {throw e} catch(e:Exception) {
                    JsonObject(result+("artifactError" to JsonPrimitive(app.amber.cloud.security.CredentialRedactor.redact(e.message.orEmpty().take(400)))))
                }
            }))
    }
    suspend fun search(args:JsonObject):SearchResults = coroutineScope {
        val query=args.string("query").trim();require(query.isNotEmpty()&&query.length<=600)
        val count=args.number("count",8);require(count in 1..20)
        val requested=args.strings("sources").ifEmpty {enabled};require(requested.all {it in enabled}) {"搜索源未启用"}
        val mode=args.string("mode").ifBlank {defaultMode};require(mode in setOf("fallback","aggregate"))
        suspend fun source(id:String):Pair<List<SearchHit>,SearchSourceReport> {
            val key=if(id in setOf("exa","brave")) vault.getSecret("search.${id}_key") else null
            if(id in setOf("exa","brave") && key.isNullOrBlank())return emptyList<SearchHit>() to SearchSourceReport(id,"missing_key")
            return try {
                val (response,hits)=fetch(id,query,count,args,key)
                val status=when {response.status==429->"rate_limited";response.status !in 200..299->"http_error";hits.isEmpty()->"empty";else->"ok"}
                hits to SearchSourceReport(id,status,hits.size,response.status)
            } catch(e:CancellationException){throw e} catch(e:Exception){emptyList<SearchHit>() to SearchSourceReport(id,"error",error=app.amber.cloud.security.CredentialRedactor.redact("${e.javaClass.simpleName}: ${e.message.orEmpty().take(200)}"))}
        }
        val batches=if(mode=="aggregate")requested.distinct().map {async { source(it) }}.awaitAll() else buildList {
            for(id in requested.distinct()) {val r=source(id);add(r);if(r.first.isNotEmpty())break}
        }
        val merged=linkedMapOf<String,SearchHit>()
        for(hit in batches.flatMap {it.first}) {
            val key=identity(hit.url);val old=merged[key]
            merged[key]=if(old==null)hit else old.copy(snippet=if(old.snippet.length>=hit.snippet.length)old.snippet else hit.snippet,sources=(old.sources+hit.sources).distinct(),images=(old.images+hit.images).distinct())
        }
        SearchResults(query,merged.values.take(count),batches.map {it.second})
    }
    private suspend fun fetch(id:String,q:String,count:Int,args:JsonObject,key:String?):Pair<PublicHttp.Result,List<SearchHit>> {
        val response=when(id) {
            "exa" -> {
                val native=args["exa"]?.jsonObject.orEmpty().filterKeys {it in setOf("type","category","includeDomains","excludeDomains","startPublishedDate","endPublishedDate","contents")}
                val body=JsonObject(native+mapOf("query" to JsonPrimitive(q),"numResults" to JsonPrimitive(count))+if("contents" !in native)mapOf("contents" to buildJsonObject {put("highlights",true)})else emptyMap())
                http.request(endpoints[id]?:"https://api.exa.ai/search","POST",body.toString(),mapOf("x-api-key" to key!!))
            }
            "brave" -> {
                val url=(endpoints[id]?:"https://api.search.brave.com/res/v1/web/search").toHttpUrl().newBuilder().addQueryParameter("q",q).addQueryParameter("count",count.toString())
                args["brave"]?.jsonObject?.filterKeys {it in setOf("country","search_lang","ui_lang","freshness","safesearch","extra_snippets") }?.forEach {(k,v)->url.addQueryParameter(k,v.jsonPrimitive.content)}
                http.request(url.build().toString(),headers=mapOf("X-Subscription-Token" to key!!,"Accept" to "application/json"))
            }
            "bing" -> http.request((endpoints[id]?:"https://www.bing.com/search").toHttpUrl().newBuilder().addQueryParameter("q",q).addQueryParameter("format","rss").build().toString())
            else -> http.request((endpoints[id]?:"https://html.duckduckgo.com/html/").toHttpUrl().newBuilder().addQueryParameter("q",q).build().toString())
        }
        if(response.status !in 200..299)return response to emptyList()
        fun hit(title:String,url:String,snippet:String,images:List<String> = emptyList(),date:String?=null):SearchHit? {
            val parsed=runCatching {url.toHttpUrl()}.getOrNull()?:return null
            if(parsed.scheme !in setOf("http","https")||parsed.username.isNotEmpty()||parsed.password.isNotEmpty())return null
            return SearchHit(title.take(500),url,snippet.take(4000),listOf(id),images.filter {runCatching {it.toHttpUrl()}.isSuccess}.take(10),date)
        }
        val hits=when(id) {
            "exa","brave" -> {
                val root=json.parseToJsonElement(response.text()).jsonObject
                val results=if(id=="exa")root["results"]?.jsonArray else root["web"]?.jsonObject?.get("results")?.jsonArray
                results.orEmpty().mapNotNull {value -> val r=value.jsonObject
                    val snippets=if(id=="exa")listOf(r.string("summary"),r.strings("highlights").joinToString("\n"),r.string("text")) else listOf(r.string("description"),r.strings("extra_snippets").joinToString("\n"))
                    val images=mutableListOf<String>();r["image"]?.jsonPrimitive?.contentOrNull?.let(images::add)
                    r["images"]?.jsonArray?.forEach {i -> if(i is JsonPrimitive)images+=i.content else i.jsonObject["url"]?.jsonPrimitive?.contentOrNull?.let(images::add)}
                    r["thumbnail"]?.jsonObject?.get("src")?.jsonPrimitive?.contentOrNull?.let(images::add)
                    hit(r.string("title"),r.string("url"),snippets.filter {it.isNotBlank()}.joinToString("\n"),images,r["publishedDate"]?.jsonPrimitive?.contentOrNull)
                }
            }
            "bing" -> Jsoup.parse(response.text(),"",Parser.xmlParser()).select("item").mapNotNull {r-> hit(r.selectFirst("title")?.text().orEmpty(),r.selectFirst("link")?.text().orEmpty(),r.selectFirst("description")?.text().orEmpty())}
            else -> Jsoup.parse(response.text(),response.url).select(".result").mapNotNull {r->
                val link=r.selectFirst("a.result__a")?:return@mapNotNull null
                val url=link.absUrl("href");val target=runCatching {url.toHttpUrl().queryParameter("uddg")}.getOrNull()?:url
                hit(link.text(),target,r.selectFirst(".result__snippet")?.text().orEmpty())
            }
        }
        return response to hits.take(count)
    }
    private fun identity(url:String):String = runCatching {val u=URI(url);val host=u.host.lowercase().removePrefix("www.").removePrefix("m.");"$host:${u.port}${u.rawPath.orEmpty().trimEnd('/')}?${u.rawQuery.orEmpty()}"}.getOrDefault(url)
}
