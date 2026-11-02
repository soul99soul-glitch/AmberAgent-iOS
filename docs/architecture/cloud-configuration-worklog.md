# 云端配置管理阶段记录

基线8809438b，前一工具链包独立交付。范围仅cloud-daemon与既有cloud-channels凭据库的原子批量更新接缝；其他平台只读。未读真实Key/Keychain，未远端部署。

## 实现决定

- RFC7516 JWE compact，RSA-OAEP-256+A256GCM，Nimbus10.10；RSA3072导入私钥存原AES256-GCM envelope vault，公开JWK/SPKI与kid供可信客户端固定。没有Key压缩/zip或自创密码算法。
- 可信原生配对设备Bearer管理权限。密文绑定gateway/device/requestId/revision/time；返回configured状态与元数据，不返Key。
- 原vault新增updateSecrets，一次原子文件替换提交选中原Key条目与非secret配置/receipt元数据。全部验证/候选构造完成后持久化，成功后单点发布runtime快照。
- CoroutineContext固定Worker整个运行中的model/search代际；默认model facade复用原KMP OpenAI/Claude适配器。AgentProfile独立modelPreference和toolScope保留。
- provider/地址变更时须显式替换或删除模型Key，防止保留Key被无意转发给新目的地。空值不改，删除明确；无Key启动管理面但任务报未配置。受管model/search配置优先于旧文件/env，避免重启还原旧Key。Router短轮与后台调用使用最新独立快照。
- TLS代理可见管理动作/公钥/密文及既有授权头边界；被动日志看不到导入Key。首次公钥依赖可信分发，后续本地重算RFC7638并固定kid、校验SPKI/JWK一致。不能承诺抵抗主动首包替换、泄露设备Bearer、daemon/客户端攻陷或运行内存零明文。

## 验证

- Apple Security/CryptoKit独立原生JWE -> JVM/Nimbus通过；无临时明文payload/私钥文件，pipe内仅fakeKey测试数据。
- 新HTTP状态转换/鉴权/篡改/跨实例设备/过期/幂等/冲突/空值/删除/落盘失败/重启测试通过；两个相同revision竞争只有一个提交成功。
- 运行中Worker仍用旧model+Key，下一任务用新model+Key；搜索代际保持。原provider协议/任务API/AgentProfile权限/持久打标受影响回归通过。
- fatJar通过，最终产物通过实际Main+native JWE+loopback HTTP provider验证凭据热更新与重启后忽略旧env；复用配对/证书/结果/导入公钥。
- code-simplifier仅本阶段diff一次：核对单vault实例、原子提交/发布、错误固定文案、配置代际生命周期与暂存明文字节清理。没有独立review或全量验证。

未验收：真实Key迁移/收费请求/真实模型、腾讯部署、双端UI/安装/真机、Linux执行隔离/依赖配置和强杀断电。

回滚：保留原data、master、identity/tls/token，停新服务后恢复8809438b jar。管理state/import-key两个新加密条目可保留，原Key仍是原名，旧版不会提供新API/热更新且其启动env可再次覆盖Key。回滚前应保留新vault加密备份并检查旧env配置，不把回滚当作凭据版本恢复。
