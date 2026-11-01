package app.amber.cloud

import app.amber.cloud.tasks.*
import app.amber.cloud.runtime.*
import app.amber.cloud.security.EnvelopeCredentialVault
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlin.test.*

class SearchNetworkTest {
    @Test fun nativeSearchProtocolsAggregationDiagnosticsAndSafeHttp()=runBlocking {
        val calls=CopyOnWriteArrayList<String>();val executor=Executors.newCachedThreadPool()
        val server=HttpServer.create(InetSocketAddress("127.0.0.1",0),0).apply {this.executor=executor}
        server.createContext("/") {e->
            val body=e.requestBody.bufferedReader().readText();calls+=e.requestURI.toString()+" "+body
            var code=200
            val text=when(e.requestURI.path) {
                "/exa"->{assertEquals("fake-exa",e.requestHeaders.getFirst("x-api-key"));assertContains(body,"includeDomains");"""{"results":[{"title":"Exa title","url":"https://example.com/Case?q=A","highlights":["longer evidence"],"images":["https://example.com/img.jpg"]}]}"""}
                "/brave"->{assertEquals("fake-brave",e.requestHeaders.getFirst("X-Subscription-Token"));assertContains(e.requestURI.query,"freshness=pw");"""{"web":{"results":[{"title":"Brave title","url":"https://www.example.com/Case?q=A","description":"snippet","thumbnail":{"src":"https://example.com/brave.jpg"}}]}}"""}
                "/bing"->"<rss><channel><item><title>Free</title><link>https://example.com/free</link><description>free snippet</description></item></channel></rss>"
                "/empty"->"<rss><channel/></rss>"
                "/rate"->{code=429;"rate limit"}
                "/redirect"->{code=302;e.responseHeaders.add("Location","http://169.254.169.254/latest/meta-data/");""}
                "/slow"->{Thread.sleep(2000);"late"}
                else->"<html><title>Fixture</title><main><p>Readable body</p></main></html>"
            }
            val bytes=text.toByteArray();e.sendResponseHeaders(code,bytes.size.toLong());runCatching {e.responseBody.use {it.write(bytes)}};e.close()
        };server.start()
        try {
            val origin="http://127.0.0.1:${server.address.port}";val http=PublicHttp(origin)
            val dir=Files.createTempDirectory("search-fixture").toFile();val vault=EnvelopeCredentialVault(dir.resolve("secrets.enc.json"),masterSecretOverride="fixture")
            vault.putSecret("search.exa_key","fake-exa");vault.putSecret("search.brave_key","fake-brave")
            val processes=TaskProcessRunner(dir.resolve("tools").also {it.mkdirs()})
            val workspace=TaskWorkspace(dir.resolve("tasks"),processes)
            val registry=CloudToolRegistry()
            val context=TaskCallContext("work:"+"d".repeat(24),"main","fixture",setOf("search_web","download_file","scrape_web","toolchain_run","toolchain_install"))
            TaskNetworkTools(http,workspace).register(registry)
            TaskToolchain(http,processes,workspace).register(registry)
            val downloaded=registry.executeGate("download_file",buildJsonObject {put("url","$origin/page");put("path","page.html")},ExecutionScope.SUBAGENT,context)
            assertTrue(downloaded.jsonObject.string("sha256").length==64)
            assertContains(workspace.bytes(context.workItemId,"page.html").toString(Charsets.UTF_8),"Readable body")
            val scraped=registry.executeGate("scrape_web",buildJsonObject {put("url","$origin/page")},ExecutionScope.SUBAGENT,context)
            assertContains(scraped.toString(),"Readable body")
            registry.capabilities.setEnabled("workspace_files",false)
            assertFails {registry.executeGate("download_file",buildJsonObject {put("url","$origin/page");put("path","no-write")},ExecutionScope.SUBAGENT,context)}
            registry.capabilities.setEnabled("workspace_files",true)
            registry.capabilities.setEnabled("terminal",false)
            assertContains(registry.executeGate("toolchain_install",buildJsonObject {put("name","ffmpeg")},ExecutionScope.SUBAGENT,context).toString(),"能力未启用")
            registry.capabilities.setEnabled("terminal",true)
            calls.clear()
            val search=CloudSearch(http,vault,listOf("bing","exa","brave"),"aggregate",mapOf("bing" to "$origin/bing","exa" to "$origin/exa","brave" to "$origin/brave"),workspace=workspace)
            search.register(registry)
            val resultJson=registry.executeGate("search_web",Json.parseToJsonElement("""{"query":"fixture","exa":{"includeDomains":["example.com"]},"brave":{"freshness":"pw"}}""").jsonObject,ExecutionScope.SUBAGENT,context)
            val result=Json {ignoreUnknownKeys=true}.decodeFromJsonElement(SearchResults.serializer(),resultJson)
            assertContains(workspace.bytes(context.workItemId,"search-results.json").toString(Charsets.UTF_8),"img.jpg")
            assertEquals(2,result.results.size);assertEquals(setOf("exa","brave"),result.results.last().sources.toSet());assertEquals(2,result.results.last().images.size)
            assertTrue(result.sources.all {it.status=="ok"});assertEquals(3,calls.size)
            val fallback=CloudSearch(http,vault,listOf("bing","brave"),"fallback",mapOf("bing" to "$origin/empty","brave" to "$origin/rate"))
            val failed=fallback.search(buildJsonObject {put("query","nothing")})
            assertEquals(listOf("empty","rate_limited"),failed.sources.map {it.status})
            val missing=CloudSearch(http,EnvelopeCredentialVault(dir.resolve("none.enc"),masterSecretOverride="fixture"),listOf("exa"))
            assertEquals("missing_key",missing.search(buildJsonObject {put("query","x")}).sources.single().status)
            assertFails {http.request("$origin/redirect")}
            for(ip in listOf("127.0.0.1","169.254.169.254","10.0.0.1","100.100.100.200","::1","fd00::1"))assertFalse(PublicHttp.publicAddress(InetAddress.getByName(ip)),ip)
            registry.capabilities.setEnabled("network_tools",false)
            assertContains(registry.executeGate("search_web",buildJsonObject {put("query","x")},ExecutionScope.SUBAGENT,context).toString(),"能力未启用")
            assertFails {PublicHttp().request("http://127.0.0.1/")}
            assertFails {http.validate("https://secret:password@example.com/")}
            val job=launch {http.request("$origin/slow")};delay(100);job.cancelAndJoin();assertTrue(job.isCancelled)
        }finally{server.stop(0);executor.shutdownNow()}
    }
    private fun JsonObject.string(key:String)=getValue(key).jsonPrimitive.content
}
