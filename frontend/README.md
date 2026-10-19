# frontend

网页服务器上的程序。它不安装中望 CAD、SketchUp 或 Rhino，也不保存建模任务。

## 文件

| 文件 | 作用 |
|---|---|
| `web.ps1` | 监听本机端口，提供页面，并把 `/api` 原样转到建模电脑 |
| `www\index.html` | 上传页 |
| `www\app.css` | 页面样式 |
| `www\app.js` | 上传、进度和下载 |

页面请求都是相对路径（`/api/build`、`/api/status`、`/api/download/...`）。所以页面必须由 `web.ps1` 提供，不能只把 `www` 丢到一台没有反向代理的静态服务器上。

## 启动

在本目录执行：

```text
powershell -NoProfile -ExecutionPolicy Bypass -File web.ps1 -Upstream http://10.1.12.30:8780
```

`-Upstream` 改成建模电脑的地址。默认端口是 `8780`，可用 `-Port 80` 改成其它端口。

首次在非管理员账户下监听 `http://+:端口/` 会报 `Access is denied`。用管理员 PowerShell 执行一次：

```text
netsh http add urlacl url=http://+:8780/ user=Everyone
```

端口不是 8780 时，把命令里的端口改成实际端口。然后重新运行 `web.ps1`。看到 `网页 http://+:8780/  接口转发到 ...` 即已启动。

## 请求怎么走

| 路径 | 处理 |
|---|---|
| `/`、`/index.html`、`/app.css`、`/app.js` | 读本目录的 `www` |
| `/api/...` | 转发到 `-Upstream`，包括上传正文、NDJSON 进度和文件下载 |

转发使用 `HttpWebRequest`，超时 15 分钟。进度响应是 `application/x-ndjson`。上游没有 `Content-Length` 时，本机按 64KB 一块往外刷，避免整段进度被缓冲到结束才显示。上游连不上时返回 HTTP 502，正文是 `{"ok":false,"error":"建模电脑没有连上"}`。

建模电脑的 `backend` 自己也能打开页面。改页面时同时改 `frontend\www` 和 `backend\www`，两处保持一致。用户平时打开的是这一侧。

## 页面行为

- 上传 DWG，填写层高（默认 3000 mm）和板厚（默认 130 mm）。
- 提交后显示当前步骤在做什么，以及本步用时和总用时。完成的步骤留在列表里。
- 结果里给出梁、柱、墙、楼板数量，以及 SketchUp、Rhino 的下载链接。
- 不查询历史上传，也不因为同一张图已经生成过就跳过建模。
