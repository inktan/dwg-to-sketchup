# backend

建模电脑上的程序。中望 CAD、SketchUp、Rhino 和这个目录必须在同一台已登录的桌面上。不要把它做成 Windows 服务：这三个软件都要在交互桌面里开着。

这个目录保持 Windows PowerShell，不改成 Node.js。中望 CAD 通过本机 COM 连接，这个 COM 只能在 PowerShell 的单线程套间里调用。网页在另一台电脑上，由 `frontend\server.js` 提供，再把 `/api` 转到这里。

把仓库克隆到本机任意目录。服务、SketchUp 和 Rhino 都从 `backend` 这个文件夹往下找文件。

## 文件

| 路径 | 作用 |
|---|---|
| `server.ps1` | 监听 `8780`，接收上传，驱动读图和建模。修改 `server.ps1`、`lib\*.ps1` 或 `.env` 后自动重启子进程 |
| `.env` | `DEEPSEEK_API_KEY`。从 `.env.example` 复制，不要提交 |
| `lib\Extract-DwgStructure.ps1` | 用中望 CAD 读 DWG，整理图元清单；读图前先关闭上次任务遗留的 `jobs\*source.dwg` 文档 |
| `lib\Invoke-DeepSeekParse.ps1` | 把图元和规则发给 DeepSeek，再还原成梁、柱、墙、楼板 |
| `lib\BuildPipeline.ps1` | 建模流水线与任务锁：任务计数、进度心跳、连接断开自动终止、DeepSeek 分析、驱动 SketchUp/Rhino |
| `lib\Close-ZwcadDialogs.ps1` | 读图时关掉字体替换等弹窗 |
| `lib\Send-SketchUp.ps1` | 连接 `127.0.0.1:9876`，执行 Ruby |
| `lib\Send-Rhino.ps1` | 连接 `127.0.0.1:2000`，发送 Rhino 命令 |
| `ruby\build.rb` | 在已打开的 SketchUp 里创建构件并保存 `model.skp` |
| `ruby\job.txt` | 运行时写入当前任务目录，脚本自己生成 |
| `rhino\build.py` | 在已打开的 Rhino 里创建构件并保存 `model.3dm` |
| `rhino\bridge.py` | Rhino 进程内的监听桥，听 `127.0.0.1:2000` |
| `sketchup\su_mcp\` | SketchUp MCP 插件 |
| `sketchup\boot_sketchup_mcp.rb` | 在已打开的 SketchUp 里加载插件并开始监听 |
| `jobs\<id>\` | 一次任务的 DWG、`floor.json`、`model.skp`、`model.3dm`。运行时生成 |

含中文的 `.ps1` 必须保存为 **UTF-8 带 BOM**。Windows PowerShell 5.1 否则会按系统 ANSI 代码页解析，中文引号会被拆开，整份脚本报语法错误。`lib\Send-Rhino.ps1` 的源码是英文，中文提示在运行时拼出来。

## 启动建模服务

三个软件按下一节准备好之后，在 `backend` 目录执行：

```text
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\server.ps1
```

`-STA` 不能省。中望 CAD 的 COM 只有在单线程套间里才能调用。

`-NoProfile` 不加载个人 PowerShell 配置。`-ExecutionPolicy Bypass` 允许运行脚本。不带参数时，这个进程是热更新父进程：它再拉起一个带 `-Child` 的子进程负责监听。窗口要一直留着，关掉服务就停。

非管理员第一次监听 `http://+:8780/` 会得到 `Access is denied`。这是没有 URL 预留，不是端口被占用。用管理员 PowerShell 执行一次：

```text
netsh http add urlacl url=http://+:8780/ user=Everyone
```

然后 `Ctrl+C` 停掉正在重试的窗口，再执行上面的启动命令。看到 `listening http://+:8780/` 后，本机打开 http://127.0.0.1:8780/api/status 。`zwcad`、`sketchup`、`rhino` 为 `true` 才算三个软件都连上。后端只提供 `/api/*`，页面由前端服务器提供；前端服务器用这台机器的局域网 IP 访问 `8780`，防火墙只对它放行 `8780`。

## 三个软件

### 中望 CAD

没有 TCP 端口。打开 ZWCAD，留在当前登录的桌面里。`server.ps1` 用 `GetActiveObject("ZWCAD.Application")` 连接它。读图时会临时打开 DWG，读完关闭；字体替换一类弹窗由 `Close-ZwcadDialogs.ps1` 关掉。

### SketchUp

插件代码在 `sketchup\su_mcp\main.rb`，监听 `127.0.0.1:9876`。打开 SketchUp 后，Ruby 控制台执行：

把下面路径里的仓库位置换成这台电脑上的实际目录：

```ruby
load 'D:/work/dwg-to-sketchup/backend/sketchup/boot_sketchup_mcp.rb'
```

控制台出现 `MCP: Server started and listening`，并且 `backend\sketchup-mcp-status.txt` 以 `listening` 开头。每次重新打开 SketchUp 都要再执行一次。扩展加载本身不会打开端口。

确认：

```text
netstat -ano | findstr "127.0.0.1:9876"
```

只认 `LISTENING`。

### Rhino

先打开 Rhino 8。在底部命令行执行：

把下面路径里的仓库位置换成这台电脑上的实际目录：

```text
_-RunPythonScript "D:/work/dwg-to-sketchup/backend/rhino/bridge.py"
```

开头的 `_-` 要保留：按英文命令名执行，并且不弹出选文件窗口。成功后日志 `%TEMP%\rhinomcp_bridge.log` 里有 `listening on 127.0.0.1:2000`。使用 2000，不要用 1999。关掉 Rhino 后端口消失，下次重新执行这一句。

确认：

```text
netstat -ano | findstr "127.0.0.1:2000"
```

建模时，桥收到 `run_command`，再执行 `rhino\build.py`。Rhino 没在监听时，任务仍会生成 SketchUp 文件，结果里带一条跳过说明。

## 分析规则

`lib\Invoke-DeepSeekParse.ps1` 里的 `Get-StructureRuleText` 是发给 DeepSeek 的预定规则，主要包括：

- 梁：`s数字-beam`、`s数字-beam-hddn`。平行双线间距 80–1010 mm 时取中线，附近尺寸文字提供梁高。
- 柱：`a数字-cols`、`s数字-cols`，以及面积合适的闭合线和圆。
- 墙：`a数字-wall`、`s数字-wall`。平行双线间距 80–1000 mm。
- 楼板：`slab-otln`、`flor-otln` 的闭合轮廓。没有轮廓时用构件包围盒。

图层整体符合这些规则时按规则归类。整张图的图层、图块和标注都对不上时，不硬套图层名，改由 DeepSeek 根据柱是否落在梁端、梁是否连接支座、墙是否为细长竖向构件、楼板是否覆盖这些构件围成的平面来判断。选中的编号必须来自图元清单，不能编造坐标。结果说明里会写明是命中了规则，还是按结构关系判断的。

DeepSeek 第一次请求开启思考模式。没有返回完整 JSON 时，关闭思考模式再请求一次。

## 并发与任务终止

同一时刻只执行一个建模任务：三个软件共用一个桌面，读图和建模必须串行。建模进行中收到新上传时，接口直接返回「当前已有任务正在建模，请等待它完成后再上传」，页面弹窗提示，不排队。

用户关闭或刷新页面时，前端代理立刻断开与后端的连接；后端进度心跳写失败后，2 秒内自动终止子进程，正在进行的读图、DeepSeek 请求和 SketchUp/Rhino 调用随进程一起结束，父进程随后重启监听进程。这样被中断的任务不会拖进下一个任务：

- 中望 CAD：下次读图前自动关闭上次遗留的 `jobs\*source.dwg` 文档，不影响用户自己打开的图纸。
- SketchUp：每次建模前删除旧任务构件并清理未使用项。
- Rhino：每次建模前删除 `Stru*` 前缀的旧构件。

## 进度

`/api/build` 返回 `application/x-ndjson`。每一行是一个 JSON 对象：

| 字段 | 含义 |
|---|---|
| `status=run` | 新步骤开始 |
| `status=tick` | 同一步骤的心跳，约 2 秒一次；写失败即视为连接断开，后端终止当前任务 |
| `status=done` | 该步骤结束，`stepSeconds` 是这一步的秒数 |
| `step` | 步骤名，例如「读取图纸」「DeepSeek 分析」「写入 SketchUp」 |
| `detail` | 这一步正在做什么 |
| `totalSeconds` | 从本次提交开始的总秒数 |

页面用这些字段显示当前说明、本步用时和已完成步骤。

## 下载

`GET /api/download/<任务id>?format=skp` 返回 `jobs\<id>\model.skp`。`format=rhino` 返回 `model.3dm`。任务目录由服务在运行时创建，不需要提前准备。
