const devicesEl = document.querySelector("#devices");
const noticeEl = document.querySelector("#notice");
const bridge = window.AstrBotPluginPage;

function setNotice(text, isError = false) {
  noticeEl.textContent = text;
  noticeEl.style.color = isError ? "#b42318" : "";
}

function formatTime(timestamp) {
  return timestamp ? new Date(timestamp * 1000).toLocaleString() : "尚未连接";
}

function requestError(error) {
  return error instanceof Error && error.message ? error.message : "请求失败，请重试";
}

async function loadDevices() {
  devicesEl.replaceChildren(Object.assign(document.createElement("li"), { textContent: "正在读取…" }));
  try {
    const data = await bridge.apiGet("devices");
    devicesEl.replaceChildren();
    if (!data.devices?.length) {
      devicesEl.append(Object.assign(document.createElement("li"), { textContent: "暂无已绑定设备" }));
      return;
    }
    for (const device of data.devices) {
      const item = document.createElement("li");
      const meta = document.createElement("div");
      meta.className = "device-meta";
      const nameForm = document.createElement("form");
      nameForm.className = "name-form";
      const nameInput = Object.assign(document.createElement("input"), {
        value: device.display_name,
        maxLength: 64,
        ariaLabel: "使用者名称",
      });
      const saveName = Object.assign(document.createElement("button"), { textContent: "保存名称", type: "submit" });
      nameForm.append(nameInput, saveName);
      nameForm.addEventListener("submit", async (event) => {
        event.preventDefault();
        const display_name = nameInput.value.trim();
        if (!display_name) return setNotice("使用者名称不能为空", true);
        saveName.disabled = true;
        try {
          const result = await bridge.apiPost(`devices/${encodeURIComponent(device.device_id)}/rename`, { display_name });
          setNotice(`已将使用者名称改为“${result.display_name}”`);
          await loadDevices();
        } catch (error) { setNotice(requestError(error), true); }
        finally { saveName.disabled = false; }
      });
      const details = document.createElement("div");
      details.className = "device-details";
      details.append(Object.assign(document.createElement("span"), { textContent: `上次连接 ${formatTime(device.last_seen_at)}` }));
      details.append(Object.assign(document.createElement("span"), { textContent: "内部设备 ID 已固定，不会因改名而断开配对" }));
      meta.append(nameForm, details);
      const actions = document.createElement("div");
      actions.className = "device-actions";
      const role = Object.assign(document.createElement("span"), {
        className: `role-badge ${device.is_admin ? "admin" : "member"}`,
        textContent: device.is_admin ? "管理员" : "普通用户",
      });
      const admin = Object.assign(document.createElement("button"), {
        className: "role-action",
        textContent: device.is_admin ? "取消管理员" : "设为管理员",
      });
      admin.addEventListener("click", async () => {
        const action = device.is_admin ? "revoke-admin" : "grant-admin";
        const label = device.is_admin ? "取消管理员" : "设为管理员";
        admin.disabled = true;
        setNotice(`正在${label}…`);
        try {
          const result = await bridge.apiPost(`devices/${encodeURIComponent(device.device_id)}/${action}`, {});
          setNotice(result.is_admin ? "管理员权限已保存" : "已取消管理员权限");
          await loadDevices();
        } catch (error) { setNotice(requestError(error), true); }
        finally { admin.disabled = false; }
      });
      const revoke = Object.assign(document.createElement("button"), { className: "danger", textContent: "撤销设备" });
      revoke.addEventListener("click", async () => {
        revoke.disabled = true;
        setNotice("正在撤销设备…");
        try {
          await bridge.apiPost(`devices/${encodeURIComponent(device.device_id)}/revoke`, {});
          setNotice("设备已撤销");
          await loadDevices();
        } catch (error) { setNotice(requestError(error), true); }
        finally { revoke.disabled = false; }
      });
      actions.append(role, admin, revoke);
      item.append(meta, actions);
      devicesEl.append(item);
    }
  } catch (error) {
    devicesEl.replaceChildren(Object.assign(document.createElement("li"), { textContent: `读取失败：${requestError(error)}` }));
  }
}

document.querySelector("#pairing-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const code = document.querySelector("#pairing-code").value.trim();
  if (!/^\d{6}$/.test(code)) return setNotice("请输入六位数字配对码", true);
  try {
    const data = await bridge.apiPost(`pairings/${code}/confirm`, {});
    setNotice(`已允许 ${data.device.display_name} 领取凭证`);
    form.reset();
    await loadDevices();
  } catch (error) { setNotice(requestError(error), true); }
});

document.querySelector("#reload").addEventListener("click", loadDevices);
if (!bridge) {
  setNotice("AstrBot 页面桥接未加载", true);
} else {
  await bridge.ready();
  loadDevices();
}
