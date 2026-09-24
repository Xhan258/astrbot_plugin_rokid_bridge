# AstrBot Rokid Bridge AIUI Client

这是 AstrBot Rokid Bridge 的通用 AIUI 客户端，不是独立 Agent。

- 远端 Bridge 负责将消息送入部署者已有的 AstrBot 会话、人格、记忆与工具链。
- 不要在客户端内新增第二套大模型、人格或长期记忆。
- 常规个人化只修改根目录 `config.js`；不要把 IP、Token 或真实姓名写死进 `pages/index/index.ink`。
- 需要扩展 UI、交互或硬件能力时，保持 `/v1/*` Bridge 协议兼容，并在 README 中记录新增权限和配置。
