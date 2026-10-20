# frontend

网页服务器上的程序。它不安装中望 CAD、SketchUp 或 Rhino，也不保存建模任务。

这里用 Node.js，不用 PowerShell。这台机器不调用中望 CAD。Windows PowerShell 5.1 会把没有 BOM 的 `.ps1` 按 GB2312 解析，中文后面的 `"` 会被吃掉，脚本报「字符串缺少终止符」。Node 按 UTF-8 读 `server.js`，并用普通套接字监听，不需要 `netsh http add urlacl`。建模仍在另一台电脑的 PowerShell 里完成：中望 CAD 的 COM 只能在单线程套间中调用，启动必须带 `-STA`。

## 文件

| 文件 | 作用 |
|---|---|
| `server.js` | 监听本机端口，提供页面，并把 `/api` 原样转到建模电脑 |
| `package.json` | `npm start` 入口，没有第三方依赖 |
| `www\index.html` | 上传页 |
| `www\app.css` | 页面样式 |
| `www\app.js` | 上传、进度和下载 |

页面请求都是相对路径（`/api/build`、`/api/status`、`/api/download/...`）。所以页面必须由 `server.js` 提供，不能只把 `www` 丢到一台没有反向代理的静态服务器上。

## 启动

需要 Node.js 18 或更新版本。在本目录执行：

```text
node server.js --upstream http://10.1.12.30:8780
```

`--upstream` 改成建模电脑的地址。默认端口是 `8780`，可用 `--port 80` 改成其它端口。`npm start -- --upstream http://10.1.12.30:8780` 等价。

看到 `网页 http://0.0.0.0:8780/  接口转发到 ...` 即已启动。浏览器打开 http://127.0.0.1:8780/ 。端口小于 1024 时，Windows 需要用管理员身份运行。

## 请求怎么走

| 路径 | 处理 |
|---|---|
| `/`、`/index.html`、`/app.css`、`/app.js` | 读本目录的 `www` |
| `/api/...` | 转发到 `--upstream`，包括上传正文、NDJSON 进度和文件下载 |

转发超时 15 分钟。进度响应是 `application/x-ndjson`。上游没有 `Content-Length` 时按块往外写，并关闭 Nagle，避免整段进度被缓冲到结束才显示。上游连不上时返回 HTTP 502，正文是 `{"ok":false,"error":"建模电脑没有连上"}`。

建模电脑的 `backend` 自己也能打开页面。改页面时同时改 `frontend\www` 和 `backend\www`，两处保持一致。用户平时打开的是这一侧。

## 页面行为

- 上传 DWG，填写层高（默认 3000 mm）和板厚（默认 130 mm）。层高用于水平梁、柱、墙和楼板。斜梁低点用图纸上的 `12.600(屋檐)`；没有屋檐文字时低点为 0。屋脊端和沿屋脊的屋脊梁梁顶，用图纸上 `15.850(屋脊)` 的标高。梁中心线与屋脊线不相交时，两侧向外延长不超过 300 mm。
- 提交后显示当前步骤在做什么，以及本步用时和总用时。完成的步骤留在列表里。
- 结果里给出梁、柱、墙、楼板数量，以及 SketchUp、Rhino 的下载链接。
- 不查询历史上传，也不因为同一张图已经生成过就跳过建模。
