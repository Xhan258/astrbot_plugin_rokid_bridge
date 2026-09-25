# Changelog

## 0.3.6

- 使用 AstrBot 官方 logger，满足插件市场日志规范。
- 将照片上传改为 aiohttp 异步分块读取，避免阻塞事件循环。
- 新增“HUD 默认显示时长（秒）”插件设置，支持 1 到 30 秒。

## 0.3.5

- 新增插件图标。

## 0.3.4

- 修正 README 中遗漏的插件版本号，使其与 Release 元数据一致。

## 0.3.3

- 修订 README 的镜腿滑动方向、分段回复成因和 HUD 显示位置说明。

## 0.3.2

- 重写面向普通用户的 README：明确端口配置、首次配对、重装后的重新配对、分段回复和眼镜工具的实际表现。
- 将端口配置标记为可自定义，并在插件设置中说明 AIUI 地址与 Docker 端口映射的同步要求。
- 精简插件市场简介，直接说明用户能获得的功能。

## 0.3.1

- 将 AIUI 客户端源码迁移至独立仓库 `rokid_aiui_astrbot_client`，使灵珠 AIUI Studio 可直接从仓库根目录导入。
- 插件 Release ZIP 仅保留 AstrBot Bridge 运行所需文件，不再携带 AIUI 客户端。

## 0.3.0

- 将 AIUI 客户端源码纳入仓库的 `aiui-client/`，可直接从 GitHub 或本地导入 AIUI Studio。
- 提供可编辑的客户端配置：Bridge 地址、HUD 顶部名称、设备显示名、TTS 开关与声音。
- 清除特定 Agent、私有 IP 与旧功能范围描述；保留旧 `alis_*` 本地存储键的迁移兼容。
- 更新 AstrBot 市场元数据、安装说明与发布文件结构。

## 0.2.2

- 移除设备管理按钮对浏览器确认弹窗的依赖，兼容 AstrBot 受限插件页面 iframe。
- 管理员、撤销操作点击后立即提交，并在页面显示明确进行中/成功/失败状态。

## 0.2.1

- 修复设备认证与管理员设置并发时可能覆盖管理员标记的问题。
- 设备页新增可编辑的使用者名称；该名称会作为眼镜消息的 AstrBot 昵称。
- 重做设备管理页布局，并为管理员状态与改名操作增加明确反馈和日志。

## 0.2.0

- 新增仅限当前管理员眼镜会话的 `rokid_show_text` HUD 文本显示工具。
- 新增 `rokid_take_photo`：眼镜按需拍照，插件以当前会话的视觉模型识图后把文字结果交回 Agent。
- 增加受认证保护的设备命令通道；照片上传上限为 8 MiB，命令结果不能跨设备提交。

## 0.1.4

- 将 AstrBot 思考期间的 SSE 保活间隔从 15 秒缩短到 3 秒，兼容约 5 秒空闲即断开的嵌入式客户端。

## 0.1.3

- 修复确认配对成功后异步事件对象失效，导致页面无法重置配对码输入框的问题。

## 0.1.2

- 修复 Rokid 设备管理页在 AstrBot 受限 iframe 内直接请求 API 导致的 `Failed to fetch`。
- 改用 AstrBot 官方 Plugin Page bridge 管理已绑定设备、确认配对与撤销凭证。

## 0.1.1

- Remove the user-visible AstrBot platform-instance setup.
- Start the AIUI HTTP/SSE endpoint from the plugin itself on the configured port.
- Keep the internal AstrBot adapter solely for normal event and session routing.

## 0.1.0

- Initial development package with pairing, credential hashing, SSE routing and device management.
