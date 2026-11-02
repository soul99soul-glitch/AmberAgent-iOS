package app.amber.cloud.tasks

import app.amber.cloud.runtime.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import org.jsoup.Jsoup
import java.io.File
import java.security.MessageDigest
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.zip.ZipInputStream

/** Only named, fixed publisher distributions can be installed, never model-provided URLs/packages/commands. */
class TaskToolchain(private val http:PublicHttp,private val processes:TaskProcessRunner,private val workspace:TaskWorkspace) {
    private val root=processes.toolsRoot
    private val mutex=Mutex()
    private val mac=System.getProperty("os.name").contains("Mac")
    private val arm=System.getProperty("os.arch") in setOf("aarch64","arm64")
    private val toolPython = if(mac && File("/opt/homebrew/bin/python3").canExecute()) "/opt/homebrew/bin/python3" else processes.python
    private val names=setOf("ffmpeg","ffprobe","yt-dlp")
    private fun installed(name:String)=File(root,"$name/current").takeIf {it.canExecute()}
    private fun binary(name:String):File?=installed(name)?:listOf("/usr/bin","/bin","/usr/local/bin","/opt/homebrew/bin").map {File(it,name)}.firstOrNull {it.canExecute()}
    private suspend fun probe(name:String,file:File,pythonZip:Boolean=false):String = trusted((if(pythonZip)listOf(toolPython,file.absolutePath)else listOf(file.absolutePath))+if(name=="yt-dlp")listOf("--ignore-config","--no-plugin-dirs","--version")else listOf("-version"),root).lineSequence().first().take(400)
    suspend fun status():JsonArray=buildJsonArray {for(name in names) {
        val f=binary(name);add(buildJsonObject {put("name",name);put("installed",f!=null);if(f!=null) {
            put("path",f.absolutePath);put("managed",installed(name)!=null)
            try {put("version",probe(name,f,name=="yt-dlp"&&installed(name)!=null))}catch(e:CancellationException){throw e}catch(e:Exception){put("error",e.message?.take(300))}
        }})
    }}
    suspend fun install(name:String,update:Boolean=false):JsonObject=mutex.withLock {
        require(name in setOf("ffmpeg","yt-dlp")) {"仅支持ffmpeg（含ffprobe）和yt-dlp"}
        if(!update && binary(name)!=null)return@withLock buildJsonObject {put("reused",true);put("tools",status())}
        val stage=Files.createTempDirectory(root.toPath(),"install-").toFile()
        try {
            val source=if(name=="yt-dlp")installYtDlp(stage)else if(mac)installMacFfmpeg(stage)else installLinuxFfmpeg(stage)
            val tools=if(name=="ffmpeg")listOf("ffmpeg","ffprobe")else listOf("yt-dlp")
            // Validate every executable before publishing any current pointer. Old versions remain available for rollback.
            val versions=tools.associateWith {probe(it,File(stage,it),it=="yt-dlp")}
            for(tool in tools) {
                val dir=File(root,tool).also {it.mkdirs()};val data=File(stage,tool).readBytes();val hash=sha(data)
                val version=File(dir,hash).also {if(!it.exists()){it.writeBytes(data);it.setExecutable(true,true)}}
                val pending=File(dir,"current.new");Files.copy(version.toPath(),pending.toPath(),StandardCopyOption.REPLACE_EXISTING);pending.setExecutable(true,true)
                Files.move(pending.toPath(),File(dir,"current").toPath(),StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE)
                File(dir,"manifest.json").writeText(buildJsonObject {put("source",source);put("sha256",hash);put("version",versions.getValue(tool));put("installedAt",java.time.Instant.now().toString())}.toString())
            }
            buildJsonObject {put("reused",false);put("source",source);put("tools",status())}
        } finally {stage.deleteRecursively()}
    }
    private suspend fun bytes(url:String,max:Int=200_000_000):ByteArray=http.request(url,maxBytes=max).also {require(it.status in 200..299) {"安装下载HTTP ${it.status}"}}.bytes
    private fun checked(data:ByteArray,manifest:String,name:String):ByteArray {
        val expected=manifest.lineSequence().map {it.trim().split(Regex("\\s+"),limit=2)}.firstOrNull {it.size==2&&it[1].removePrefix("*").removePrefix("./")==name}?.first()
            ?:manifest.trim().takeIf {Regex("[a-fA-F0-9]{64}").matches(it)} ?:error("校验清单缺少 $name")
        require(sha(data).equals(expected,true)) {"SHA256不匹配"};return data
    }
    private suspend fun installYtDlp(stage:File):String {
        val release=Json.parseToJsonElement(bytes("https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest",2_000_000).toString(Charsets.UTF_8)).jsonObject.string("tag_name")
        require(Regex("[0-9.]+").matches(release)) {"无效发布版本"}
        val name="yt-dlp" // Official portable Python zip distribution; Python >=3.10 is required, no pip/venv.
        val base="https://github.com/yt-dlp/yt-dlp/releases/download/$release"
        File(stage,"yt-dlp").apply {writeBytes(checked(bytes("$base/$name"),bytes("$base/SHA2-256SUMS",100_000).toString(Charsets.UTF_8),name));setExecutable(true,true)}
        return "$base/$name"
    }
    private suspend fun installLinuxFfmpeg(stage:File):String {
        require(System.getProperty("os.name").contains("Linux")) {"不支持此OS"}
        val platform=if(arm)"linuxarm64"else if(System.getProperty("os.arch")=="amd64")"linux64"else error("不支持此架构")
        val release=Json.parseToJsonElement(bytes("https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest",3_000_000).toString(Charsets.UTF_8)).jsonObject
        val assets=release.getValue("assets").jsonArray.map {it.jsonObject}
        val asset=assets.sortedByDescending { it.string("name").substringAfter("ffmpeg-n", "0").substringBefore("-latest").split('.').take(3).fold(0) { n,v -> n*100+(v.toIntOrNull()?:0) } }.firstOrNull {it.string("name").matches(Regex("ffmpeg-n[0-9.]+-latest-$platform-lgpl-[0-9.]+\\.tar\\.xz"))}?:error("未找到平台静态LGPL发行包")
        val name=asset.string("name");val url=asset.string("browser_download_url")
        require(url.startsWith("https://github.com/BtbN/FFmpeg-Builds/releases/download/"))
        val checksum=assets.first {it.string("name")=="checksums.sha256"}.string("browser_download_url")
        require(checksum.startsWith("https://github.com/BtbN/FFmpeg-Builds/releases/download/"))
        File(stage,"archive.tar.xz").writeBytes(checked(bytes(url),bytes(checksum,300_000).toString(Charsets.UTF_8),name))
        // Select regular binary members only; never extract archive paths, links or scripts.
        val unpack="import tarfile,shutil,os\nt=tarfile.open('archive.tar.xz')\nfor m in t:\n n=m.name.rsplit('/',1)[-1]\n if m.isfile() and n in ('ffmpeg','ffprobe'):\n  assert m.size<400000000\n  with t.extractfile(m) as src,open(n,'wb') as dst:shutil.copyfileobj(src,dst)\n  os.chmod(n,0o700)"
        trusted(listOf(processes.python,"-c",unpack),stage)
        return url
    }
    private suspend fun installMacFfmpeg(stage:File):String {
        val platform=if(arm)"arm64"else "amd64"
        val base="https://ffmpeg.martin-riedl.de"
        val doc=Jsoup.parse(bytes("$base/",2_000_000).toString(Charsets.UTF_8),base)
        // Release version URLs contain _<version>; nightly URLs use a different suffix.
        val urls=doc.select("a[href]").map {it.absUrl("href")}.filter {it.matches(Regex("https://ffmpeg\\.martin-riedl\\.de/download/macos/$platform/[0-9]+_[0-9.]+/ffmpeg\\.zip"))}
        val ffmpeg=urls.firstOrNull()?:error("未找到macOS发行包")
        for(tool in listOf("ffmpeg","ffprobe")) {
            val url=ffmpeg.substringBeforeLast('/')+"/$tool.zip"
            val zip=checked(bytes(url),bytes("$url.sha256",10000).toString(Charsets.UTF_8),"$tool.zip")
            ZipInputStream(zip.inputStream()).use {stream->var found=false;while(true){val e=stream.nextEntry?:break
                if(!e.isDirectory&&e.name.substringAfterLast('/')==tool){File(stage,tool).outputStream().use {out->val buf=ByteArray(8192);var total=0;while(true){val n=stream.read(buf);if(n<0)break;total+=n;require(total<=300_000_000);out.write(buf,0,n)}};found=true;break}
            };require(found){"发行包缺少$tool"}}
            File(stage,tool).setExecutable(true,true)
        }
        return ffmpeg
    }
    private suspend fun trusted(args:List<String>,dir:File):String=withContext(Dispatchers.IO) {
        val p=ProcessBuilder(args).directory(dir).redirectErrorStream(true).apply {environment().clear();environment().putAll(mapOf("PATH" to "/usr/bin:/bin","HOME" to dir.absolutePath,"TMPDIR" to dir.absolutePath))}.start()
        coroutineScope {
            val output=async(Dispatchers.IO) {p.inputStream.bufferedReader().use {it.readText().take(100_000)}}
            try {
                withTimeout(30_000) {while(p.isAlive)delay(30)}
                val text=output.await()
                require(p.exitValue()==0){"工具安装/探测失败(exit=${p.exitValue()}): ${text.take(1000)}"}
                text
            } finally {
                p.descendants().forEach {it.destroyForcibly()}
                if(p.isAlive)p.destroyForcibly()
                output.cancel()
            }
        }
    }
    fun register(registry:CloudToolRegistry) {
        fun register(name:String,description:String,s:app.amber.ai.core.InputSchema,handler:suspend(JsonObject,TaskCallContext)->JsonElement)=registry.register(CloudToolDefinition(name,description,false,ToolEffect.TASK_LOCAL,requiredCapability=if(name=="toolchain_status")null else "terminal",parameters=s,taskHandler=handler))
        register("toolchain_status","检测ffmpeg/ffprobe/yt-dlp实际路径与版本；managed表示专用目录",schema()){_,_->status()}
        register("toolchain_install","按任务需要安装/更新ffmpeg（含ffprobe）或yt-dlp；固定平台发行源+SHA256，专用目录，不sudo/不改全局包；默认复用已安装项",schema("""{"name":{"type":"string","enum":["ffmpeg","yt-dlp"]},"update":{"type":"boolean"}}""","name")){a,_->install(a.string("name"),a["update"]?.jsonPrimitive?.booleanOrNull==true)}
        register("toolchain_run","在任务OS隔离内真实调用已安装CLI。脚本网络关闭；先用download_file下载公开媒体再本地处理。yt-dlp可处理任务内file fixture，不代表已支持真实站点",schema("""{"name":{"type":"string","enum":["ffmpeg","ffprobe","yt-dlp"]},"args":{"type":"array","items":{"type":"string"}},"timeoutSeconds":{"type":"integer","minimum":1,"maximum":600}}""","name","args")){a,c->
            val name=a.string("name");require(name in names);val file=binary(name)?:throw TaskCapabilityUnavailable("缺少$name，请调用toolchain_install")
            val args=(if(name=="yt-dlp")listOf("--ignore-config","--no-plugin-dirs","--cache-dir",".cache/yt-dlp")else emptyList())+a.strings("args")
            Json.encodeToJsonElement(processes.run(c.workItemId,workspace.directory(c.workItemId),(if(name=="yt-dlp"&&installed(name)!=null)listOf(toolPython,file.absolutePath)else listOf(file.absolutePath))+args,a.number("timeoutSeconds",60)))
        }
    }
    private fun sha(data:ByteArray)=MessageDigest.getInstance("SHA-256").digest(data).joinToString(""){"%02x".format(it)}
}
