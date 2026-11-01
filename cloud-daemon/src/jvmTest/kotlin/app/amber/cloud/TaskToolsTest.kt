package app.amber.cloud

import app.amber.cloud.tasks.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.nio.file.Files
import kotlin.test.*

class TaskToolsTest {
    @Test fun isolatedCsvAndFailureBoundaries() = runBlocking {
        val root=Files.createTempDirectory("task-tools").toFile()
        val p=TaskProcessRunner(root.resolve("tools").also { it.mkdirs() })
        val w=TaskWorkspace(root.resolve("tasks"),p)
        val id="work:"+"a".repeat(24)
        w.operation(id,"write",buildJsonObject {put("path","data.csv");put("content","name,value\na,2\nb,3\n")})
        val script="import csv,json\nrows=list(csv.DictReader(open('data.csv')))\njson.dump({'sum':sum(int(r['value']) for r in rows)},open('result.json','w'))\nprint('processed',len(rows))"
        w.operation(id,"write",buildJsonObject {put("path","run.py");put("content",script)})
        val r=p.run(id,w.directory(id),listOf(p.python,"run.py"))
        assertEquals(0,r.exitCode,r.stderr);assertContains(r.stdout,"processed 2")
        assertEquals("{\"sum\": 5}",w.bytes(id,"result.json").toString(Charsets.UTF_8));assertEquals(10,w.artifact(id,"result.json").sizeBytes)
        assertFails { w.bytes(id,"../outside") }
        Files.createSymbolicLink(w.directory(id).resolve("escape").toPath(),root.toPath())
        assertFails { w.operation(id,"write",buildJsonObject {put("path","escape/out");put("content","x")}) }
        root.resolve("private-fixture").writeText("synthetic secret")
        val readDenied=p.run(id,w.directory(id),listOf(p.python,"-c","print(open('${root.absolutePath}/private-fixture').read())"))
        assertNotEquals(0,readDenied.exitCode);assertFalse(readDenied.stdout.contains("synthetic secret"))
        val denied=p.run(id,w.directory(id),listOf(p.python,"-c","open('${root.absolutePath}/secret','w').write('x')"))
        assertNotEquals(0,denied.exitCode);assertFalse(root.resolve("secret").exists())
        val network=p.run(id,w.directory(id),listOf(p.python,"-c","import socket;socket.socket().connect(('1.1.1.1',80))"),3)
        assertNotEquals(0,network.exitCode)
        assertEquals(7,p.run(id,w.directory(id),listOf("/bin/sh","-c","exit 7")).exitCode)
        assertEquals("timed_out",p.run(id,w.directory(id),listOf("/bin/sh","-c","sleep 10"),1).state)
        val child=p.start(id,w.directory(id),listOf("/bin/sh","-c","sleep 30 & echo $! > child.pid; wait"))
        assertFails { p.wait("work:"+"b".repeat(24),child,1) }
        withTimeout(3000){while(!w.directory(id).resolve("child.pid").exists())delay(20)}
        val childPid=w.bytes(id,"child.pid").toString(Charsets.UTF_8).trim().toLong()
        p.stopTask(id);assertFalse(p.active(id))
        assertEquals("cancelled",p.wait(id,child,1).state)
        withTimeout(3000){while(ProcessHandle.of(childPid).map {it.isAlive}.orElse(false))delay(20)}
    }
}
