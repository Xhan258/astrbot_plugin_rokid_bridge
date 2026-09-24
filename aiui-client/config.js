/**
 * AstrBot Rokid Bridge 客户端配置。
 *
 * 只改这个文件即可完成常见的个人化部署。不要填写 AstrBot WebUI 地址，
 * 而是填写运行本插件的 AstrBot 服务可被眼镜访问的 Bridge 地址。
 */
export const config = {
  // 例如：http://192.168.1.4:6191
  serverUrl: 'http://YOUR_ASTRBOT_HOST:6191',

  // HUD 顶部显示的名称；不影响 AstrBot 人格、模型或系统唤醒词。
  assistantName: 'ASTRBOT',

  // 配对页面和 AstrBot 插件设备页中显示的设备名称。
  deviceDisplayName: 'Rokid Glasses',

  // 眼镜本地存储命名空间。多套客户端连接同一台设备时可改为不同值。
  storagePrefix: 'astrbot_rokid_bridge',

  // AIUI 本地 TTS：关闭后仍能在 HUD 收到完整文字回复。
  ttsEnabled: true,
  ttsVoice: 'female-yujie',
};
