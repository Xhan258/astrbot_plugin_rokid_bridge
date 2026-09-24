# AstrBot Rokid Bridge

将 Rokid Glasses 的 AIUI 客户端接入现有 AstrBot 的通用插件。它不是第二个机器人，也不创建第二套人格、记忆或模型：眼镜消息会进入你已有的 AstrBot 会话链路。

当前版本：`0.3.1`

## 已提供

- 六位码配对、每设备凭证及撤销。
- 语音输入到 AstrBot，SSE 流式文字显示与对话历史。
- AIUI 本地 TTS（可关闭）。
- 仅限管理员眼镜会话调用的 HUD 文本显示、拍照识图工具。
- 插件页中的设备列表、管理员权限和眼镜使用者名称编辑。
- 配套 AIUI 客户端位于 [`rokid_aiui_astrbot_client`](https://github.com/Xhan258/rokid_aiui_astrbot_client)，可从灵珠 AIUI Studio 直接 GitHub 导入。

## 安装插件

1. 在 AstrBot 的插件页安装本仓库的 Release ZIP，或从源码安装 `astrbot_plugin_rokid_bridge/`。
2. 在插件配置中确认 Bridge 监听地址与端口。默认端口为 `6191`。
3. 确认眼镜能够访问该地址；局域网部署通常填写 AstrBot 主机的局域网 IP。公网部署请自行配置 HTTPS 入口或安全隧道。
4. 在插件的 `Rokid 设备` 页面，输入眼镜显示的六码并确认配对。
5. 若要让眼镜会话使用拍照/HUD 工具，把该设备设为管理员，并确保当前模型支持 Function Calling；拍照识图还需要视觉能力。

插件只管理 Bridge。AIUI 的语音、TTS、相机权限均在客户端资源包里声明；不需要新建 AstrBot 机器人或平台实例。

## 配套 AIUI 客户端

请从 [`rokid_aiui_astrbot_client`](https://github.com/Xhan258/rokid_aiui_astrbot_client) 导入客户端。该仓库根目录就是 AIUI 项目根目录；用户在其中的 `config.js` 配置 Bridge 地址、HUD 名称、设备名称和 TTS。

启动口令/启动提示词在 AIUI Studio 的智能体配置中设置，例如“乐奇，打开我的助手”；它不是系统唤醒词，也不属于 AstrBot 插件配置。

## 管理员与身份

插件页的“设为管理员”决定该**眼镜设备**进入 AstrBot 时的事件角色：管理员设备为 `admin`，普通设备为 `member`。这不会创建机器人，也不会修改 QQ、Telegram 等其他平台账号的权限。

“使用者名称”会作为此眼镜消息的 AstrBot 昵称，因此可填写自己的称呼；内部 `device_id` 与配对凭证不变。

## 眼镜工具

仅当前已连接的管理员眼镜会话可调用：

- `rokid_show_text(text, duration_seconds=8)`：在 HUD 顶部暂时显示短文本。
- `rokid_take_photo(purpose)`：请求眼镜拍照，将图片交给当前会话的视觉模型识别。

照片通过已认证的请求上传，服务端限制为 8 MiB。工具不会让 QQ 等其他平台远程控制眼镜。

## 分段回复

`普通分段回复结束等待（毫秒）` 默认 `3000`。QQ/微信式回复在该时间内有新的分段，就会继续合并；空闲达到该时间后才向眼镜发送完成事件。若你的分段间隔更长，可在插件配置中调大。

## 二次开发

- Bridge 协议在 [`docs/protocol.md`](docs/protocol.md)。不要无故改变既有 `/v1/*` 字段。
- AIUI 客户端边界与约束写在配套客户端仓库的 `AGENTS.md`。
- 插件数据只写入运行时 `data/`，不提交设备信息、凭证、IP、令牌或个人身份。

## 许可证与参考

MIT License，见 [`LICENSE`](LICENSE)。

项目独立实现；`rokid-glasses-desktop-agent`、`claude-bridge-glasses` 与 `rokid-personal-ai` 只作为配对和分层设计参考，未复制其代码。
