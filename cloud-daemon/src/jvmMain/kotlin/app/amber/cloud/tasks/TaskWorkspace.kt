package app.amber.cloud.tasks

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.io.File
import java.nio.file.Files
import java.util.Base64

@Serializable
data class TaskArtifact(val path: String, val sizeBytes: Long, val sha256: String, val contentType: String)

/** File IO uses openat/O_NOFOLLOW inside the OS sandbox, including parent creation and downloads. */
class TaskWorkspace(private val root: File, private val processes: TaskProcessRunner) {
    private val json = Json { ignoreUnknownKeys = true }
    private val helper = javaClass.getResourceAsStream("/task-tools/files.py")!!.bufferedReader().use { it.readText() }
    init { root.mkdirs(); require(!Files.isSymbolicLink(root.toPath())) }
    fun directory(id: String): File {
        require(Regex("work:[a-f0-9]{24}").matches(id)) { "无效任务身份" }
        val dir = File(root,id.substringAfter(':'))
        require(!Files.isSymbolicLink(dir.toPath())) { "任务目录不能为符号链接" }
        dir.mkdirs(); return dir
    }
    suspend fun operation(id: String, op: String, args: JsonObject = JsonObject(emptyMap()), outputLimit: Int = 256_000): JsonElement {
        val request = JsonObject(args + ("op" to JsonPrimitive(op))).toString().toByteArray()
        val result = processes.run(id, directory(id), listOf(processes.python,"-c",helper), 30, request, outputLimit,allowClosed=op in setOf("list","read","search","artifact","bytes"))
        if (result.exitCode != 0) throw IllegalStateException("文件操作失败(state=${result.state},exit=${result.exitCode}): ${result.stdout.ifBlank { result.stderr }.take(1000)}")
        return json.parseToJsonElement(result.stdout).jsonObject.getValue("result")
    }
    suspend fun artifact(id: String, path: String): TaskArtifact = json.decodeFromJsonElement(operation(id,"artifact",buildJsonObject { put("path",path) }))
    suspend fun artifacts(id: String): List<TaskArtifact> = operation(id,"list").jsonArray.map { artifact(id,it.jsonPrimitive.content) }
    suspend fun bytes(id: String, path: String): ByteArray = Base64.getDecoder().decode(operation(id,"bytes",buildJsonObject { put("path",path) },46_000_000).jsonPrimitive.content)
    suspend fun writeBytes(id: String, path: String, bytes: ByteArray): TaskArtifact = json.decodeFromJsonElement(operation(id,"write_bytes",buildJsonObject {
        put("path",path);put("data",Base64.getEncoder().encodeToString(bytes))
    }))
}
