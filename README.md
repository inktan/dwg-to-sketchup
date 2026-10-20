# DWG 结构模型

把一张结构施工图 DWG 读成梁、斜梁、柱、墙和楼板，生成 SketchUp 模型（`.skp`）和 Rhino 模型（`.3dm`）。图元和默认图层规则交给 DeepSeek 分析。整张图对不上预定规则时，由 DeepSeek 按结构布置是否合理自行判断。斜梁先取全部梁中心线，再按 `15.850(屋脊)` 所标屋脊线相交或两侧延长 300 mm 分段。

克隆到任意目录即可。建模脚本按自己所在的位置找任务文件，不要求固定盘符。

## 两台电脑

| 目录 | 跑在哪台电脑 | 作用 |
|---|---|---|
| `frontend` | 网页服务器 | 只提供页面，并把 `/api` 转到建模电脑 |
| `backend` | 开着中望 CAD、SketchUp、Rhino 的电脑 | 读 DWG、调用 DeepSeek、往两个软件里建模 |

浏览器只访问网页服务器。SketchUp 的 `127.0.0.1:9876` 和 Rhino 的 `127.0.0.1:2000` 不开放到局域网。中望 CAD 也只接受本机 COM。建模电脑对外只开放 `8780`。

```text
浏览器
  └─ 网页服务器  frontend\server.js
       └─ 建模电脑  backend\server.ps1 :8780
            ├─ 中望 CAD（本机 COM）
            ├─ DeepSeek API
            ├─ SketchUp  127.0.0.1:9876
            └─ Rhino     127.0.0.1:2000
```

## 运行时

网页端用 Node.js，建模端用 Windows PowerShell 5.1。两边的运行时按各自要调用的东西来定，不要对调。

- 网页机不打开中望 CAD、SketchUp、Rhino。`frontend\server.js` 只提供页面，并把 `/api` 转到建模电脑。Node 按 UTF-8 读脚本，用普通套接字监听端口。Windows PowerShell 5.1 会把没有 BOM 的脚本按系统 ANSI 代码页解析（中文系统是 GB2312），汉字的尾字节会吃掉后面的引号，脚本报「字符串缺少终止符」。Node 也不走 HTTP.sys，网页端不需要 `netsh http add urlacl`。
- 建模端留在 PowerShell。中望 CAD 通过本机 COM 连接，这个 COM 只能在单线程套间里调用，所以 `backend\server.ps1` 必须用 `powershell -STA` 启动。含中文的 `.ps1` 保存为 UTF-8 带 BOM。

开发说明：

- 网页端：[frontend/README.md](frontend/README.md)
- 建模端：[backend/README.md](backend/README.md)

## 一次建模做了什么

1. 网页把 DWG、层高、板厚发给建模电脑。
2. 中望 CAD 读出直线、多线、多段线、圆、文字、图块和图层。
3. 图元清单和默认梁、柱、墙、楼板规则一起发给 DeepSeek。
4. DeepSeek 只返回梁中心线编号和截面，不输出斜梁高度。程序按编号还原坐标。若有 `15.850(屋脊)`，旁边最近的平行线是屋脊线。梁中心线与它相交时在交点分成两段；否则两侧向外延长不超过 300 mm，新定位线是交点到较远端点。交点用屋脊标高，另一端用页面上的层高。沿屋脊线的屋脊梁，梁顶也用这个标高，例如 `15.850(屋脊)` 是 15.85 m。结果写成 `floor.json`。
5. SketchUp 执行 `backend\ruby\build.rb`，保存 `model.skp`。
6. Rhino 已在监听时，执行 `backend\rhino\build.py`，保存 `model.3dm`。Rhino 没连上时，这一步记为跳过，SketchUp 模型仍然可用。

每次上传都重新读图、重新建模，不按文件指纹跳过。

## 不要提交的文件

`.env` 里有 DeepSeek 密钥，已被 `.gitignore` 排除。任务目录 `backend\jobs`、生成的 `skp` / `3dm` / `dwg` 也不进仓库。新环境复制 `backend\.env.example` 为 `backend\.env`，再填入密钥。
