package app.amber.cloud

import app.amber.cloud.tasks.*
import app.amber.cloud.runtime.*
import app.amber.cloud.security.EnvelopeCredentialVault
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import java.io.File
import kotlin.test.*

/** Opt-in only: uses public free search and dedicated build/tool-acceptance downloads, never global packages or real media. */
class TaskExternalAcceptanceTest {
    @Test fun freeSearchAndManagedMediaTools()=runBlocking {
        if(System.getenv("AMBER_TEST_PUBLIC_TOOLS")!="1")return@runBlocking
        val root=File("build/tool-acceptance").canonicalFile.also {it.mkdirs()}
        // This Mac uses a TUN fake-IP DNS range, which production correctly blocks. Resolve public A records
        // in this opt-in test without changing the machine DNS or weakening the connection gate.
        val http=PublicHttp(resolver={ host ->
            val process=ProcessBuilder("/usr/bin/curl","--fail","--max-time","15","-s","https://dns.google/resolve?name=$host&type=A").start()
            val text=process.inputStream.bufferedReader().readText();check(process.waitFor()==0)
            Json.parseToJsonElement(text).jsonObject["Answer"]?.jsonArray.orEmpty().mapNotNull { r ->
                val item=r.jsonObject;if(item["type"]?.jsonPrimitive?.intOrNull==1)java.net.InetAddress.getByName(item["data"]!!.jsonPrimitive.content)else null
            }
        });val p=TaskProcessRunner(File(root,"toolchain").also {it.mkdirs()});val w=TaskWorkspace(File(root,"tasks"),p);val manager=TaskToolchain(http,p,w)
        val id="work:"+"c".repeat(24)
        if(System.getenv("AMBER_TEST_STAGE").isNullOrBlank()) {
        val search=CloudSearch(http,EnvelopeCredentialVault(File(root,"stub-secrets.enc"),masterSecretOverride="external-acceptance"))
        val results=search.search(buildJsonObject {put("query","Python csv documentation");put("mode","aggregate");put("count",3)})
        File(root,"free-search.json").writeText(Json.encodeToString(SearchResults.serializer(),results));assertTrue(results.results.isNotEmpty(),results.toString())
        File(root,"install-ffmpeg.json").writeText(manager.install("ffmpeg").toString())
        }
        if(System.getenv("AMBER_TEST_STAGE")!="execute") File(root,"install-ytdlp.json").writeText(manager.install("yt-dlp",true).toString())
        assertTrue(manager.install("ffmpeg")["reused"]!!.jsonPrimitive.boolean)
        val registry=CloudToolRegistry();manager.register(registry)
        val context=TaskCallContext(id,"main","fixture-session",registry.registeredToolNames())
        suspend fun cli(name:String,args:List<String>):TaskProcessResult {
            val result=registry.executeGate("toolchain_run",buildJsonObject {put("name",name);put("args",buildJsonArray {args.forEach {add(it)}})},ExecutionScope.SUBAGENT,context)
            return Json.decodeFromJsonElement(TaskProcessResult.serializer(),result)
        }
        val synth=cli("ffmpeg",listOf("-v","error","-f","lavfi","-i","sine=frequency=440:duration=0.2","-y","tone.wav"))
        assertEquals(0,synth.exitCode,synth.stderr)
        val metadata=cli("ffprobe",listOf("-v","quiet","-show_format","-of","json","tone.wav"));assertEquals(0,metadata.exitCode,metadata.stderr);assertContains(metadata.stdout,"duration")
        val taskDir=w.directory(id).canonicalPath
        w.operation(id,"write",buildJsonObject {put("path","fixture.html");put("content","<html><title>Controlled media fixture</title><video src=\"file://$taskDir/tone.wav\"></video></html>")})
        val yt=cli("yt-dlp",listOf("--ignore-config","--no-plugin-dirs","--enable-file-urls","--skip-download","--dump-json","file://$taskDir/fixture.html"))
        assertEquals(0,yt.exitCode,yt.stderr);assertContains(yt.stdout,"tone.wav")
        File(root,"execution-evidence.json").writeText(buildJsonObject {put("ffmpeg",Json.encodeToJsonElement(TaskProcessResult.serializer(),synth));put("ffprobe",Json.encodeToJsonElement(TaskProcessResult.serializer(),metadata));put("yt-dlp",Json.encodeToJsonElement(TaskProcessResult.serializer(),yt));put("artifact",Json.encodeToJsonElement(TaskArtifact.serializer(),w.artifact(id,"tone.wav")))}.toString())
    }
}
