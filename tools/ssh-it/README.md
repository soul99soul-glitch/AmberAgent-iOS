# iOS SSH 双 sshd 本地验收

仅限本机容器。目标不发布端口；jump 强制 `/bin/false`，只能使用 direct-tcpip，不提供 shell。本期不实现 `-L`。

```sh
./tools/ssh-it/prepare.sh
docker compose -f tools/ssh-it/compose.yml up -d --build
```

在 iOS 模拟器中执行（无需连接真实服务器）：

1. 导入 `tools/ssh-it/fixtures/id_ed25519`，口令 `amber-it-pass`。复制公钥应与 `.pub` 相同（comment 可以不同）。
2. 创建 jump profile：`127.0.0.1:2222`，用户 `jumper`，绑定导入密钥；无跳板。
3. 创建 target profile：`target:22`，用户 `deploy`，绑定同一密钥，跳板设为 jump。
4. 设置页检查指纹，逐跳核对并信任，验证认证。也可通过前台 terminal 审批卡逐跳首次信任。锁屏、通知只能拒绝。
5. 执行 `terminal_execute`（target 的 `profile_id`，命令 `echo ok`），应返回 stdout `ok`、exit code 0。将 target 改为密码认证（`target-test-password`）后再测一次。
6. `terminal_job_start` 执行 `sleep 30; echo done`，随后 read / stop；停止后 `docker compose -f tools/ssh-it/compose.yml exec jump netstat -tn` 不应残留 ESTABLISHED 客户端会话。
7. 将 target 的 host 改为 `denied`，重新检查时应得到 `jump_forward_denied`，归属第 1 跳（PermitOpen 禁止）。
8. 轮换 target host key：`docker compose -f tools/ssh-it/compose.yml exec target sh -c 'rm /etc/ssh/ssh_host_*; ssh-keygen -A; kill -HUP 1'`。再次执行应在第 2 跳认证前阻断，前台卡不提供批准；只有设置页人工替换指纹后才能恢复。
9. 验证 jump 不支持 shell：`ssh -i tools/ssh-it/fixtures/id_ed25519 -p 2222 jumper@127.0.0.1 id`，输入测试口令后应以非 0 退出。不要写入个人 known_hosts；测试时用临时 `UserKnownHostsFile`。

结束：`docker compose -f tools/ssh-it/compose.yml down`。不删除任何用户数据；fixtures 是可重新生成、被 Git 忽略的本地测试材料。

不依赖 Docker 的自动门禁：`IOSSSHJumpIntegrationTests` 在 XCTest 内启动三个 loopback NIOSSH server，验证两层 direct-tcpip、逐跳 TOFU、指纹变化前零认证/后续零连接、输出脱敏及取消时整链关闭。Docker 未实际运行时不得把本文件视为 Docker 通过证据。
