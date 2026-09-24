# Rokid Glasses Bridge Protocol v1

AIUI 客户端只能连接用户自己安装并启用的 AstrBot `rokid_bridge` 平台实例。插件不会提供公网托管。

## Endpoint

插件启动后在本机监听 HTTP/SSE：

`GET {server_url}/health`

`server_url` 是插件设置中的局域网或 HTTPS 反向代理地址，例如 `http://192.168.1.20:6191`。它不是眼镜 UI 的输入项，而是 AIUI 开发配置。

## 配对申请

```json
{"protocol_version":1,"device_id":"rokid-serial-or-install-id","display_name":"Rokid Glasses"}
```

成功响应：

```json
{"protocol_version":1,"status":"pairing","pairing_code":"482731","expires_at":1760000000}
```

用户在 AstrBot WebUI 确认该码后，AIUI 使用同一码轮询领取凭证：

```json
{"protocol_version":1,"pairing_code":"482731"}
```

未确认时响应 `{"protocol_version":1,"status":"pending"}`。确认后，插件只返回一次：

```json
{"protocol_version":1,"status":"paired","device_id":"rokid-serial-or-install-id","credential":"device-secret"}
```

AIUI 必须立即保存 `credential`，随后停止轮询；插件只存凭证哈希，原始凭证不经过 WebUI。

## 聊天

```json
{"protocol_version":1,"device_id":"rokid-serial-or-install-id","credential":"device-secret","text":"你好"}
```

响应 Content-Type 为 `text/event-stream`，事件为：

```text
event: ready
data: {"protocol_version":1,"request_id":"..."}

event: delta
data: {"text":"你好，我在。"}

event: done
data: {}
```

客户端应处理网络重连、显示超时错误，且不得记录或显示设备凭证。

## 设备命令扩展

同一条活跃聊天 SSE 流可包含 `command` 事件。客户端必须携带原设备的认证信息与 `command_id`，回传至：

`POST {server_url}/v1/command/result`

- `show_text`：载荷包含 `text` 和 `duration_seconds`；客户端显示后以 JSON 确认。
- `take_photo`：载荷包含请求的 `mode`；客户端拍一张照片、停止相机轨道，再用 multipart 字段 `image` 回传。

命令只在发起它的聊天流仍活跃时有效。Bridge 会拒绝其他设备提交的结果、过期的命令 ID、非图片上传和超过 8 MiB 的图片。
