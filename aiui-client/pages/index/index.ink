<script def>
{
  "navigationBarTitleText": "AstrBot 眼镜助手"
}
</script>

<script setup>
import { config } from '../../config.js';
import wx from 'wx';

const storagePrefix = String(config.storagePrefix || 'astrbot_rokid_bridge').trim() || 'astrbot_rokid_bridge';
const storageKeys = {
  deviceId: storagePrefix + '_device_id',
  credential: storagePrefix + '_credential',
  chatHistory: storagePrefix + '_chat_history_v1',
};
// 迁移早期开发版的本地配对和 HUD 历史，不要求已部署用户重新配对。
const legacyStorageKeys = {
  deviceId: 'alis_device_id',
  credential: 'alis_credential',
  chatHistory: 'alis_chat_history_v1',
};

function getStoredValue(key, legacyKey) {
  try {
    const current = wx.getStorageSync(key);
    if (current !== undefined && current !== '') return current;
    const legacy = wx.getStorageSync(legacyKey);
    if (legacy !== undefined && legacy !== '') {
      wx.setStorageSync(key, legacy);
      return legacy;
    }
  } catch (e) {
    // 存储不可用时继续以运行时状态工作。
  }
  return '';
}

function bridgeUrl() {
  const url = String(config.serverUrl || '').trim().replace(/\/+$/, '');
  return url.includes('YOUR_ASTRBOT_HOST') ? '' : url;
}

export default {
  data: {
    connectionStatus: 'pairing',
    statusLabel: 'PAIR',
    statusIcon: '○',
    isStreaming: false,
    errorMessage: '',
    thinkingActive: false,
    dot0Active: false,
    dot1Active: false,
    dot2Active: false,
    debugInfo: '',
    deviceId: '',
    credential: '',
    pairingCode: '',
    isPairing: false,
    pollingActive: false,
    isListening: false,
    // 已完成回合仅用于本次打开期间的只读 HUD 历史；当前回合仍使用下方单页字段。
    completedTurns: [],
    turnIdCounter: 0,
    showUserMessage: false,
    userMessageText: '',
    replyText: '',
    toolDisplayText: '',
    ttsStatus: '',
    assistantName: String(config.assistantName || 'ASTRBOT').trim() || 'ASTRBOT',
  },

  onLoad() {
    this.restoreChatHistory();
    this.initDevice();
  },

  onShow() {
    // Storage restoration finishes before the scroll-view's content layout.
    // Retry over the first render frames so re-entering the page always starts
    // at the newest conversation instead of its preserved old offset.
    this.restoreHistoryScrollToBottom();
  },

  onHide() {
    this.persistChatHistory();
  },

  onUnload() {
    this.aborted = true;
    this.persistChatHistory();
    this.stopThinkingAnimation();
    this.stopPairPolling();
    this.abortSpeechRecognition();
    if (this.toolDisplayTimer) {
      clearTimeout(this.toolDisplayTimer);
      this.toolDisplayTimer = null;
    }
    if (this.ttsStatusTimer) {
      clearTimeout(this.ttsStatusTimer);
      this.ttsStatusTimer = null;
    }
  },

  // ── 单击镜腿开始/结束录音；滑动仍只用于浏览历史 ───────

  onKeyDown(event) {
    // GlobalHook 的 down/up 不携带长按或滑动信息；录音开关只在 key up 处理。
  },

  onKeyUp(event) {
    // 镜腿上下滑在 Rokid 侧会被投递为 ArrowUp / ArrowDown；
    // 默认行为只会滚动根页面，必须显式转发到聊天 scroll-view。
    if (event.code === 'ArrowUp' || event.code === 'ArrowDown') {
      const list = this.querySelector('#chat-scroll');
      if (list) {
        const step = Math.max(48, Math.round(list.clientHeight * 0.65));
        list.scrollBy({
          top: event.code === 'ArrowUp' ? -step : step,
          behavior: 'instant',
        }).catch(() => {});
      }
      event.preventDefault();
      return;
    }

    if (event.code === 'GlobalHook') {
      if (!this.data.credential || this.data.isStreaming || this.data.isPairing) {
        return;
      }
      if (this.data.isListening && this.recognition) {
        this.listenStopRequested = true;
        try {
          this.recognition.stop();
        } catch (e) {
          this.finishTapRecording();
        }
      } else if (!this.data.isListening) {
        this.startSpeechRecognition();
      }
    }
  },

  onVoiceWakeup() {
    // 录音只由明确的镜腿单击开启，避免触摸唤醒或环境唤醒误入录音态。
  },

  // ── Device identity ──────────────────────────────────

  initDevice() {
    let deviceId = getStoredValue(storageKeys.deviceId, legacyStorageKeys.deviceId);

    if (deviceId === undefined || deviceId === '') {
      deviceId = this.generateDeviceId();
      try {
        wx.setStorageSync(storageKeys.deviceId, deviceId);
      } catch (e) {
        // storage 写入失败，继续使用内存值
      }
    }

    const credential = getStoredValue(storageKeys.credential, legacyStorageKeys.credential);

    this.setData({
      deviceId,
      credential,
    });

    if (credential) {
      this.setData({
        connectionStatus: 'standby',
        statusLabel: 'READY',
        statusIcon: '●',
      });
    } else {
      this.startPairing();
    }
  },

  generateDeviceId() {
    let uuid = '';
    try {
      if (typeof crypto !== 'undefined' && crypto.randomUUID) {
        uuid = crypto.randomUUID();
      }
    } catch (e) {
      uuid = '';
    }
    if (!uuid) {
      uuid = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
    }
    return 'rokid-' + uuid;
  },

  // ── Pairing flow ─────────────────────────────────────

  async startPairing() {
    if (this.data.isPairing) {
      return;
    }

    const deviceId = this.data.deviceId;
    if (!deviceId) {
      this.setData({
        connectionStatus: 'error',
        statusLabel: 'ERROR',
        statusIcon: '△',
        errorMessage: 'Device ID missing',
      });
      return;
    }

    const baseUrl = bridgeUrl();
    if (!baseUrl) {
      this.setData({
        isPairing: false,
        connectionStatus: 'error',
        statusLabel: 'CONFIG',
        statusIcon: '△',
        errorMessage: '请先在 config.js 填写 Bridge 地址',
      });
      return;
    }

    this.stopPairPolling();
    this.aborted = false;

    this.setData({
      isPairing: true,
      connectionStatus: 'pairing',
      statusLabel: 'PAIR',
      statusIcon: '○',
      pairingCode: '',
      errorMessage: '',
    });

    try {
      const response = await fetch(baseUrl + '/v1/pair/request', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          protocol_version: 1,
          device_id: deviceId,
          display_name: String(config.deviceDisplayName || 'Rokid Glasses'),
        }),
      });

      if (!response.ok) {
        throw new Error('HTTP ' + response.status);
      }

      const data = await response.json();
      const code = data.pairing_code || '';

      if (!code) {
        throw new Error('No pairing code');
      }

      this.setData({ pairingCode: code });
      this.startPairPolling(code);
    } catch (err) {
      const msg = err && err.message ? err.message : String(err);
      this.setData({
        isPairing: false,
        connectionStatus: 'error',
        statusLabel: 'ERROR',
        statusIcon: '△',
        errorMessage: msg,
      });
    }
  },

  startPairPolling(code) {
    this.pollingActive = true;
    this.pollPairClaim(code);
  },

  async pollPairClaim(code) {
    if (!this.pollingActive || this.aborted) {
      return;
    }

    try {
      const response = await fetch(bridgeUrl() + '/v1/pair/claim', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          protocol_version: 1,
          pairing_code: code,
        }),
      });

      if (!response.ok) {
        throw new Error('HTTP ' + response.status);
      }

      const data = await response.json();
      const status = data.status || '';

      if (status === 'paired') {
        this.pollingActive = false;
        const credential = data.credential || '';
        if (credential) {
          try {
            wx.setStorageSync(storageKeys.credential, credential);
          } catch (e) {
            // storage 写入失败，继续使用内存值
          }
          this.setData({
            credential,
            isPairing: false,
            pairingCode: '',
            connectionStatus: 'standby',
            statusLabel: 'READY',
            statusIcon: '●',
          });
        } else {
          this.setData({
            isPairing: false,
            connectionStatus: 'error',
            statusLabel: 'ERROR',
            statusIcon: '△',
            errorMessage: 'No credential returned',
          });
        }
        return;
      }

      if (status === 'pending') {
        // 继续等待，2 秒后再次轮询
        this.pollTimer = setTimeout(() => {
          this.pollPairClaim(code);
        }, 2000);
        return;
      }

      // 未知状态或过期
      throw new Error('Pairing ' + status);
    } catch (err) {
      const msg = err && err.message ? err.message : String(err);
      this.pollingActive = false;
      this.setData({
        isPairing: false,
        connectionStatus: 'error',
        statusLabel: 'ERROR',
        statusIcon: '△',
        errorMessage: msg,
      });
    }
  },

  stopPairPolling() {
    this.pollingActive = false;
    if (this.pollTimer) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
  },

  clearCredential() {
    try {
      wx.removeStorageSync(storageKeys.credential);
      wx.removeStorageSync(storageKeys.chatHistory);
      wx.removeStorageSync(legacyStorageKeys.credential);
      wx.removeStorageSync(legacyStorageKeys.chatHistory);
    } catch (e) {
      // ignore
    }
    this.setData({
      credential: '',
    });
  },

  // ── Speech recognition ───────────────────────────────

  startSpeechRecognition() {
    if (this.data.isListening || this.data.isStreaming || this.data.isPairing) {
      return;
    }

    const credential = this.data.credential;
    if (!credential) {
      // 未配对时不设置错误状态，避免干扰配对流程
      return;
    }

    this.setData({
      isListening: true,
      errorMessage: '',
      connectionStatus: 'listening',
      statusLabel: 'LISTEN',
      statusIcon: '◌',
    });

    let recognition = null;
    try {
      recognition = new SpeechRecognition();
    } catch (e) {
      this.setData({
        isListening: false,
        connectionStatus: 'standby',
        statusLabel: 'READY',
        statusIcon: '●',
        errorMessage: 'Speech unavailable',
      });
      return;
    }

    recognition.lang = 'zh-CN';
    recognition.continuous = true;
    recognition.interimResults = false;
    recognition.maxAlternatives = 1;

    // 单击开始、再单击发送：期间只收集最终识别片段，绝不提前发消息。
    this.pendingTranscript = '';
    this.listenStopRequested = false;
    this.recognitionFailed = false;

    recognition.onresult = (event) => {
      try {
        const results = event.results;
        const start = Number(event.resultIndex) || 0;
        for (let index = start; results && index < results.length; index++) {
          const item = results[index];
          const transcript = item && item[0] ? String(item[0].transcript || '').trim() : '';
          if (transcript) {
            this.pendingTranscript = (this.pendingTranscript + ' ' + transcript).trim();
          }
        }
      } catch (e) {
        // Keep listening; a malformed partial result is not a chat message.
      }
    };

    recognition.onnomatch = () => {
      // Continue until the user taps again. Empty recognition never sends.
    };

    recognition.onerror = (event) => {
      let msg = '';
      try {
        if (event && event.error) {
          if (event.error === 'not-allowed' || event.error === 'permission-denied') {
            msg = 'Mic permission denied';
          } else if (event.error === 'aborted' || event.error === 'no-speech') {
            msg = '';
          } else if (event.message) {
            msg = event.message;
          } else {
            msg = event.error;
          }
        }
      } catch (e) {
        // keep default
      }
      this.recognitionFailed = true;
      this.pendingTranscript = '';
      this.stopSpeechRecognition();
      this.setData({ connectionStatus: 'standby', statusLabel: 'READY', statusIcon: '●', errorMessage: msg || '' });
    };

    recognition.onend = () => {
      this.finishTapRecording();
    };

    this.recognition = recognition;

    try {
      recognition.start();
    } catch (e) {
      this.stopSpeechRecognition();
      this.setData({
        connectionStatus: 'standby',
        statusLabel: 'READY',
        statusIcon: '●',
        errorMessage: 'Speech start failed',
      });
    }
  },

  stopSpeechRecognition() {
    this.setData({ isListening: false });
  },

  finishTapRecording() {
    const shouldSend = this.listenStopRequested && !this.recognitionFailed;
    const text = String(this.pendingTranscript || '').trim();
    this.recognition = null;
    this.stopSpeechRecognition();
    this.setData({ connectionStatus: 'standby', statusLabel: 'READY', statusIcon: '●' });
    this.listenStopRequested = false;
    this.pendingTranscript = '';
    if (shouldSend && text) {
      this.sendChatMessage(text);
    }
  },

  abortSpeechRecognition() {
    if (this.recognition) {
      try {
        this.recognition.abort();
      } catch (e) {
        // ignore
      }
      this.recognition = null;
    }
    this.listenStopRequested = false;
    this.pendingTranscript = '';
    this.recognitionFailed = false;
    if (this.data.isListening) {
      this.setData({ isListening: false });
    }
  },

  // ── Thinking animation ───────────────────────────────

  startThinkingAnimation() {
    this.setData({
      thinkingActive: true,
      dot0Active: false,
      dot1Active: false,
      dot2Active: false,
    });

    let i = 0;
    this.thinkingTimer = setInterval(() => {
      const next = (i + 1) % 3;
      if (next === 0) {
        this.setData({ dot0Active: true, dot1Active: false, dot2Active: false });
      } else if (next === 1) {
        this.setData({ dot0Active: false, dot1Active: true, dot2Active: false });
      } else {
        this.setData({ dot0Active: false, dot1Active: false, dot2Active: true });
      }
      i = next;
    }, 400);
  },

  stopThinkingAnimation() {
    if (this.thinkingTimer) {
      clearInterval(this.thinkingTimer);
      this.thinkingTimer = null;
    }
    if (this.data.thinkingActive) {
      this.setData({
        thinkingActive: false,
        dot0Active: false,
        dot1Active: false,
        dot2Active: false,
      });
    }
  },

  // ── Single-turn HUD helpers ──────────────────────────

  bumpScrollToBottom() {
    // AIUI 官方 Entity API：直接读取真实内容高度再滚动，
    // 不依赖 scroll-into-view 的渲染时序。
    setTimeout(() => {
      const list = this.querySelector('#chat-scroll');
      if (!list) {
        return;
      }
      list.scrollTo({ top: list.scrollHeight, behavior: 'instant' }).catch(() => {});
    }, 32);
  },

  restoreHistoryScrollToBottom() {
    [80, 240, 520].forEach((delay) => {
      setTimeout(() => {
        const list = this.querySelector('#chat-scroll');
        if (!list) {
          return;
        }
        list.scrollTo({ top: list.scrollHeight, behavior: 'instant' }).catch(() => {});
      }, delay);
    });
  },

  restoreChatHistory() {
    let stored = [];
    try {
      stored = getStoredValue(storageKeys.chatHistory, legacyStorageKeys.chatHistory);
    } catch (e) {
      stored = [];
    }
    if (!Array.isArray(stored)) return;
    const completedTurns = stored.slice(-30).map((item, index) => ({
      id: Number(item && item.id) || index + 1,
      userText: String((item && item.userText) || '').slice(0, 8000),
      replyText: String((item && item.replyText) || '').slice(0, 16000),
    })).filter((item) => item.userText && item.replyText);
    const turnIdCounter = completedTurns.reduce((maximum, item) => Math.max(maximum, item.id), 0);
    this.setData({ completedTurns, turnIdCounter });
  },

  persistChatHistory() {
    const turns = this.data.completedTurns.slice(-30);
    if (this.data.showUserMessage && this.data.userMessageText && this.data.replyText.trim()) {
      turns.push({
        id: this.data.turnIdCounter + 1,
        userText: this.data.userMessageText,
        replyText: this.data.replyText,
      });
    }
    try {
      wx.setStorageSync(storageKeys.chatHistory, turns.slice(-30));
    } catch (e) {
      // Storage is only a HUD convenience; chat and pairing keep working if full.
    }
  },

  beginTurn(text) {
    const completedTurns = this.data.completedTurns.slice();
    let turnIdCounter = this.data.turnIdCounter;

    // 仅在开始下一轮时冻结上一轮。当前页绝不同时出现在历史和当前区，
    // 避免此前“同一句话被两套模板各画一次”的问题。
    if (this.data.showUserMessage && this.data.userMessageText && this.data.replyText.trim()) {
      completedTurns.push({
        id: ++turnIdCounter,
        userText: this.data.userMessageText,
        replyText: this.data.replyText,
      });
    }

    this.setData({
      completedTurns: completedTurns.slice(-30),
      turnIdCounter,
      showUserMessage: true,
      userMessageText: text,
      replyText: '',
      errorMessage: '',
    });
    this.ttsSpokenOffset = 0;
    this.persistChatHistory();
    this.bumpScrollToBottom();
  },

  updateAssistantContent(deltaText) {
    if (!deltaText) {
      return false;
    }
    const replyText = this.data.replyText + deltaText;
    this.setData({ replyText });
    this.queueCompletedTtsSentences(replyText);
    return true;
  },

  scrollToEnd() {
    this.bumpScrollToBottom();
  },

  enqueueTts(text) {
    if (!config.ttsEnabled) return;
    if (!text || typeof speechSynthesis === 'undefined' || typeof SpeechSynthesisUtterance === 'undefined') {
      this.showTtsStatus('TTS UNAVAILABLE');
      return;
    }
    try {
      const utterance = new SpeechSynthesisUtterance(text);
      utterance.lang = 'zh-CN';
      utterance.voice = String(config.ttsVoice || 'female-yujie');
      utterance.volume = 10;
      speechSynthesis.speak(utterance, 'enqueue');
      this.showTtsStatus('TTS QUEUED');
    } catch (e) {
      this.showTtsStatus('TTS ERROR');
    }
  },

  queueCompletedTtsSentences(fullText) {
    const offset = this.ttsSpokenOffset || 0;
    const pending = String(fullText || '').slice(offset);
    const punctuation = /[。！？!?]+/g;
    let boundary = -1;
    let match;
    while ((match = punctuation.exec(pending)) !== null) {
      boundary = match.index + match[0].length;
    }
    if (boundary <= 0) return;
    const completed = pending.slice(0, boundary).trim();
    this.ttsSpokenOffset = offset + boundary;
    if (completed) this.enqueueTts(completed);
  },

  flushTtsTail(fullText) {
    const offset = this.ttsSpokenOffset || 0;
    const allText = String(fullText || '');
    const tail = allText.slice(offset).trim();
    this.ttsSpokenOffset = allText.length;
    if (tail) this.enqueueTts(tail);
  },

  showTtsStatus(status) {
    if (this.ttsStatusTimer) clearTimeout(this.ttsStatusTimer);
    this.setData({ ttsStatus: status });
    this.ttsStatusTimer = setTimeout(() => {
      this.ttsStatusTimer = null;
      this.setData({ ttsStatus: '' });
    }, 5000);
  },

  async submitCommandResult(commandId, status, message, imageBlob) {
    const deviceId = this.data.deviceId;
    const credential = this.data.credential;
    if (!commandId || !deviceId || !credential) return;
    try {
      let response;
      if (imageBlob) {
        const form = new FormData();
        form.append('protocol_version', '1');
        form.append('device_id', deviceId);
        form.append('credential', credential);
        form.append('command_id', commandId);
        form.append('status', status);
        form.append('message', message || '');
        form.append('image', new File([imageBlob], 'rokid-photo.jpg', { type: imageBlob.type || 'image/jpeg' }));
        response = await fetch(bridgeUrl() + '/v1/command/result', { method: 'POST', body: form, timeout: 90000 });
      } else {
        response = await fetch(bridgeUrl() + '/v1/command/result', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ protocol_version: 1, device_id: deviceId, credential, command_id: commandId, status, message: message || '' }),
          timeout: 15000,
        });
      }
      if (!response.ok) throw new Error('HTTP ' + response.status);
    } catch (e) {
      // The server-side command waiter turns a missing acknowledgement into a clear timeout.
    }
  },

  showToolText(text, durationSeconds) {
    if (this.toolDisplayTimer) clearTimeout(this.toolDisplayTimer);
    this.setData({ toolDisplayText: (text || '').slice(0, 500) });
    this.toolDisplayTimer = setTimeout(() => {
      this.toolDisplayTimer = null;
      this.setData({ toolDisplayText: '' });
    }, Math.max(1, Math.min(Number(durationSeconds) || 8, 30)) * 1000);
  },

  async takeToolPhoto(mode) {
    let stream;
    try {
      if (!navigator.mediaDevices || typeof ImageCapture === 'undefined') throw new Error('Camera unavailable');
      stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
      const track = stream.getVideoTracks()[0];
      if (!track) throw new Error('Camera track unavailable');
      return await new ImageCapture(track).takePhoto({ quality: 'high', mode: mode === 'wide' ? 'wide' : 'telephoto', enableSystemPreview: true });
    } finally {
      if (stream) stream.getTracks().forEach((track) => track.stop());
    }
  },

  async handleBridgeCommand(data) {
    const commandId = data && data.command_id;
    const command = data && data.command;
    const payload = (data && data.payload) || {};
    if (!commandId) return;
    if (command === 'show_text') {
      this.showToolText(String(payload.text || ''), payload.duration_seconds);
      await this.submitCommandResult(commandId, 'ok', 'HUD text displayed');
    } else if (command === 'take_photo') {
      try {
        const photo = await this.takeToolPhoto(payload.mode);
        await this.submitCommandResult(commandId, 'ok', 'Photo captured', photo);
      } catch (e) {
        await this.submitCommandResult(commandId, 'error', e && e.message ? e.message : 'Photo capture failed');
      }
    } else {
      await this.submitCommandResult(commandId, 'error', 'Unsupported command');
    }
  },

  // ── Chat (Bridge SSE protocol) ───────────────────────

  async sendChatMessage(text) {
    if (this.data.isStreaming) {
      return;
    }

    const deviceId = this.data.deviceId;
    const credential = this.data.credential;

    if (!deviceId || !credential) {
      // 无凭证，回到配对流程
      this.startPairing();
      return;
    }

    // 【第 5 条】空消息不发送
    if (!text || !text.trim()) {
      return;
    }

    // 每一轮直接替换上一轮 HUD 内容：这是原始单页交互，不维护聊天列表。
    this.beginTurn(text.trim());

    this.aborted = false;

    this.setData({
      connectionStatus: 'connecting',
      statusLabel: 'THINK',
      statusIcon: '◌',
      isStreaming: true,
      errorMessage: '',
    });
    this.startThinkingAnimation();

    let receivedContent = false;

    try {
      const response = await fetch(bridgeUrl() + '/v1/chat', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        },
        body: JSON.stringify({
          protocol_version: 1,
          device_id: deviceId,
          credential: credential,
          text: text.trim(),
        }),
        timeout: 120000,
      });

      // HTTP 401: 凭证失效
      if (response.status === 401) {
        this.stopThinkingAnimation();
        this.clearCredential();
        this.setData({
          isStreaming: false,
        });
        this.startPairing();
        return;
      }

      if (!response.ok) {
        throw new Error('HTTP ' + response.status + ' ' + (response.statusText || ''));
      }

      if (!response.body) {
        const respText = await response.text();
        this.stopThinkingAnimation();
        if (respText && respText.trim()) {
          this.updateAssistantContentDirect(respText);
          receivedContent = true;
        }
        if (!receivedContent) {
          this.handleEmptyReply('Empty response');
        }
        this.setData({
          connectionStatus: 'standby',
          statusLabel: 'READY',
          statusIcon: '●',
          isStreaming: false,
        });
        this.scrollToEnd();
        this.persistChatHistory();
        if (receivedContent) {
          this.flushTtsTail(this.data.replyText);
        }
        return;
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder('utf-8');
      let sseBuffer = '';
      let currentEvent = '';

      while (true) {
        if (this.aborted) {
          reader.cancel();
          break;
        }

        const { value, done } = await reader.read();
        if (done) {
          break;
        }

        const chunk = decoder.decode(value, { stream: true });
        sseBuffer += chunk;

        const lines = sseBuffer.split('\n');
        sseBuffer = lines.pop();

        for (let i = 0; i < lines.length; i++) {
          const line = lines[i].trim();

          if (line.startsWith('event:')) {
            currentEvent = line.slice(6).trim();
          } else if (line.startsWith('data:')) {
            const payload = line.slice(5).trim();

            if (currentEvent === 'delta' && payload) {
              try {
                const parsed = JSON.parse(payload);
                const deltaText = parsed.text || '';
                if (deltaText) {
                  const appended = this.updateAssistantContent(deltaText);
                  if (appended && !receivedContent) {
                    receivedContent = true;
                    this.stopThinkingAnimation();
                    this.setData({
                      connectionStatus: 'receiving',
                      statusLabel: 'LIVE',
                      statusIcon: '●',
                      errorMessage: '',
                    });
                  }
                }
              } catch (e) {
                // JSON 解析失败，跳过该片段
              }
            } else if (currentEvent === 'command' && payload) {
              try {
                await this.handleBridgeCommand(JSON.parse(payload));
              } catch (e) {
                // The command handler sends its own result where possible.
              }
            } else if (currentEvent === 'done') {
              // 流结束
              sseBuffer = '';
              this.stopThinkingAnimation();
              if (!receivedContent) {
                // done 时 assistant content 仍为空，不留空白回复
                this.handleEmptyReply('No reply content');
              }
              this.setData({
                connectionStatus: 'standby',
                statusLabel: 'READY',
                statusIcon: '●',
                isStreaming: false,
              });
              // 【第 13 条】done 后自动回到底部
              this.scrollToEnd();
              this.persistChatHistory();
              if (receivedContent) {
                this.flushTtsTail(this.data.replyText);
              }
              if (reader.releaseLock) {
                reader.releaseLock();
              }
              return;
            }

            currentEvent = '';
          }
        }
      }

      // 流自然结束（未收到 done 事件）
      if (reader.releaseLock) {
        reader.releaseLock();
      }

      this.stopThinkingAnimation();
      if (!receivedContent) {
        this.handleEmptyReply('No reply content');
      }
      this.setData({
        connectionStatus: 'standby',
        statusLabel: 'READY',
        statusIcon: '●',
        isStreaming: false,
      });
      this.scrollToEnd();
      this.persistChatHistory();
      if (receivedContent) {
        this.flushTtsTail(this.data.replyText);
      }
    } catch (err) {
      this.stopThinkingAnimation();
      if (!receivedContent) {
        this.handleEmptyReply('Stream error');
      }
      const msg = err && err.message ? err.message : String(err);
      this.setData({
        connectionStatus: 'standby',
        statusLabel: 'READY',
        statusIcon: '●',
        isStreaming: false,
        errorMessage: msg,
      });
      this.scrollToEnd();
      this.persistChatHistory();
    }
  },

  // 当前回合尚未写入历史，空回复只保留错误并在结束时提交用户消息。
  handleEmptyReply(reason) {
    this.setData({
      replyText: '',
      errorMessage: reason,
    });
  },

  // 直接替换 assistant 内容（用于无 body 的非流式响应）
  updateAssistantContentDirect(text) {
    this.setData({ replyText: text || '' });
  },
};
</script>

<page>
  <view class="hud-root">

    <view class="hud-header">
      <view class="hud-brand-wrap">
        <text class="hud-brand">{{assistantName}}</text>
      </view>
      <view class="hud-status">
        <text class="hud-status-icon">{{statusIcon}}</text>
        <text class="hud-status-label">{{statusLabel}}</text>
      </view>
    </view>

    <view class="hud-divider"></view>

    <view class="hud-dialog">
      <view ink:if="{{toolDisplayText}}" class="hud-tool-notice">
        <text class="hud-tool-notice-text">{{toolDisplayText}}</text>
      </view>
      <scroll-view id="chat-scroll" class="hud-dialog-scroll" scroll-y="true">

        <view ink:if="{{isPairing}}" class="hud-pairing-wrap">
          <view ink:if="{{pairingCode}}" class="hud-pairing-code">
            <text class="hud-pairing-code-text">{{pairingCode}}</text>
          </view>
          <view ink:else class="hud-pairing-waiting">
            <view class="hud-dot {{dot0Active ? 'dot-on' : ''}}"></view>
            <view class="hud-dot {{dot1Active ? 'dot-on' : ''}}"></view>
            <view class="hud-dot {{dot2Active ? 'dot-on' : ''}}"></view>
          </view>
        </view>

        <view ink:elif="{{completedTurns.length > 0 || showUserMessage}}" class="hud-chat-list">
          <view ink:for="{{completedTurns}}" ink:key="id" class="hud-reply-wrap">
            <view class="hud-user-line">
              <text class="hud-user-text">{{item.userText}}</text>
            </view>
            <view class="hud-reply">
              <streamdown
                content="{{item.replyText}}"
                streaming="{{false}}"
                color="rgba(64,255,94,0.85)"
                font-size="{{14}}"
              ></streamdown>
            </view>
          </view>

          <view ink:if="{{showUserMessage}}" class="hud-reply-wrap">
            <view class="hud-user-line">
            <text class="hud-user-text">{{userMessageText}}</text>
            </view>
            <view ink:if="{{thinkingActive && isStreaming && !replyText}}" class="hud-thinking">
              <view class="hud-dot {{dot0Active ? 'dot-on' : ''}}"></view>
              <view class="hud-dot {{dot1Active ? 'dot-on' : ''}}"></view>
              <view class="hud-dot {{dot2Active ? 'dot-on' : ''}}"></view>
            </view>
            <view ink:elif="{{replyText}}" class="hud-reply">
              <streamdown
                content="{{replyText}}"
                streaming="{{false}}"
                color="rgba(64,255,94,0.85)"
                font-size="{{14}}"
              ></streamdown>
            </view>
            <view ink:if="{{errorMessage}}" class="hud-error-line">
              <text class="hud-error-text">{{errorMessage}}</text>
            </view>
          </view>
        </view>

        <view ink:elif="{{thinkingActive}}" class="hud-thinking">
          <view class="hud-dot {{dot0Active ? 'dot-on' : ''}}"></view>
          <view class="hud-dot {{dot1Active ? 'dot-on' : ''}}"></view>
          <view class="hud-dot {{dot2Active ? 'dot-on' : ''}}"></view>
        </view>

        <view ink:elif="{{errorMessage}}" class="hud-error-line">
          <text class="hud-error-text">{{errorMessage}}</text>
        </view>

      </scroll-view>
    </view>

    <view class="hud-footer">
      <view class="hud-reserved-slots">
        <text class="hud-tts-status">{{ttsStatus}}</text>
      </view>
    </view>

  </view>
</page>

<style>
.hud-root {
  width: 100%;
  height: 100%;
  min-height: 0;
  display: flex;
  flex-direction: column;
  background-color: #000000;
  padding: 12px 16px;
  box-sizing: border-box;
  overflow: hidden;
}

.hud-header {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  padding: 0 0 4px 0;
  flex-shrink: 0;
}

.hud-brand-wrap {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 5px;
}

.hud-brand {
  font-family: sans-serif;
  font-size: 11px;
  font-weight: 500;
  color: rgba(64,255,94,0.88);
  letter-spacing: 0.18em;
  text-transform: uppercase;
}

.hud-debug {
  font-family: sans-serif;
  font-size: 7px;
  color: rgba(64,255,94,0.55);
}

.hud-status {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 4px;
}

.hud-status-icon {
  font-family: sans-serif;
  font-size: 10px;
  color: rgba(64,255,94,0.60);
}

.hud-status-label {
  font-family: sans-serif;
  font-size: 10px;
  font-weight: 400;
  color: rgba(64,255,94,0.60);
  letter-spacing: 0.06em;
}

.hud-divider {
  height: 1px;
  background-color: rgba(64,255,94,0.18);
  margin: 0 0 0 0;
  flex-shrink: 0;
}

.hud-dialog {
  flex-grow: 1;
  flex-shrink: 1;
  display: flex;
  flex-direction: column;
  padding: 8px 0;
  box-sizing: border-box;
  min-height: 0;
}

.hud-dialog-scroll {
  height: 100%;
  width: 100%;
  flex-grow: 1;
  min-height: 0;
}

.hud-tool-notice {
  flex-shrink: 0;
  padding: 3px 0 6px 0;
}

.hud-tool-notice-text {
  font-family: sans-serif;
  font-size: 12px;
  color: rgba(64,255,94,0.92);
  line-height: 1.35;
}

.hud-pairing-wrap {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  flex-grow: 1;
}

.hud-pairing-code {
  padding: 8px 0;
}

.hud-pairing-code-text {
  font-family: sans-serif;
  font-size: 28px;
  font-weight: 600;
  color: rgba(64,255,94,0.85);
  letter-spacing: 0.12em;
  text-align: center;
}

.hud-pairing-waiting {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: center;
  gap: 6px;
  padding: 8px 0;
}

.hud-chat-list {
  display: flex;
  flex-direction: column;
}

.hud-msg-item {
  padding: 0 0 8px 0;
}

.hud-user-text {
  font-family: sans-serif;
  font-size: 13px;
  color: rgba(64,255,94,0.65);
  line-height: 1.5;
}

.hud-msg-assistant {
  display: flex;
  flex-direction: column;
  padding: 0;
}

.hud-thinking-inline {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: flex-start;
  gap: 6px;
  padding: 2px 0;
}

.hud-thinking {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: flex-start;
  gap: 6px;
  padding: 6px 0;
}

.hud-dot {
  width: 4px;
  height: 4px;
  border-radius: 9999px;
  background-color: rgba(64,255,94,0.10);
  opacity: 0.10;
  transition: opacity 200ms cubic-bezier(0.16, 1, 0.3, 1);
}

.dot-on {
  opacity: 0.60;
}

.hud-error-line {
  padding: 4px 0;
}

.hud-error-text {
  font-family: sans-serif;
  font-size: 10px;
  color: rgba(64,255,94,0.65);
  letter-spacing: 0.05em;
}

.hud-footer {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  padding: 4px 0 0 0;
  flex-shrink: 0;
}

.hud-reserved-slots {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 8px;
}

.hud-reserved-slot {
  font-family: sans-serif;
  font-size: 10px;
  color: rgba(64,255,94,0.10);
  letter-spacing: 0.05em;
}

.hud-tts-status {
  font-family: sans-serif;
  font-size: 10px;
  color: rgba(64,255,94,0.82);
  letter-spacing: 0.05em;
}
</style>
