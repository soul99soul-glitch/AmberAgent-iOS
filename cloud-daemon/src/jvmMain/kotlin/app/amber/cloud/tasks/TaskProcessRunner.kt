package app.amber.cloud.tasks

import kotlinx.coroutines.*
import kotlinx.serialization.Serializable
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

@Serializable
data class TaskProcessResult(val id: String, val state: String, val exitCode: Int? = null, val stdout: String = "", val stderr: String = "", val truncated: Boolean = false)

/** OS sandbox is mandatory. Only the task directory is writable; scripts have no network or daemon environment. */
class TaskProcessRunner(val toolsRoot: File, val python: String = if (System.getProperty("os.name").contains("Mac")) "/Library/Developer/CommandLineTools/usr/bin/python3" else "/usr/bin/python3") {
    private data class Running(val owner: String, val process: Process, val result: Deferred<TaskProcessResult>, var stopped: Boolean = false)
    private val jobs = ConcurrentHashMap<String, Running>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycle=Any()
    private val closedTasks=ConcurrentHashMap.newKeySet<String>()
    var inputPending:(String)->Boolean={false}
    var onBackgroundStarted:(String,String,Long,Long)->Unit={_,_,_,_->}
    var onBackgroundFinished:suspend (String,TaskProcessResult)->Unit={_,_->}
    private val mac = System.getProperty("os.name").contains("Mac", true)
    private val bwrap = listOf("/usr/bin/bwrap", "/bin/bwrap").firstOrNull { File(it).canExecute() }
    val isolation get() = if (mac && File("/usr/bin/sandbox-exec").canExecute()) "macOS Seatbelt" else if (bwrap != null) "Linux bubblewrap" else "unavailable"

    fun command(dir: File, args: List<String>): List<String> {
        require(args.isNotEmpty() && args.size <= 100 && args.all { it.length <= 100_000 && '\u0000' !in it })
        if (mac) {
            if (!File("/usr/bin/sandbox-exec").canExecute()) throw TaskCapabilityUnavailable("缺少 sandbox-exec，拒绝裸执行")
            fun quoted(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
            val reads = listOf("/usr", "/bin", "/sbin", "/System/Library", "/Library/Developer", "/private/var/db/dyld", toolsRoot.canonicalPath) + listOfNotNull(File("/opt/homebrew/bin/python3").takeIf { it.exists() }?.canonicalFile?.parentFile?.parentFile?.path)
            val profile = "(version 1)(deny default)(allow process*)(allow file-read* (literal \"/private/etc/apache2/mime.types\"))(allow file-read-metadata)(allow file-read* (regex \"^/opt/homebrew/(Cellar/[^/]+/[^/]+|opt/[^/]+)/lib(/|$)\"))(allow file-read* (literal \"/\"))(allow sysctl-read)(allow signal (target self))" +
                reads.joinToString("") { "(allow file-read* (subpath ${quoted(it)}))" } +
                "(allow file-read* file-write* (subpath ${quoted(dir.canonicalPath)}))(allow file-read* file-write* (literal \"/dev/null\"))(allow file-read* (literal \"/dev/urandom\"))"
            return listOf("/usr/bin/sandbox-exec", "-p", profile) + args
        }
        val binary = bwrap ?: throw TaskCapabilityUnavailable("缺少 bubblewrap；请由管理员配置 bwrap 与非特权 user namespace，拒绝裸执行")
        val cmd = mutableListOf(binary, "--unshare-all", "--die-with-parent", "--new-session", "--cap-drop", "ALL")
        for (path in listOf("/usr", "/bin", "/sbin", "/lib", "/lib64")) if (File(path).exists()) cmd += listOf("--ro-bind", path, path)
        cmd += listOf("--dir", "/etc")
        if (File("/etc/ld.so.cache").exists()) cmd += listOf("--ro-bind", "/etc/ld.so.cache", "/etc/ld.so.cache")
        // Debian-family shared libraries (for example FFmpeg's libblas) resolve through these symlinks.
        if (File("/etc/alternatives").isDirectory) cmd += listOf("--ro-bind", "/etc/alternatives", "/etc/alternatives")
        cmd += listOf("--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--bind", dir.canonicalPath, "/workspace")
        if (toolsRoot.exists()) cmd += listOf("--ro-bind", toolsRoot.canonicalPath, toolsRoot.canonicalPath)
        cmd += listOf("--chdir", "/workspace", "--setenv", "HOME", "/workspace/.home", "--") + args
        return cmd
    }

    suspend fun start(owner: String, dir: File, args: List<String>, timeoutSeconds: Int = 60, stdin: ByteArray = byteArrayOf(), outputLimit: Int = 256_000, notify: Boolean = false, allowClosed:Boolean=false): String = synchronized(lifecycle) {
        require(allowClosed||owner !in closedTasks) {"任务已停止，不能再启动进程"}
        require(timeoutSeconds in 1..600)
        require(jobs.values.count { it.owner == owner && !it.result.isCompleted } < 2) { "每任务最多两个进程" }
        if (jobs.size > 128) jobs.entries.filter { it.value.result.isCompleted }.take(jobs.size - 64).forEach { jobs.remove(it.key) }
        val id = "process:" + UUID.randomUUID()
        File(dir, ".home").mkdirs()
        val launcher = "import os,resource; os.setsid(); resource.setrlimit(resource.RLIMIT_CPU,($timeoutSeconds,$timeoutSeconds)); resource.setrlimit(resource.RLIMIT_NOFILE,(128,128)); resource.setrlimit(resource.RLIMIT_FSIZE,(33554432,33554432)); " + (if (mac) "" else "resource.setrlimit(resource.RLIMIT_AS,(805306368,805306368)); resource.setrlimit(resource.RLIMIT_NPROC,(64,64)); ") + "os.execvp(__import__('sys').argv[1],__import__('sys').argv[1:])"
        val process = ProcessBuilder(command(dir, listOf(python, "-c", launcher) + args)).directory(dir).apply {
            environment().clear(); environment().putAll(mapOf("PATH" to "/usr/bin:/bin:/usr/sbin:/sbin", "HOME" to File(dir,".home").absolutePath,
                "TMPDIR" to if (mac) dir.canonicalPath else "/tmp", "PYTHONNOUSERSITE" to "1", "PYTHONDONTWRITEBYTECODE" to "1", "LANG" to "C.UTF-8"))
        }.start()
        try {if(notify)onBackgroundStarted(owner,id,process.pid(),process.toHandle().info().startInstant().orElseThrow().toEpochMilli())}
        catch(t:Throwable){kill(process);throw t}
        val result = scope.async(start=CoroutineStart.LAZY) {
            var truncated = false
            suspend fun drain(input: java.io.InputStream): Deferred<String> = async {
                val out = ByteArrayOutputStream(); val buf = ByteArray(8192)
                input.use { while (true) { val n = it.read(buf); if (n < 0) break
                    val keep = n.coerceAtMost((outputLimit - out.size()).coerceAtLeast(0)); if (keep < n) truncated = true; out.write(buf,0,keep)
                } }; out.toString(Charsets.UTF_8)
            }
            val stdout = drain(process.inputStream); val stderr = drain(process.errorStream)
            val input = async { process.outputStream.use { it.write(stdin) } }
            var state = "exited"
            try {
                if (!process.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)) { state = "timed_out"; kill(process) }
                killChildren(process)
                input.await()
                TaskProcessResult(id, state, if (state == "exited") process.exitValue() else null, stdout.await(), stderr.await(), truncated)
            } catch (e: CancellationException) { kill(process); throw e }
            finally { killChildren(process) }
        }
        jobs[id] = Running(owner, process, result)
        result.start()
        if(notify)scope.launch {
            val output=try {result.await()}catch(_:CancellationException){TaskProcessResult(id,"cancelled")}
            onBackgroundFinished(owner,output)
        }
        id
    }

    suspend fun wait(owner: String, id: String, seconds: Int = 30): TaskProcessResult {
        val job = jobs[id]?.takeIf { it.owner == owner } ?: throw IllegalArgumentException("进程不属于此任务")
        if (job.stopped) return TaskProcessResult(id,"cancelled")
        val deadline=System.nanoTime()+seconds.coerceIn(1,60)*1_000_000_000L
        while(System.nanoTime()<deadline) {
            if(inputPending(owner))return TaskProcessResult(id,"input_pending")
            withTimeoutOrNull(100) {job.result.await()}?.let {return it}
        }
        return TaskProcessResult(id,"running")
    }

    suspend fun run(owner: String, dir: File, args: List<String>, timeout: Int = 60, stdin: ByteArray = byteArrayOf(), outputLimit: Int = 256_000, allowClosed:Boolean=false): TaskProcessResult {
        val id = start(owner, dir, args, timeout, stdin, outputLimit,allowClosed=allowClosed)
        return try { jobs.getValue(id).result.await() } catch (e: CancellationException) { stop(owner,id); throw e } finally { jobs.remove(id) }
    }

    suspend fun stop(owner: String, id: String): TaskProcessResult {
        val job = jobs[id]?.takeIf { it.owner == owner } ?: throw IllegalArgumentException("进程不属于此任务")
        job.stopped = true
        kill(job.process); job.result.cancelAndJoin()
        return TaskProcessResult(id,"cancelled")
    }
    suspend fun stopTask(owner: String) { jobs.filterValues { it.owner == owner && !it.result.isCompleted }.keys.forEach { stop(owner,it) } }
    suspend fun cancelTask(owner:String) {synchronized(lifecycle){closedTasks.add(owner)};stopTask(owner)}
    fun recoverProcess(pid:Long,startedAtMs:Long) {
        val process=ProcessHandle.of(pid).orElse(null)?:return
        // Never signal a recycled PID or an unrelated host process.
        if(process.info().startInstant().orElse(null)?.toEpochMilli()!=startedAtMs)return
        if(mac)runCatching {ProcessBuilder("/bin/kill","-KILL","--","-$pid").start().waitFor(2,TimeUnit.SECONDS)}
        process.descendants().toList().reversed().forEach {it.destroyForcibly()}
        process.destroyForcibly()
        process.onExit().get(3,TimeUnit.SECONDS)
    }
    fun active(owner: String) = jobs.values.any { it.owner == owner && !it.result.isCompleted }
    private fun killChildren(process: Process) {
        if (mac) runCatching { ProcessBuilder("/bin/kill", "-KILL", "--", "-${process.pid()}").start().waitFor(2,TimeUnit.SECONDS) }
        process.descendants().toList().reversed().forEach { it.destroyForcibly() } }
    private fun kill(process: Process) { killChildren(process); process.destroyForcibly(); process.waitFor(2,TimeUnit.SECONDS) }
}
