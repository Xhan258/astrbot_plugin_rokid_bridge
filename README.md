# AstrBot Rokid Bridge

让 Rokid 眼镜连接到 AstrBot。

完成安装后，你可以通过眼镜和 AstrBot 对话，在 AIUI 页面阅读回复或听取播报；Agent 还可以在当前 AIUI 页面显示短提示，或请求眼镜拍照并交给视觉模型识别。

本插件需要配合 AIUI 眼镜客户端使用：

- AIUI 客户端仓库：[rokid_aiui_astrbot_client](https://github.com/Xhan258/rokid_aiui_astrbot_client)
- AIUI Studio 网页端：[https://aiui.rokid.com/](https://aiui.rokid.com/)

当前版本：`0.3.2`

## 你会得到什么

- 六位配对码绑定眼镜和 AstrBot。
- 眼镜语音输入、文字回复显示、对话历史浏览和本地 TTS 播报。
- 支持分段回复逐段显示。
- 在 AstrBot 页面管理已绑定眼镜、管理员权限和使用者名称。
- Agent 可在当前 AIUI 对话页显示短文本。
- Agent 可请求眼镜拍照，再由当前视觉模型识图。

## 使用前准备

你需要：

1. 一套可以正常使用的 AstrBot。
2. 支持 AIUI 的 Rokid 眼镜，以及 Rokid AI App。
3. 能登录 AIUI Studio 的 Rokid 账号。
4. 眼镜能够访问 AstrBot 所在主机的网络地址。

局域网使用时，眼镜和 AstrBot 主机通常接入同一个局域网即可。

## 第一次安装

### 1. 安装插件

1. 在本仓库的 Release 页面下载最新 ZIP。
2. 打开 AstrBot WebUI，进入“插件”。
3. 上传 ZIP、安装并启用插件。
4. 打开插件卡片，可以看到插件配置和“Rokid 设备”页面。

### 2. 选择眼镜连接端口

默认端口是：

```text
6191
```

在插件配置中可以修改“眼镜连接端口（可自定义）”。例如改成：

```text
7000
```

改端口时，下面三处必须一致：

| 位置 | 要填写什么 |
| --- | --- |
| AstrBot 插件配置 | 例如 `7000` |
| AIUI 客户端 `serverUrl` | 例如 `http://192.168.1.100:7000` |
| Docker 端口映射（如使用 Docker） | 例如 `7000:7000` |

保存端口设置后，请在 AstrBot 插件页面重载插件。

如果 AstrBot 通过 Docker 部署，除了修改插件配置，还要在 compose 文件中映射相同端口。例如使用默认端口：

```yaml
ports:
  - "6191:6191"
```

端口改为 `7000` 后：

```yaml
ports:
  - "7000:7000"
```

修改 Docker 端口映射后，需要重新创建容器，单纯重启容器不会读取新的映射。

### 3. 导入 AIUI 客户端

AIUI Studio 是 Rokid 的网页端 AIUI 开发和构建平台：

<https://aiui.rokid.com/>

在 AIUI Studio 中选择“GitHub 导入”，填写：

```text
仓库：https://github.com/Xhan258/rokid_aiui_astrbot_client
分支：main
```

客户端仓库根目录就是完整 AIUI 工程，不需要填写子目录。

### 4. 修改眼镜连接地址和页面名称

导入后，在 AIUI Studio 的“代码”页签打开根目录 `config.js`。

```js
export const config = {
  serverUrl: 'http://YOUR_ASTRBOT_HOST:6191',
  assistantName: 'ASTRBOT',
  deviceDisplayName: 'Rokid Glasses',
  storagePrefix: 'astrbot_rokid_bridge',
  ttsEnabled: true,
  ttsVoice: 'female-yujie',
};
```

每一项的作用：

| 配置项 | 作用 | 应该怎样填写 |
| --- | --- | --- |
| `serverUrl` | 眼镜连接 AstrBot 的地址 | 必填。填写 `http://主机IP:端口`，例如 `http://192.168.1.100:6191`。端口必须与插件配置一致。不要填写 AstrBot WebUI 地址。 |
| `assistantName` | AIUI 对话页面 HUD 顶部显示的名称 | 例如 `ALIS`。它只改变页面内标题，不改变 AstrBot 人格、AIUI 智能体名称或使用者昵称。 |
| `deviceDisplayName` | 第一次配对时 AstrBot 设备页看到的默认设备名称 | 例如 `我的 Rokid`。已经配对的设备可在 AstrBot“Rokid 设备”页修改使用者名称。 |
| `storagePrefix` | 眼镜本地保存设备 ID、配对凭证和 HUD 历史的前缀 | 普通用户保持默认。修改它会让客户端按一套新的本地信息运行，通常需要重新配对。 |
| `ttsEnabled` | 是否播报回复 | `true` 为播报；`false` 为只显示文字。 |
| `ttsVoice` | AIUI 本地 TTS 声音名称 | 默认 `female-yujie` 已测试。除非确认自己的 AIUI 环境支持其他名称，否则保持默认。 |

改完 `config.js` 后，保存项目并重新构建 AIUI 资源包，再更新到眼镜。

### 5. 设置眼镜如何打开这个智能体

在 AIUI Studio 中创建或编辑智能体时，填写智能体名称。

例如名称填写：

```text
Alis
```

安装到眼镜后，说：

```text
乐奇，打开 Alis
```

其中“乐奇”是眼镜系统唤醒词，“Alis”是 AIUI Studio 中的智能体名称。

`assistantName`、AIUI 智能体名称和 AstrBot 使用者名称是三项不同设置：

| 想改什么 | 去哪里改 |
| --- | --- |
| 说“乐奇，打开什么”时的名称 | AIUI Studio 的智能体名称 |
| AIUI 对话页顶部显示什么 | `config.js` 的 `assistantName` |
| AstrBot 如何称呼佩戴眼镜的人 | AstrBot 插件“Rokid 设备”页的使用者名称 |

### 6. 构建并更新到眼镜

在 AIUI Studio 中构建 AIX 资源包。然后在 Rokid AI App 中进入：

```text
设置 → 开发者 → 更新眼镜资源包
```

看到资源包更新成功后，使用“乐奇，打开 Alis”进入客户端。

## 第一次配对

1. 在眼镜中打开 AIUI 客户端。
2. 眼镜显示六位配对码。
3. 打开 AstrBot 插件的“Rokid 设备”页面。
4. 输入眼镜显示的六码，点击“确认配对”。
5. 眼镜显示 `READY` 后即可开始对话。

默认情况下，配对码有效期是 5 分钟。

## 日常使用

当眼镜顶部显示：

```text
● READY
```

表示可以说话。

1. 轻触一次镜腿，开始语音识别。
2. 说出问题。
3. 再轻触一次镜腿，结束语音识别。
4. 回复显示在当前 AIUI 对话页面中。

镜腿上下滑动可以浏览历史对话。退出后再次进入，客户端会自动尝试回到最新一条记录。

### 分段回复如何显示

AstrBot 有时会把一条回复分成多段发送。眼镜会在当前回复中逐段追加内容。

最后一段到达后，插件会等待“普通分段回复结束等待”指定的时间；如果等待期间又收到了新分段，就继续追加并重新计时。

默认是 `3000` 毫秒，也就是 3 秒。若回复仍然只显示前半段，可把插件配置中的该值改为 `5000`，然后重载插件。

## 重装插件后重新配对

删除、重装插件，或清除插件数据后，服务器端原有的眼镜凭证会失效。但眼镜本地可能还保存旧凭证，因此重新进入时可能先显示 `READY`。

按以下步骤恢复：

1. 返回眼镜主界面。
2. 再通过“乐奇，打开 Alis”进入客户端。
3. 如果眼镜直接显示六码，正常确认配对。
4. 如果仍显示 `READY`，说一句能够识别成文字的话，例如“重新配对”。
5. 客户端发现旧凭证失效后，会自动显示新的六码。
6. 在 AstrBot“Rokid 设备”页面确认新六码。

没有识别到文字的空语音不会发送到 AstrBot，因此不会触发重新配对。

## 管理眼镜与使用者名称

在 AstrBot 插件的“Rokid 设备”页面，可以：

| 操作 | 作用 |
| --- | --- |
| 刷新 | 读取最新设备状态 |
| 设为管理员 | 允许这副眼镜调用页面提示和拍照工具 |
| 撤销管理员 | 保留聊天功能，关闭眼镜工具调用权限 |
| 修改使用者名称 | 修改 AstrBot 收到眼镜消息时看到的昵称 |
| 撤销 | 删除该设备凭证，之后需要重新配对 |

例如把使用者名称改为 `Xhan258` 后，AstrBot 收到的眼镜消息会使用 `Xhan258` 作为昵称。

## Agent 如何使用眼镜

使用下列能力前，需要把眼镜设为管理员。

### 在 AIUI 对话页显示短文本

Agent 可调用：

```text
rokid_show_text(text, duration_seconds=8)
```

文字会显示在**已经打开的 AIUI 对话页面内部**，位于对话区域上方。

它适合显示“拍照中”“服务器正常”“你有一封重要邮件”这类当前对话提示。它不会在退出 AIUI 页面后作为系统级通知弹出，也不会覆盖其他眼镜应用。

默认显示 8 秒，最长可设置为 30 秒。

### 拍照识图

Agent 可调用：

```text
rokid_take_photo(purpose)
```

拍照时，AIUI 客户端需要获得眼镜相机权限。如果拍照失败，请在眼镜或 Rokid AI App 的权限设置中允许该 AIUI 智能体使用相机，重新进入 AIUI 页面后再试。

拍照识图还需要：

1. 眼镜已经设为管理员。
2. 眼镜当前停留在 AIUI 对话页面并保持连接。
3. 当前模型支持工具调用。
4. 当前模型支持图片识别。

## 常见问题

### 眼镜没有显示配对码

依次检查：

1. `config.js` 的 `serverUrl` 是否正确。
2. 插件是否启用。
3. 插件端口、`serverUrl` 端口、Docker 映射端口是否一致。
4. 插件配置中的“允许新设备申请配对”是否开启。
5. 如果眼镜显示 `READY`，请执行“重装插件后重新配对”。

### 眼镜显示连接错误

重点检查：

```js
serverUrl: 'http://主机IP:端口',
```

常见原因包括填写了 AstrBot WebUI 地址、端口没有同步、Docker 未映射端口，或服务器 IP 已改变。

### Agent 不能显示文字或拍照

确认眼镜已经设为管理员，且用户正停留在 AIUI 对话页面。拍照还需要相机权限、支持工具调用的模型和支持图片识别的模型。

## 二次开发

普通用户可以跳过本节。

- Bridge 协议：[`docs/protocol.md`](docs/protocol.md)
- AIUI 客户端源码：[rokid_aiui_astrbot_client](https://github.com/Xhan258/rokid_aiui_astrbot_client)
- 扩展 AIUI 能力时，请同步更新 `app.json` 权限、`config.js` 说明和 README。

## 版本兼容

| 组件 | 版本 |
| --- | --- |
| AstrBot Rokid Bridge | `0.3.2` |
| Rokid AIUI AstrBot Client | `1.0.0` |

## License

MIT License
