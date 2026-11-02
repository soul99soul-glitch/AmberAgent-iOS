package app.amber.cloud.tasks

import kotlinx.serialization.json.*
import java.io.File
import java.lang.management.ManagementFactory
import java.time.Instant

internal fun hostInfo(): JsonObject {
    val errors=mutableListOf<String>()
    val os=ManagementFactory.getOperatingSystemMXBean()
    return buildJsonObject {
        put("sampledAt",Instant.now().toString())
        put("os",os.name)
        put("arch",os.arch)
        put("cpuCount",os.availableProcessors)
        if(os.systemLoadAverage>=0) put("loadAverage",os.systemLoadAverage) else errors+="loadAverage unavailable"
        val extended=os as? com.sun.management.OperatingSystemMXBean
        if(extended!=null) {
            put("memoryTotalBytes",extended.totalMemorySize)
            put("memoryFreeBytes",extended.freeMemorySize)
            val cpu=extended.cpuLoad
            if(cpu>=0)put("cpuLoad",cpu)else errors+="cpuLoad unavailable at sample time"
        }else errors+="physical memory/CPU MXBean unavailable"
        put("disks",buildJsonArray {
            File.listRoots().forEach { root -> add(buildJsonObject {
                put("path",root.path)
                put("totalBytes",root.totalSpace)
                put("freeBytes",root.usableSpace)
            }) }
        })
        put("processes",buildJsonArray {
            ProcessHandle.allProcesses().use { stream -> stream.limit(100).forEach { process ->
                add(buildJsonObject {
                    put("pid",process.pid())
                    put("name",process.info().command().map { File(it).name }.orElse("unavailable"))
                    process.info().totalCpuDuration().ifPresent { put("cpuMillis",it.toMillis()) }
                })
            } }
        })
        put("errors",buildJsonArray {errors.forEach {add(it)}})
    }
}
