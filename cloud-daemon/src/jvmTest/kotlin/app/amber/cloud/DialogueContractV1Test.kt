package app.amber.cloud

import app.amber.ai.ui.UIMessage
import app.amber.cloud.gateway.*
import app.amber.cloud.orchestration.*
import app.amber.cloud.runtime.*
import io.ktor.client.request.*
import io.ktor.client.statement.bodyAsText
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import java.nio.file.Files
import kotlin.test.*

class DialogueContractV1Test {
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    private fun fingerprintFor(input: DialogueInput): String {
        val raw = buildString {
            append(input.kind).append('\u0000').append(input.workItemId.orEmpty()).append('\u0000').append(input.text)
            if (input.conversationId != null) append("\u0000conv:").append(input.conversationId)
            if (input.epoch != null) append("\u0000epoch:").append(input.epoch)
        }
        return OrchestrationHash.sha256Hex(raw)
    }

    @Test
    fun conformance_fixtures_all_six_scenarios_pass() {
        val fixtureText = javaClass.getResource("/dialogue-contract-v1-fixtures.json")?.readText()
            ?: error("Missing dialogue-contract-v1-fixtures.json resource")
        val root = json.parseToJsonElement(fixtureText).jsonObject
        assertEquals(DIALOGUE_CONTRACT_SCHEMA_VERSION, root.getValue("schemaVersion").jsonPrimitive.int)
        assertEquals("dialogue-event-contract-v1", root.getValue("contract").jsonPrimitive.content)

        val scenarios = root.getValue("scenarios").jsonArray
        assertEquals(6, scenarios.size, "Expected 6 cross-platform conformance scenarios")

        for (scenarioEl in scenarios) {
            val scenario = scenarioEl.jsonObject
            val scenarioId = scenario.getValue("id").jsonPrimitive.content
            val dir = Files.createTempDirectory("dialogue-fixture-$scenarioId").toFile()
            val store = CloudOrchestrationStore(dir)
            try {
                val dialogue = store.dialogue
                val acceptedById = mutableMapOf<String, DialogueInput>()

                for (stepEl in scenario.getValue("steps").jsonArray) {
                    val step = stepEl.jsonObject
                    val expect = step["expect"]?.jsonObject
                    when (val action = step.getValue("action").jsonPrimitive.content) {
                        "accept" -> {
                            val input = json.decodeFromJsonElement<DialogueInput>(step.getValue("input"))
                            val expectedError = expect?.get("errorCode")?.jsonPrimitive?.content
                            if (expectedError != null) {
                                val err = assertFailsWith<DialogueConflict>("[$scenarioId] expected $expectedError") {
                                    dialogue.accept(input, fingerprintFor(input))
                                }
                                assertEquals(expectedError, err.code, "[$scenarioId] conflict code mismatch")
                            } else {
                                val (accepted, replayed) = dialogue.accept(input, fingerprintFor(input))
                                acceptedById[accepted.id] = accepted
                                expect?.get("replayed")?.jsonPrimitive?.boolean?.let {
                                    assertEquals(it, replayed, "[$scenarioId] replayed mismatch for ${input.requestId}")
                                }
                                expect?.get("acceptedInputId")?.jsonPrimitive?.content?.let {
                                    assertEquals(it, accepted.id, "[$scenarioId] acceptedInputId mismatch")
                                }
                                expect?.get("disposition")?.jsonPrimitive?.content?.let {
                                    assertEquals(it, dialogue.disposition(accepted.id), "[$scenarioId] disposition mismatch")
                                }
                            }
                        }

                        "consume" -> {
                            val ids = step.getValue("inputIds").jsonArray.map { it.jsonPrimitive.content }
                            val toConsume = ids.map { id ->
                                acceptedById[id] ?: error("[$scenarioId] unknown input id to consume: $id")
                            }
                            dialogue.consume(toConsume)
                        }

                        "append_event" -> {
                            val event = json.decodeFromJsonElement<DialogueEvent>(step.getValue("event"))
                            dialogue.append(event)
                        }

                        "import_ledger" -> {
                            val ledgerId = step.getValue("ledgerId").jsonPrimitive.content
                            val events = step.getValue("events").jsonArray.map {
                                json.decodeFromJsonElement<DialogueEvent>(it)
                            }
                            val expectedError = expect?.get("errorCode")?.jsonPrimitive?.content
                            if (expectedError != null) {
                                val err = assertFailsWith<DialogueConflict>("[$scenarioId] expected $expectedError") {
                                    dialogue.importLedgerEvents(ledgerId, events)
                                }
                                assertEquals(expectedError, err.code, "[$scenarioId] ledger errorCode mismatch")
                            } else {
                                val result = dialogue.importLedgerEvents(ledgerId, events)
                                assertEquals(ledgerId, result.ledgerId, "[$scenarioId] ledgerId mismatch")
                                expect?.get("importedCount")?.jsonPrimitive?.int?.let {
                                    assertEquals(it, result.importedCount, "[$scenarioId] importedCount mismatch")
                                }
                                expect?.get("duplicateCount")?.jsonPrimitive?.int?.let {
                                    assertEquals(it, result.duplicateCount, "[$scenarioId] duplicateCount mismatch")
                                }
                            }
                        }

                        else -> error("Unknown fixture action: $action")
                    }
                }

                val expected = scenario.getValue("expected").jsonObject
                expected["dispositions"]?.jsonObject?.forEach { (id, stateEl) ->
                    assertEquals(
                        stateEl.jsonPrimitive.content,
                        dialogue.disposition(id),
                        "[$scenarioId] final disposition mismatch for $id",
                    )
                }
                expected["pendingInputIds"]?.jsonArray?.let { arr ->
                    val expectedIds = arr.map { it.jsonPrimitive.content }
                    assertEquals(expectedIds, dialogue.pending().map { it.id }, "[$scenarioId] pendingInputIds mismatch")
                }
                expected["pendingFollowupIds"]?.jsonArray?.let { arr ->
                    val expectedIds = arr.map { it.jsonPrimitive.content }
                    assertEquals(expectedIds, dialogue.pending(kind = "followup").map { it.id }, "[$scenarioId] pendingFollowupIds mismatch")
                }

                val page = dialogue.page(0, 100)
                assertEquals(DIALOGUE_CONTRACT_SCHEMA_VERSION, page.schemaVersion)
                val eventsById = page.items.associateBy { it.id }

                expected["eventCountByKind"]?.jsonObject?.forEach { (kind, countEl) ->
                    assertEquals(
                        countEl.jsonPrimitive.int,
                        page.items.count { it.kind == kind },
                        "[$scenarioId] event count mismatch for kind=$kind",
                    )
                }

                expected["requiredEvents"]?.jsonArray?.forEach { reqEl ->
                    val req = reqEl.jsonObject
                    val eventId = req.getValue("id").jsonPrimitive.content
                    val actual = eventsById[eventId]
                        ?: fail("[$scenarioId] missing required event $eventId; actual=${page.items.map { it.id }}")
                    assertEquals(req.getValue("kind").jsonPrimitive.content, actual.kind, "[$scenarioId] kind mismatch")
                    req["workItemId"]?.jsonPrimitive?.contentOrNull?.let {
                        assertEquals(it, actual.workItemId, "[$scenarioId] workItemId mismatch on $eventId")
                    }
                    req["conversationId"]?.jsonPrimitive?.contentOrNull?.let {
                        assertEquals(it, actual.conversationId, "[$scenarioId] conversationId mismatch on $eventId")
                    }
                    req["causedByInputId"]?.jsonPrimitive?.contentOrNull?.let {
                        assertEquals(it, actual.causedByInputId, "[$scenarioId] causedByInputId mismatch on $eventId")
                    }
                    req["causedByRequestId"]?.jsonPrimitive?.contentOrNull?.let {
                        assertEquals(it, actual.causedByRequestId, "[$scenarioId] causedByRequestId mismatch on $eventId")
                    }
                    req["executorKind"]?.jsonPrimitive?.contentOrNull?.let {
                        assertEquals(it, actual.executorKind, "[$scenarioId] executorKind mismatch on $eventId")
                    }
                    req["executorId"]?.jsonPrimitive?.contentOrNull?.let {
                        assertEquals(it, actual.executorId, "[$scenarioId] executorId mismatch on $eventId")
                    }
                    req["ledgerId"]?.jsonPrimitive?.contentOrNull?.let {
                        assertEquals(it, actual.ledgerId, "[$scenarioId] ledgerId mismatch on $eventId")
                    }
                }

                expected["absentEventIds"]?.jsonArray?.forEach { absentEl ->
                    val absentId = absentEl.jsonPrimitive.content
                    assertNull(eventsById[absentId], "[$scenarioId] event $absentId must not exist")
                }
            } finally {
                store.close()
                dir.deleteRecursively()
            }
        }
    }

    @Test
    fun native_dialogue_and_http_routes_passthrough_conversationId_and_enforce_invariants() = runBlocking {
        val dir = Files.createTempDirectory("dialogue-contract-v1-http").toFile()
        val k = CloudAgentKernel(dir, CloudModelClient { _, _ -> UIMessage.assistant("ok") }, masterSecretOverride = "contract-v1-test")
        k.orchestrationKernel.autoExecuteWorkersInBackground = false
        val pair = k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(), "ios", "fixture") as CloudGatewayState.PairResult.Success
        val device = k.gatewayState.loadDevicesStrict().single()
        try {
            val task = AgentCentricApi(k).tasks.submit(device, NativeTaskRequest("task-v1", "test")).workItem
            val workRecord = k.orchestrationStore.getWorkItem(task.id)!!
            k.orchestrationStore.upsertWorkItem(
                workRecord.copy(
                    conversationId = "conv-shared-42",
                    executorKind = "mac",
                    executorId = "mac-studio-1",
                    epoch = 2L,
                )
            )

            testApplication {
                application { configureCloudGateway(k.gatewayState, agentApi = AgentCentricApi(k)) }

                // 1. POST /v2/dialogue/messages with conversationId passes it through to receipt & event
                val msgResp = client.post("/v2/dialogue/messages") {
                    bearerAuth(pair.token)
                    setBody("""{"requestId":"msg-conv-1","text":"你好","conversationId":"conv-shared-42","executorKind":"ios","executorId":"iphone-1"}""")
                }
                assertEquals(202, msgResp.status.value)
                val msgReceipt = json.decodeFromString<DialogueReceipt>(msgResp.bodyAsText())
                assertEquals("conv-shared-42", msgReceipt.conversationId)
                assertEquals(DIALOGUE_CONTRACT_SCHEMA_VERSION, msgReceipt.schemaVersion)

                // 2. Legacy message without conversationId keeps topicId behavior and conversationId == null
                val legacyResp = client.post("/v2/dialogue/messages") {
                    bearerAuth(pair.token)
                    setBody("""{"requestId":"msg-legacy-1","text":"旧客户端消息"}""")
                }
                assertEquals(202, legacyResp.status.value)
                val legacyReceipt = json.decodeFromString<DialogueReceipt>(legacyResp.bodyAsText())
                assertNull(legacyReceipt.conversationId)
                assertNotEquals(msgReceipt.topicId, legacyReceipt.topicId)

                // 3. Stale epoch (1 < 2) on workItem returns HTTP 409 stale_epoch
                val staleResp = client.post("/v2/work-items/${task.id}/inputs") {
                    bearerAuth(pair.token)
                    setBody("""{"requestId":"stale-1","text":"旧 epoch","epoch":1}""")
                }
                assertEquals(409, staleResp.status.value)
                assertContains(staleResp.bodyAsText(), "stale_epoch")

                // 4. Valid epoch followup inherits workItem conversationId and carries causedByInputId when consumed
                val f1Resp = client.post("/v2/work-items/${task.id}/inputs") {
                    bearerAuth(pair.token)
                    setBody("""{"requestId":"f-same-1","text":"同一句补充","epoch":2}""")
                }
                val f2Resp = client.post("/v2/work-items/${task.id}/inputs") {
                    bearerAuth(pair.token)
                    setBody("""{"requestId":"f-same-2","text":"同一句补充","epoch":2}""")
                }
                assertEquals(202, f1Resp.status.value)
                assertEquals(202, f2Resp.status.value)
                val f1Receipt = json.decodeFromString<DialogueReceipt>(f1Resp.bodyAsText())
                val f2Receipt = json.decodeFromString<DialogueReceipt>(f2Resp.bodyAsText())
                assertEquals("conv-shared-42", f1Receipt.conversationId)
                assertEquals("conv-shared-42", f2Receipt.conversationId)

                val secondInput = k.orchestrationStore.dialogue.find(device.id, "f-same-2")!!
                k.orchestrationStore.dialogue.consume(listOf(secondInput))
                assertEquals("received", k.nativeDialogue.receipt(device, "f-same-1")!!.state)
                assertEquals("consumed", k.nativeDialogue.receipt(device, "f-same-2")!!.state)

                // 5. Abandon remaining pending followup -> cancelled with causedByInputId
                k.orchestrationStore.dialogue.abandonPending(task.id)
                assertEquals("cancelled", k.nativeDialogue.receipt(device, "f-same-1")!!.state)

                // 6. Mark workItem COMPLETED and send stop -> HTTP 200 + stop_too_late event
                val principal = k.orchestrationKernel.workerPrincipalFor(k.orchestrationStore.getWorkItem(task.id)!!)
                assertEquals(
                    WorkItemState.COMPLETED,
                    k.orchestrationKernel.reportWorkerSettlement(principal, WorkerSettlementReport(task.id, "completed", "done")).state,
                )
                val lateStopResp = client.post("/v2/work-items/${task.id}/stop") {
                    bearerAuth(pair.token)
                    setBody("""{"requestId":"stop-after-done","conversationId":"conv-shared-42","epoch":2}""")
                }
                assertEquals(200, lateStopResp.status.value)
                val lateStopReceipt = json.decodeFromString<DialogueReceipt>(lateStopResp.bodyAsText())
                assertEquals("cancelled", lateStopReceipt.state)
                assertEquals("conv-shared-42", lateStopReceipt.conversationId)

                val pageText = client.get("/v2/dialogue/events?after=0&limit=100") {
                    bearerAuth(pair.token)
                }.bodyAsText()
                val page = json.decodeFromString<DialoguePage>(pageText)
                assertEquals(DIALOGUE_CONTRACT_SCHEMA_VERSION, page.schemaVersion)
                assertTrue(page.items.any {
                    it.kind == DialogueEventKinds.INPUT_CONSUMED &&
                        it.causedByInputId == f2Receipt.eventId &&
                        it.causedByRequestId == "f-same-2" &&
                        it.conversationId == "conv-shared-42"
                })
                assertTrue(page.items.any {
                    it.kind == DialogueEventKinds.INPUT_CANCELLED &&
                        it.causedByInputId == f1Receipt.eventId &&
                        it.causedByRequestId == "f-same-1" &&
                        it.conversationId == "conv-shared-42"
                })
                assertTrue(page.items.any {
                    it.kind == DialogueEventKinds.STOP_TOO_LATE &&
                        it.causedByInputId == lateStopReceipt.eventId &&
                        it.causedByRequestId == "stop-after-done" &&
                        it.conversationId == "conv-shared-42"
                })
            }
        } finally {
            k.router.awaitIdle(includeWorkers = true)
            k.conversationTagger.closeAndJoin()
            k.agentRegistry.close()
            k.orchestrationStore.close()
            k.supertagStore.close()
            dir.deleteRecursively()
        }
    }

    @Test
    fun legacy_json_and_unknown_future_keys_deserialize_cleanly() {
        val legacyInputJson = """{"id":"i1","deviceId":"d1","requestId":"r1","kind":"followup","text":"hi","topicId":"t1","workItemId":"w1","futureField":"ignored"}"""
        val input = json.decodeFromString<DialogueInput>(legacyInputJson)
        assertNull(input.conversationId)
        assertNull(input.epoch)
        assertEquals(DIALOGUE_CONTRACT_SCHEMA_VERSION, input.schemaVersion)

        val legacyEventJson = """{"id":"e1","kind":"input_consumed","role":"system","text":"ok","topicId":"t1","workItemId":"w1","seq":5,"unknownExtra":123}"""
        val event = json.decodeFromString<DialogueEvent>(legacyEventJson)
        assertNull(event.causedByInputId)
        assertFalse(event.outcomeUnknown)
        assertEquals(DIALOGUE_CONTRACT_SCHEMA_VERSION, event.schemaVersion)

        val legacyReceiptJson = """{"eventId":"e1","requestId":"r1","topicId":"t1","workItemIds":["w1"],"state":"received","unknownFlag":true}"""
        val receipt = json.decodeFromString<DialogueReceipt>(legacyReceiptJson)
        assertNull(receipt.conversationId)
        assertFalse(receipt.outcomeUnknown)
        assertEquals(DIALOGUE_CONTRACT_SCHEMA_VERSION, receipt.schemaVersion)

        val legacyPageJson = """{"items":[],"nextCursor":0,"extraFuture":[]}"""
        val page = json.decodeFromString<DialoguePage>(legacyPageJson)
        assertEquals(DIALOGUE_CONTRACT_SCHEMA_VERSION, page.schemaVersion)
    }
}
