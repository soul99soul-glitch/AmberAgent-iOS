# Cloud configuration API v1 — 客户端冻结契约

本阶段基线8809438b，新增云端配置管理，上一阶段工具包独立有效。仅本地fakeKey验证，不代表生产导入或部署获准。

## 认证、信任和端点

三条端点均用当前配对 `Authorization: Bearer <device-token>`；服务端要求该持久设备记录为可信原生管理面（trustedApprovalSurface=true，platform为ios/macos/android/harmony），不接受模型/Worker身份。无Bearer401、存储损坏503、不可信设备403。客户端继续已有HTTPS/SPKI校验及gatewayId绑定，不关闭校验。

- `GET /v2/configuration`：只返回非secret配置、revision、configured状态和支持选项，绝不返回Key、掩码占位Key或Key哈希。
- `GET /v2/configuration/import-key`：返回daemon的长期导入公钥及当前认证设备身份，客户端按gatewayId固定kid（RFC7638 JWK SHA256 thumbprint）；已存kid变化时不得自动更新后继续发送，需重新确认信任。
- `POST /v2/configuration`：JSON `{"jwe":"<compact JWE>"}`，整个配置patch和凭据操作均加密。不接受明文Key字段或zip。

公钥响应：

```json
{
  "version":1,
  "gatewayId":"<existing-pairing-gateway-id>",
  "deviceId":"<authenticated-device-id>",
  "kid":"<RFC7638-base64url-thumbprint>",
  "alg":"RSA-OAEP-256",
  "enc":"A256GCM",
  "publicJwk":{"kty":"RSA","kid":"...","alg":"RSA-OAEP-256","use":"enc","n":"...","e":"AQAB"},
  "publicKeySpkiDerBase64":"<base64-X509-SPKI-DER>",
  "serverTime":1793516400,
  "maxEnvelopeLifetimeSeconds":300
}
```

客户端必须从实际收到的JWK重算RFC7638：按字典序序列化仅含e/kty/n的JSON（例如 `{"e":"AQAB","kty":"RSA","n":"..."}`），取UTF8的SHA256并base64url无padding，校验等于响应kid，再和该gateway已固定的kid比较。不能只信响应里自报的kid字符串。若使用SPKI DER导入SecKey，还须核对DER中的RSA modulus/exponent与同一JWK一致；SPKI SHA256不是RFC7638 kid，不能混用。独立Swift互通fixture演示这些检查。

JWK只含公钥。服务端RSA私钥仅写入原EnvelopeCredentialVault的加密条目，不共享TLS代理私钥、不写PEM临时文件。

首次公钥通过现有可信HTTPS/SPKI取得并固定，支持用可信独立渠道核对kid。JWE保证标准TLS终止代理/普通请求日志只见密文；**首次分发若被掌握TLS证书私钥的主动代理替换公钥，单靠同一路HTTPS不能抵抗该攻击**。设备Bearer亦仍是管理授权边界。后续固定kid可发现换钥，不声称抵抗daemon/客户端或上游provider被攻陷。

## JWE格式

采用RFC7516 compact serialization，固定RSA-OAEP-256（OAEP与MGF1均SHA256）、A256GCM；RSA3072公钥，随机256-bit CEK、随机96-bit IV、128-bit GCM tag。

protected header只使用：`{"alg":"RSA-OAEP-256","enc":"A256GCM","kid":"...","typ":"amber-config+jwe"}`。不使用zip/压缩、crit、外置JWK或URL。

输出为五段base64url无padding，以`.`连接：`protected.encryptedKey.iv.ciphertext.tag`。AES-GCM AAD为protected段本身的ASCII字节。客户端用成熟JOSE库，或平台CryptoKit/Security标准原语构造同一JWE格式；不要另造算法。后端Nimbus JOSE+JWT解析/认证/解密。

明文payload DTO（这里只展示fakeKey示意，真实Key不得进聊天/日志/文件）：

```json
{
  "version":1,
  "gatewayId":"<key-response-gatewayId>",
  "deviceId":"<key-response-deviceId>",
  "requestId":"<UUID>",
  "expectedRevision":0,
  "issuedAt":1793516400,
  "expiresAt":1793516700,
  "configuration":{
    "model":{"provider":"openai","modelId":"deepseek-flash","baseUrl":"https://api.deepseek.com/v1"},
    "search":{"sources":["bing","duckduckgo","exa","brave"],"mode":"aggregate"}
  },
  "credentials":{
    "modelApiKey":{"action":"replace","value":"fake-model-key"},
    "exaApiKey":{"action":"replace","value":"fake-exa-key"},
    "braveApiKey":{"action":"delete"}
  }
}
```

configuration、configuration.model、configuration.search、credentials及三个凭据动作均可省略，省略保持不变。model对象给出完整provider/modelId/baseUrl（空baseUrl使用该协议默认地址）；search对象给出完整有序sources与mode。仅允许openai/claude协议（DeepSeek等兼容provider选择openai并填其HTTPS baseUrl），不提供远程echo。本机免费源若标识为free/bing_local，应映射为有序的bing、duckduckgo，不能原样发送别名。免费源bing/duckduckgo，无需Key；exa/brave需显式启用和自己的Key。新管理地址只接受无userinfo/query/fragment的HTTPS API根地址。

凭据action为replace或delete。replace的value缺失/null/空白保持当前Key；非空仅替换该选中项，拒绝脱敏占位符。delete必须显式，且不能携带非空value。不接收任意凭据键名。删除模型Key后管理API继续可用，后续任务明确报未配置，不回显冒充执行。其他未选Key始终保留。

凭据目的地保护：当前模型Key非空时，若provider或有效baseURL改变，必须在同一请求显式replace非空modelApiKey或delete；未选/空值replace返回422 `credential_action_required`，整个请求不生效，原Key和原配置保留。只改modelId或其他设置可保留Key。这样不会因一次地址编辑就把旧Key自动转发给新provider。客户端应让用户勾选相应本机Key，或明确删除后切换。

## GET配置响应

```json
{
  "gatewayId":"...",
  "revision":1,
  "model":{"provider":"openai","modelId":"deepseek-flash","baseUrl":"https://api.deepseek.com/v1"},
  "search":{"sources":["bing","duckduckgo","exa"],"mode":"fallback"},
  "credentials":{
    "modelApiKey":{"configured":true},
    "exaApiKey":{"configured":true},
    "braveApiKey":{"configured":false}
  },
  "supportedModelProviders":["openai","claude"],
  "supportedSearchSources":["bing","duckduckgo","exa","brave"]
}
```

更新成功200：`{"requestId":"...","revision":1,"currentRevision":1,"replayed":false,"effective":"next_task"}`。客户端再GET刷新状态。

## 幂等、冲突、生效与错误

- 单设备requestId持久幂等。相同语义patch/凭据动作可重新封装重试；返回原applied revision并设replayed=true，currentRevision可能更高。相同requestId用于不同操作409 request_id_conflict。receipt只进原加密库，不向管理响应暴露秘密摘要。
- 新请求expectedRevision必须等于当前revision，否则409 revision_conflict并返回currentRevision。密文必须绑定当前gatewayId与Bearer对应deviceId，防跨实例/跨设备转投。
- issuedAt允许最多60秒未来时钟差；expiresAt>issuedAt且寿命<=300秒。未知过期请求410 envelope_expired；已经完成的相同请求只回receipt，不重复应用，允许超期重试查询。
- 非法/篡改密文、错kid/alg/enc/typ或绑定错误400 invalid_envelope；JSON形状/参数错误400 invalid_request；body过大413 request_too_large；provider/model/baseURL/sources/操作验证失败422 invalid_configuration（固定错误文案，不回传用户输入/Key）；持久化不可用503 configuration_unavailable。失败不修改当前revision、Key或可用运行配置。
- 所有变更先验证并构造候选客户端，凭据与配置/receipt元数据一次vault原子落盘后发布内存快照。无需真实provider请求验证；Key是否被provider接受只能另行授权实测。
- 后续Worker启动时固定model/search/Key快照；正在执行的Worker不会中途换provider。AgentProfile显式modelPreference与toolScope保持原语义。独立Router/后台请求用最新配置。
- 持久管理配置一旦存在，重启以其model/search与Key为准，不再被旧AMBER_MODEL_API_KEY或旧配置文件字段悄悄覆盖；IM等其他配置保持现机制。无模型Key时管理服务可启动，任务报未配置。

## 原生最窄接缝

iOS/macOS复用当前配对连接、设备Bearer、SPKI delegate与本机已选provider/搜索配置读取器。流程：GET配置和导入公钥→核对gatewayId/固定kid→只把用户勾选Key在内存加入payload→JWE→POST→GET刷新configured状态。空编辑框保持，不用掩码字符串回填；删除独立动作。冲突需拉取新revision并让用户重审本次差异，不能静默覆盖。

客户端不可把解密后payload或JWE解封私钥写日志/临时明文文件。daemon仅内存解封，持久内容继续原AES256-GCM信封库；客户端、daemon和上游HTTPS provider调用时仍需在内存使用明文，不能承诺运行内存绝无明文。TLS代理只需处理现有HTTPS，不得增加解密导入Key的组件。

参考标准：[RFC7516](https://www.rfc-editor.org/rfc/rfc7516.html)、[RFC7518](https://www.rfc-editor.org/rfc/rfc7518.html)、[Nimbus](https://connect2id.com/products/nimbus-jose-jwt)。本契约与实现验证结果将一起归档；本文件当前先冻结并行接入DTO。

## 已核对的原生接入位置

- iOS交付对象cc7189af：`iosApp/iosApp/MacGatewayClient.swift` 的 `MacGatewayClient` actor 与 `MacGatewayPinningDelegate` 承接HTTP/Bearer/SPKI；`MacGatewayStore.swift` 持有配对连接与Keychain设备token；`MacGatewayCloudTasks.swift`/`MacGatewayCloudTaskViews.swift` 是现有云任务消费路径。配置管理与加密封装可作为同一连接上的独立client/store能力。
- macOS搜索接缝：`macApp/AmberMac/Runtime/DesktopSearchSettings.swift` 与既有 `DesktopCredentialStore`；模型读取沿 `DesktopProvider`/`DesktopProviderCatalog`。出站云管理连接由客户端实现线程负责，现有 `DesktopGateway*` 为宿主Gateway功能，不能据其存在宣称已有出站配置客户端。仅读取源码/已交付对象，未触碰客户端工作树或实际Key。

## 本轮后端验收与交付边界

- 独立Apple Security/CryptoKit fixture校验RFC7638、SPKI/JWK一致，生成JWE；真实JVM/Nimbus解封后配置落到原加密vault。仅fakeKey/临时库。
- 覆盖401/403、错误绑定/篡改/过期、请求幂等与不同操作冲突、revision竞争、空输入保留与显式删除、无效参数不改旧状态、落盘失败不发布候选、重启保留公钥/版本/receipt、忽略过时启动env。
- Worker进行中切配置仍用旧模型/Key，后续任务用新模型/Key；搜索代际保持；AgentProfile命名模型原回归保留。
- 实际fatJar的Main+loopback provider完成原CSV产物链路，再通过原生JWE导入fake模型/Exa Key；后续HTTP provider请求头实际用新Key。重启仍保留过时env，后续请求继续用新Key，证书/配对/结果/公钥复用。provider/model选择切换通过确定性factory验证；未向真实provider或Exa/Brave发请求。
- 生产使用客户端HTTPS/SPKI与上游HTTPS配置；本机协议验收的loopback HTTP只承载fakeKey。未部署腾讯、迁移真实Key或替换TLS代理；没有iOS/macOS原生UI/安装/真机验收。Linux工具隔离前置仍沿8809438b交付约定。
