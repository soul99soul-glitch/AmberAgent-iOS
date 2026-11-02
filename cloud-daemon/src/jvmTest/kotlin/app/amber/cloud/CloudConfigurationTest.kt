package app.amber.cloud

import app.amber.ai.ui.*
import app.amber.cloud.config.*
import app.amber.cloud.gateway.*
import app.amber.cloud.runtime.*
import app.amber.cloud.security.EnvelopeCredentialVault
import com.nimbusds.jose.*
import com.nimbusds.jose.crypto.RSAEncrypter
import com.nimbusds.jose.jwk.RSAKey
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.server.testing.*
import kotlinx.coroutines.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.*

class CloudConfigurationTest {
    private val json=Json {encodeDefaults=true}
    private val env=mapOf("AMBER_MASTER_KEY" to "temporary-config-master")
    private fun payload(key:ConfigurationImportKey,id:String,revision:Int,patch:ConfigurationPatch?=null,credentials:CredentialPatch?=null)=ConfigurationEnvelopePayload(
        1,key.gatewayId,key.deviceId,id,revision,key.serverTime,key.serverTime+300,patch,credentials)
    private fun seal(key:ConfigurationImportKey,payload:ConfigurationEnvelopePayload):String {
        val public=RSAKey.parse(key.publicJwk.toString())
        return JWEObject(JWEHeader.Builder(JWEAlgorithm.RSA_OAEP_256,EncryptionMethod.A256GCM).keyID(key.kid).type(JOSEObjectType("amber-config+jwe")).build(),Payload(json.encodeToString(payload)))
            .apply {encrypt(RSAEncrypter(public.toRSAPublicKey()))}.serialize()
    }
    private fun nativeSeal(key:ConfigurationImportKey,payload:ConfigurationEnvelopePayload):String {
        val binary=File("build/config-jwe-client").absoluteFile
        if(!binary.exists()) {
            val compile=ProcessBuilder("/usr/bin/swiftc","scripts/config-jwe-client.swift","-o",binary.path).redirectErrorStream(true).start()
            assertEquals(0,compile.waitFor(),compile.inputStream.bufferedReader().readText())
        }
        val process=ProcessBuilder(binary.path).start()
        process.outputStream.use {it.write(buildJsonObject {put("importKey",json.encodeToJsonElement(key));put("payload",json.encodeToJsonElement(payload))}.toString().toByteArray())}
        val result=process.inputStream.bufferedReader().readText().trim()
        assertEquals(0,process.waitFor(),process.errorStream.bufferedReader().readText())
        assertEquals(5,result.split('.').size)
        return result
    }
    private fun hash(file:File)=MessageDigest.getInstance("SHA-256").digest(file.readBytes()).toList()
    private suspend fun close(k:CloudAgentKernel){k.router.awaitIdle(includeWorkers=true);k.conversationTagger.closeAndJoin();k.supertagStore.close();k.agentRegistry.close();k.orchestrationStore.close()}

    @Test fun managementHttpNativeJweAtomicUpdateAndRestart()=testApplication {
        val dir=Files.createTempDirectory("configuration-http").toFile()
        val k=loadConfiguredDaemon(dir,env=env+mapOf("AMBER_SEARCH_BRAVE_KEY" to "fake-original-brave-key")).kernel
        val manager=k.configurationManager!!
        val pair=k.gatewayState.pairDevice(k.gatewayState.issuePairingTicket(),"ios","fixture") as CloudGatewayState.PairResult.Success
        val device=k.gatewayState.loadDevicesStrict().single()
        application {configureCloudGateway(k.gatewayState,agentApi=AgentCentricApi(k))}
        try {
            assertEquals(401,client.get("/v2/configuration").status.value)
            assertFalse(manager.view(device).credentials.modelApiKey.configured)
            val untrusted=device.copy(id="linux",platform="linux",trustedApprovalSurface=false)
            k.gatewayState.saveDevicesStrict(listOf(device,untrusted.copy(tokenHash=CloudGatewayState.sha256Hex("untrusted-token"))))
            assertEquals(403,client.get("/v2/configuration/import-key"){bearerAuth("untrusted-token")}.status.value)
            val keyResponse=client.get("/v2/configuration/import-key"){bearerAuth(pair.token)}
            assertEquals(200,keyResponse.status.value)
            val key=json.decodeFromString<ConfigurationImportKey>(keyResponse.bodyAsText())
            assertFalse(key.publicJwk.keys.any {it in setOf("d","p","q","dp","dq","qi")})
            val request=payload(key,"native-1",0,ConfigurationPatch(model=ManagedModelSettings("openai","imported-model","https://api.example.com/v1")),
                CredentialPatch(modelApiKey=CredentialMutation("replace","fake-model-import-12345"),exaApiKey=CredentialMutation("replace","fake-exa-import-12345")))
            val sealed=if(System.getProperty("os.name").contains("Mac"))nativeSeal(key,request)else seal(key,request)
            suspend fun post(envelope:String)=client.post("/v2/configuration"){bearerAuth(pair.token);setBody(json.encodeToString(ConfigurationImportRequest(envelope)))}
            val response=post(sealed);assertEquals(200,response.status.value,response.bodyAsText())
            assertEquals(1,manager.view(device).revision);assertTrue(manager.view(device).credentials.modelApiKey.configured)
            assertEquals("fake-model-import-12345",k.vault.getSecret("model.api_key"))
            assertFalse(File(dir,"secrets.enc.json").readText().contains("fake-model-import"))
            assertFalse(client.get("/v2/configuration"){bearerAuth(pair.token)}.bodyAsText().contains("fake-"))
            val replay=post(seal(key,request.copy(issuedAt=key.serverTime-1000,expiresAt=key.serverTime-900)))
            assertEquals(200,replay.status.value);assertTrue(json.decodeFromString<ConfigurationReceipt>(replay.bodyAsText()).replayed)
            assertEquals(409,post(seal(key,request.copy(configuration=ConfigurationPatch(model=ManagedModelSettings("claude","different"))))).status.value)
            assertEquals(400,post(sealed.dropLast(2)+if(sealed.endsWith("A"))"BB"else"AA").status.value)
            assertEquals(400,post(seal(key,request.copy(deviceId="other",requestId="bound"))).status.value)
            assertEquals(400,post(seal(key,request.copy(gatewayId="other",requestId="bound"))).status.value)
            assertEquals(410,post(seal(key,request.copy(requestId="expired",issuedAt=key.serverTime-400,expiresAt=key.serverTime-100))).status.value)
            val conflict=post(seal(key,request.copy(requestId="stale")))
            assertEquals(409,conflict.status.value);assertContains(conflict.bodyAsText(),"currentRevision")
            val oldHash=hash(File(dir,"secrets.enc.json"))
            val invalid=request.copy(requestId="invalid",expectedRevision=1,configuration=ConfigurationPatch(model=ManagedModelSettings("openai","bad","http://api.example.com")))
            assertEquals(422,post(seal(key,invalid)).status.value);assertEquals(oldHash,hash(File(dir,"secrets.enc.json")))
            val destinationChange=request.copy(requestId="destination",expectedRevision=1,
                configuration=ConfigurationPatch(model=ManagedModelSettings("claude","new-model","https://api.anthropic.com/v1")),credentials=null)
            val destinationDenied=post(seal(key,destinationChange))
            assertEquals(422,destinationDenied.status.value);assertContains(destinationDenied.bodyAsText(),"credential_action_required")
            assertEquals(oldHash,hash(File(dir,"secrets.enc.json")))
            val reflected=invalid.copy(requestId="reflection",configuration=ConfigurationPatch(model=ManagedModelSettings("openai","fake-model-import-12345")))
            assertEquals(422,post(seal(key,reflected)).status.value)
            val placeholder=invalid.copy(requestId="placeholder",configuration=null,credentials=CredentialPatch(exaApiKey=CredentialMutation("replace","<redacted>")))
            assertEquals(422,post(seal(key,placeholder)).status.value)
            val tmp=File(dir,"secrets.enc.json.tmp").also {assertTrue(it.mkdir())}
            val valid=request.copy(requestId="blank-preserve",expectedRevision=1,configuration=ConfigurationPatch(search=ManagedSearchSettings(listOf("bing","exa"),"aggregate")),credentials=CredentialPatch(modelApiKey=CredentialMutation("replace"," "),exaApiKey=CredentialMutation("replace","fake-exa-updated-67890"),braveApiKey=CredentialMutation("delete")))
            assertEquals(503,post(seal(key,valid)).status.value);assertEquals(oldHash,hash(File(dir,"secrets.enc.json")));assertEquals(1,manager.view(device).revision)
            assertTrue(tmp.delete())
            assertEquals(200,post(seal(key,valid)).status.value);assertEquals("fake-model-import-12345",k.vault.getSecret("model.api_key"))
            assertEquals(2,manager.view(device).revision);assertTrue(manager.view(device).credentials.exaApiKey.configured);assertFalse(manager.view(device).credentials.braveApiKey.configured)
            val deleted=payload(key,"delete",2,credentials=CredentialPatch(modelApiKey=CredentialMutation("delete")))
            assertEquals(200,post(seal(key,deleted)).status.value);assertFalse(manager.view(device).credentials.modelApiKey.configured)
            assertFails {manager.modelClient.generateReply(listOf(UIMessage.user("test")),emptyList())}
            assertEquals(400,client.post("/v2/configuration"){bearerAuth(pair.token);setBody("""{"apiKey":"fake-never-accepted"}""")}.status.value)
            assertEquals(413,post("A".repeat(120_001)).status.value)
            val restarted=loadConfiguredDaemon(dir,env=env+mapOf("AMBER_MODEL_API_KEY" to "fake-obsolete-env","AMBER_MODEL_ID" to "obsolete","AMBER_SEARCH_EXA_KEY" to "fake-obsolete-exa")).kernel
            try {
                val recovered=restarted.configurationManager!!
                assertEquals(3,recovered.view(device).revision);assertFalse(recovered.view(device).credentials.modelApiKey.configured)
                assertEquals("imported-model",recovered.view(device).model.modelId)
                assertEquals("fake-exa-updated-67890",restarted.vault.getSecret("search.exa_key"));assertEquals(key.kid,recovered.importKey(device).kid)
                assertTrue(recovered.update(device,seal(key,request)).replayed)
                File("build/configuration-interop-evidence.json").writeText(buildJsonObject {
                    put("client",if(System.getProperty("os.name").contains("Mac"))"Apple Security + CryptoKit"else"Nimbus fixture")
                    put("server","Nimbus JOSE JWT 10.10 / JVM")
                    put("alg","RSA-OAEP-256");put("enc","A256GCM");put("jwkAndSpkiBindingVerified",true)
                    put("plaintextKeysInResponsesOrVaultFile",false);put("restartedRevision",3);put("publicKeyPreserved",true)
                    put("realCredentialReadOrUploaded",false);put("realProviderCalled",false)
                }.toString())
            }finally{close(restarted)}
        }finally{close(k)}
    }

    @Test fun runningWorkerKeepsModelAndSearchGenerationAndNewTaskUsesUpdate()=runBlocking {
        val dir=Files.createTempDirectory("configuration-running").toFile()
        val vault=EnvelopeCredentialVault(File(dir,"secrets.enc.json"),masterSecretOverride="fixture",pbkdf2Iterations=1000)
        vault.putSecret("model.api_key","fake-old-provider-key")
        val entered=CompletableDeferred<Unit>();val release=CompletableDeferred<Unit>()
        val observed=CopyOnWriteArrayList<Pair<String,String?>>()
        var oldCalls=0
        val state=CloudGatewayState(dir)
        val pair=state.pairDevice(state.issuePairingTicket(),"ios","test") as CloudGatewayState.PairResult.Success
        val device=state.loadDevicesStrict().single()
        val manager=CloudConfigurationManager(vault,state.identity.id,CloudDaemonConfig(modelProvider="openai",modelId="old-model",searchSources="exa"),modelFactory={config,key->
            CloudModelClient { messages,_->
                if(!messages.first().toText().contains("受管 Worker"))return@CloudModelClient UIMessage.assistant("{\"tags\":[]}")
                observed+=config.modelId to key
                if(config.modelId=="old-model"&&oldCalls++==0){entered.complete(Unit);release.await();UIMessage.assistant("").copy(parts=listOf(UIMessagePart.Tool("search","history_search","{\"query\":\"fixture\"}")))}
                else UIMessage.assistant("").copy(parts=listOf(UIMessagePart.Tool("finish","task_finish","""{"outcome":"completed","summary":"${config.modelId}"}""")))
            }
        })
        val k=CloudAgentKernel(dir,manager.modelClient,masterSecretOverride="fixture",configurationManager=manager,vaultOverride=vault)
        try {
            val api=AgentCentricApi(k)
            val first=api.tasks.submit(device,NativeTaskRequest("first","task"))
            withTimeout(5000){entered.await()}
            val before=manager.snapshot();val pub=manager.importKey(device)
            val switch=payload(pub,"switch",0,ConfigurationPatch(ManagedModelSettings("claude","new-model"),ManagedSearchSettings(listOf("brave"),"fallback")),CredentialPatch(modelApiKey=CredentialMutation("replace","fake-new-provider-key")))
            val competing=(0..1).map { index -> async(Dispatchers.Default) {
                runCatching {manager.update(device,seal(pub,switch.copy(requestId="switch-$index")))}
            } }.awaitAll()
            assertEquals(1,competing.count {it.isSuccess})
            assertEquals(409,(competing.single {it.isFailure}.exceptionOrNull() as ConfigurationApiException).status)
            assertEquals("exa",before.search.search(buildJsonObject {put("query","x")}).sources.single().source)
            assertEquals("brave",manager.snapshot().search.search(buildJsonObject {put("query","x")}).sources.single().source)
            release.complete(Unit)
            withTimeout(5000){k.router.awaitIdle(includeWorkers=true)}
            assertEquals(listOf("old-model","old-model"),observed.map {it.first});assertTrue(observed.all {it.second=="fake-old-provider-key"})
            assertEquals("completed",api.workItem(first.workItem.id)!!.outcome)
            api.tasks.submit(device,NativeTaskRequest("second","task"))
            withTimeout(5000){k.router.awaitIdle(includeWorkers=true)}
            assertEquals("new-model" to "fake-new-provider-key",observed.last())
            val safe=credentialSafeModel(CloudModelClient {_,_->throw IllegalStateException("reflected fake-new-provider-key")},listOf("fake-new-provider-key"))
            assertFalse(assertFails {safe.generateReply(emptyList(),emptyList())}.message.orEmpty().contains("fake-new-provider-key"))
        }finally{release.complete(Unit);close(k)}
    }
}
