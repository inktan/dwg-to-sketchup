const statusEl = document.querySelector("#status");
const form = document.querySelector("#form");
const fileInput = document.querySelector("#file");
const drop = document.querySelector("#drop");
const dropTitle = document.querySelector("#dropTitle");
const submitBtn = document.querySelector("#submit");
const resultEl = document.querySelector("#result");
const resultTitle = document.querySelector("#resultTitle");
const countsEl = document.querySelector("#counts");
const sourceEl = document.querySelector("#source");
const downloadsEl = document.querySelector("#downloads");
const warningsEl = document.querySelector("#warnings");
const errorEl = document.querySelector("#error");
const progressEl = document.querySelector("#progress");
const progressStage = document.querySelector("#progressStage");
const progressTime = document.querySelector("#progressTime");
const progressDetail = document.querySelector("#progressDetail");
const progressLog = document.querySelector("#progressLog");

let progressTimer = null;
let progressStarted = 0;
let progressCurrent = null;
let progressFinishedTitle = "各步骤已完成";

function formatDuration(total) {
  const seconds = Math.max(0, total);
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return String(m).padStart(2, "0") + ":" + String(s).padStart(2, "0");
}

function setBusy(busy) {
  submitBtn.disabled = busy;
  if (!busy) {
    submitBtn.textContent = "生成结构模型";
    stopProgress();
  }
}

function renderProgress() {
  const total = formatDuration(Math.max(0, Math.floor((Date.now() - progressStarted) / 1000)));
  if (progressCurrent) {
    const stepSec = Math.max(0, Math.floor((Date.now() - progressCurrent.started) / 1000));
    progressStage.textContent = progressCurrent.step;
    progressDetail.hidden = !progressCurrent.detail;
    progressDetail.textContent = progressCurrent.detail || "";
    progressTime.textContent = "本步 " + formatDuration(stepSec) + " · 总计 " + total;
    submitBtn.textContent = progressCurrent.step + " · 本步 " + formatDuration(stepSec);
    return;
  }
  progressStage.textContent = progressFinishedTitle;
  progressDetail.hidden = true;
  progressTime.textContent = "总计 " + total;
}

function startProgress() {
  progressStarted = Date.now();
  progressCurrent = {
    step: "正在准备",
    detail: "正在把图纸提交到建模电脑。",
    started: progressStarted
  };
  progressFinishedTitle = "各步骤已完成";
  progressLog.innerHTML = "";
  progressEl.hidden = false;
  renderProgress();
  if (progressTimer) clearInterval(progressTimer);
  progressTimer = setInterval(renderProgress, 250);
}

function stopProgress() {
  if (progressTimer) clearInterval(progressTimer);
  progressTimer = null;
}

function appendDone(step, detail, seconds) {
  const item = document.createElement("li");
  const name = document.createElement("span");
  name.className = "step-name";
  name.textContent = step;
  const time = document.createElement("span");
  time.className = "step-time";
  time.textContent = "用时 " + formatDuration(seconds);
  const text = document.createElement("span");
  text.className = "step-detail";
  text.textContent = detail || "";
  item.append(name, time, text);
  progressLog.appendChild(item);
}

function applyProgress(message) {
  const step = message.step || message.stage || "";
  if (!step) return;
  const detail = message.detail || "";
  const status = message.status || (message.live ? "tick" : "run");
  if (typeof message.totalSeconds === "number") {
    progressStarted = Date.now() - message.totalSeconds * 1000;
  }
  if (status === "done") {
    appendDone(step, detail, Number(message.stepSeconds) || 0);
    if (progressCurrent && progressCurrent.step === step) progressCurrent = null;
    progressFinishedTitle = "各步骤已完成";
    renderProgress();
    return;
  }
  if (status === "tick" && progressCurrent && progressCurrent.step === step) {
    if (detail) progressCurrent.detail = detail;
    renderProgress();
    return;
  }
  if (progressCurrent && progressCurrent.step !== step && progressCurrent.step !== "正在准备") {
    appendDone(
      progressCurrent.step,
      progressCurrent.detail,
      Math.max(0, Math.floor((Date.now() - progressCurrent.started) / 1000))
    );
  }
  const already = Number(message.stepSeconds) || 0;
  progressCurrent = {
    step,
    detail,
    started: Date.now() - already * 1000
  };
  renderProgress();
}

function settleProgress() {
  if (!progressCurrent) {
    renderProgress();
    return;
  }
  appendDone(
    progressCurrent.step,
    progressCurrent.detail,
    Math.max(0, Math.floor((Date.now() - progressCurrent.started) / 1000))
  );
  progressCurrent = null;
  progressFinishedTitle = "已中断";
  renderProgress();
}

function showError(message) {
  errorEl.hidden = false;
  errorEl.textContent = message;
}

function clearError() {
  errorEl.hidden = true;
  errorEl.textContent = "";
}

function asList(value) {
  if (Array.isArray(value)) return value.filter(Boolean);
  if (value) return [value];
  return [];
}

function downloadButtons(data) {
  const files = data.files || {};
  const names = data.filenames || {};
  if (!files.skp && data.download) {
    files.skp = data.download;
    names.skp = data.filename || "结构模型.skp";
  }
  const items = [
    ["skp", "下载 SketchUp .skp"],
    ["rhino", "下载 Rhino .3dm"]
  ];
  return items.filter(([key]) => files[key]).map(([key, label]) => {
    const name = names[key] || label;
    return `<a class="download" href="${files[key]}" download="${name}">${label}</a>`;
  }).join("");
}

function showResult(data) {
  resultEl.hidden = false;
  resultEl.scrollIntoView({ behavior: "smooth", block: "start" });
  const counts = data.counts || {};
  const rows = [
    ["梁", counts.beams],
    ["柱", counts.columns],
    ["墙", counts.walls],
    ["楼板", counts.slab]
  ];
  countsEl.innerHTML = rows.map(([name, value]) =>
    `<div><dt>${name}</dt><dd>${value ?? 0}</dd></div>`
  ).join("");
  const usage = data.usage || {};
  const hosts = data.hosts || {};
  let text = data.summary || "构件已经生成。";
  if (data.story != null && data.story !== "") text += ` 层高 ${data.story} mm，板厚 ${data.slabThick} mm。`;
  if (usage.prompt) text += ` deepseek-flash 输入 ${usage.prompt}、输出 ${usage.completion} tokens。`;
  const placed = ["SketchUp"];
  if (hosts.rhino) placed.push("Rhino");
  text += "模型已放入" + placed.join("、") + "。";
  sourceEl.textContent = text;
  resultTitle.textContent = "模型已生成";
  const warnings = asList(data.warnings);
  warningsEl.hidden = warnings.length === 0;
  warningsEl.textContent = warnings.join(" ");
  downloadsEl.innerHTML = downloadButtons(data);
}

fileInput.addEventListener("change", () => {
  const file = fileInput.files[0];
  dropTitle.textContent = file ? file.name : "选择或拖入 DWG";
});

["dragover", "dragenter"].forEach((name) => {
  drop.addEventListener(name, (event) => {
    event.preventDefault();
    drop.classList.add("over");
  });
});
["dragleave", "drop"].forEach((name) => {
  drop.addEventListener(name, (event) => {
    event.preventDefault();
    drop.classList.remove("over");
  });
});
drop.addEventListener("drop", (event) => {
  const file = event.dataTransfer.files[0];
  if (!file) return;
  const transfer = new DataTransfer();
  transfer.items.add(file);
  fileInput.files = transfer.files;
  dropTitle.textContent = file.name;
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  clearError();
  const file = fileInput.files[0];
  if (!file) {
    showError("请先选择一个 DWG 文件。");
    return;
  }
  const body = new FormData();
  body.append("file", file);
  body.append("story", document.querySelector("#story").value);
  body.append("slab", document.querySelector("#slab").value);
  await run("/api/build", { method: "POST", body });
});

async function readEvents(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let result = null;
  while (true) {
    const chunk = await reader.read();
    buffer += decoder.decode(chunk.value || new Uint8Array(), { stream: !chunk.done });
    const lines = buffer.split("\n");
    buffer = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      const message = JSON.parse(line);
      if (message.type === "progress") applyProgress(message);
      if (message.type === "error") throw new Error(message.error || "生成失败");
      if (message.type === "result") result = message;
    }
    if (chunk.done) break;
  }
  if (buffer.trim()) {
    const message = JSON.parse(buffer);
    if (message.type === "error") throw new Error(message.error || "生成失败");
    if (message.type === "result") result = message;
  }
  if (!result) throw new Error("服务器没有返回结果");
  return result;
}

async function run(url, options) {
  setBusy(true);
  startProgress();
  resultEl.hidden = true;
  try {
    const response = await fetch(url, options);
    const type = response.headers.get("content-type") || "";
    if (!type.includes("ndjson")) {
      const data = await response.json();
      if (!response.ok || !data.ok) throw new Error(data.error || "生成失败");
      showResult(data);
      return;
    }
    const data = await readEvents(response);
    if (!data.ok) throw new Error(data.error || "生成失败");
    showResult(data);
  } catch (error) {
    showError(error.message || "生成失败");
  } finally {
    settleProgress();
    setBusy(false);
  }
}

function setHostStatus(key, connected) {
  const node = statusEl.querySelector('[data-key="' + key + '"]');
  if (!node) return;
  node.classList.toggle("ok", connected);
  node.classList.toggle("bad", !connected);
  const note = node.querySelector("small");
  if (note) note.textContent = connected ? "已连接" : "未连接";
}

async function refreshStatus() {
  try {
    const response = await fetch("/api/status");
    const data = await response.json();
    setHostStatus("zwcad", !!data.zwcad);
    setHostStatus("sketchup", !!data.sketchup);
    setHostStatus("rhino", !!data.rhino);
  } catch {
    ["zwcad", "sketchup", "rhino"].forEach((key) => setHostStatus(key, false));
  }
}

localStorage.removeItem("dwg-deepseek-key");
refreshStatus();
