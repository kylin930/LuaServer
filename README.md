# LuaServer

在安卓手机上用 Lua 跑起来的本地 HTTP 服务器管理应用（NeLuaJ+ 工程，可直接打包为独立 APK）。

- 应用名 / 包名：`LuaServer` · `com.xiaolin.luaserver`
- 运行环境：NeLuaJ+（LuaJ++ 1.0）+ Android `java.net.ServerSocket` / `java.net.Socket`
- 界面：Material Design 3（`Theme_NeLuaJ_Material3_NoActionBar_ActionOverlay`），蓝绿色主色，深浅色跟随系统

## 1. 快速开始

1. 在 NeLuaJ+ 中打开本工程目录，运行 `main.lua`。
2. 首页点击「启动服务器」。
3. 手机浏览器访问 `http://127.0.0.1:8080`（默认端口）即可看到默认站点。
4. 回到应用，「日志」页可以看到刚才的请求，首页的统计数字会同步增长。
5. 首页再次点击「停止服务器」即可释放端口。

打包：使用 NeLuaJ+ 的打包功能（`init.lua` 已包含 `app_name`、`package_name`、`ver_name`、`ver_code`、`min_sdk`、`target_sdk` 与 `INTERNET` 权限），无需改动 Gradle 或 NDK。

## 2. 实际目录结构

```
LuaServer/
├── main.lua                  # 入口：组装外壳、生命周期（onDestroy 停止服务器）
├── init.lua                  # 打包配置（应用名、包名、SDK、主题、INTERNET 权限）
├── app/screen.lua            # 随工程生成的界面工具（工具栏包装、主题色适配）
├── core/
│   ├── utils.lua             # 单调时钟、大小/时长格式化、URL 编解码、HTML 转义、局域网 IP
│   ├── config.lua            # 配置默认值、校验、SharedPreferences 持久化
│   └── logger.lua            # 线程安全日志队列 + 原子计数器
├── server/
│   ├── server.lua            # ServerSocket 生命周期、accept 线程、固定工作线程池
│   ├── http_parser.lua       # 有上限的 HTTP/1.x 请求解析
│   ├── response.lua          # 状态行、响应头、错误页、文件流写出
│   ├── static_file.lua       # 静态文件托管、路径穿越防护、目录索引、默认站点生成
│   ├── mime.lua              # 扩展名 → MIME
│   └── router.lua            # 方法分发 + 仅本机可访问的状态 API
├── ui/
│   ├── shell.lua             # 工具栏 + 标签页 + 页面切换 + 主线程刷新
│   ├── theme.lua             # MD3 色板与可复用布局构件（卡片、KV、统计格、按钮、输入框）
│   ├── dashboard.lua         # 首页
│   ├── settings.lua          # 服务设置
│   ├── logs.lua              # 请求日志
│   ├── files.lua             # 网站文件
│   └── about.lua             # 关于
├── res/
│   ├── layout/main.lua       # 外壳布局（TabLayout + FrameLayout 容器）
│   └── string/               # 字符串资源（保留工程原有的多语言文件）
├── www/seed.lua              # 默认站点模板（首次运行写入网站根目录）
├── tools/selftest.lua        # 真实 loopback 自测脚本（37 项断言）
└── README.md
```

运行时生成的网站根目录：`<应用私有目录>/www`（默认 `activity.getLuaDir("www")`），
首次启动自动创建 `index.html`、`style.css`、`app.js`、`logo.svg`。

## 3. 模块职责

| 模块 | 职责 |
| --- | --- |
| `core/utils.lua` | 单调时钟计时、字节/时长格式化、`urlDecode`/`urlEncode`、查询串解析、HTML 转义、局域网 IPv4 枚举（10 秒缓存） |
| `core/config.lua` | 默认配置、范围校验、`SharedPreferences` 读写（键 `luaserver_config_v1`）、默认根目录 |
| `core/logger.lua` | 工作线程只做 `AtomicInteger` 计数 + `LinkedBlockingQueue` 入队；主线程 `drain()` 取走并写入有上限的历史 |
| `server/server.lua` | 启停、端口绑定与释放、accept 线程、固定 N 个工作线程、请求处理、异常兜底、重启 |
| `server/http_parser.lua` | 逐字节读取，解析请求行/Header/CRLF/URL/Query/百分号编码，含各项长度与超时限制 |
| `server/response.lua` | 统一状态行与响应头、Content-Length、`Connection: close`、错误页、`Files.copy` 流式发送文件 |
| `server/static_file.lua` | 根目录 canonical 校验防穿越、目录索引页、默认首页、空文件、首启站点生成 |
| `server/mime.lua` | 30+ 扩展名映射，未知回落 `application/octet-stream` |
| `server/router.lua` | GET/HEAD 放行、POST 返回 501、其他方法 405、`/ _api/status` 仅 loopback |
| `ui/theme.lua` | 从 `activity.themeUtil` 取主题色，统一卡片/文字/按钮/输入框构件，失败回退安全色值 |
| `ui/shell.lua` | 外壳与页面切换、定时刷新（经 `call()` 回主线程）、`app.destroy()` |
| `ui/dashboard.lua` | 状态、监听地址、本机/局域网地址、累计/成功/错误/活动连接/运行时长、启停按钮 |
| `ui/settings.lua` | 端口、监听范围（仅本机 / 局域网）、并发上限、超时、首页文件、根目录；保存后按需自动重启 |
| `ui/logs.lua` | 最近请求（时间、方法、URL、状态码、耗时、客户端）、清空、上限 200 条 / 最多渲染 60 行 |
| `ui/files.lua` | 浏览根目录、进入子目录、新建文件夹、新建 HTML、查看信息、删除（长按） |
| `ui/about.lua` | 版本、简介、Android/Lua/Java VM、运行参数、许可与前台服务限制说明 |

## 4. 权限说明

`init.lua` 中只有一项：

```lua
user_permission = {"INTERNET"}
```

- `INTERNET` 用于创建本地监听 Socket；未申请任何存储、位置、相机等敏感权限。
- 网站根目录位于应用私有目录（`getLuaDir("www")`），无需存储权限即可读写。
- 局域网地址通过 `java.net.NetworkInterface` 枚举得到，不需要 `ACCESS_NETWORK_STATE`。

## 5. 安全设计

1. 默认只监听 `127.0.0.1`；局域网模式必须由用户在「设置」中主动切换，页面上有明确风险提示。
2. 路径穿越防护：先做百分号解码，再拒绝任何 `..` 段、反斜杠、控制字符，最后用 `getCanonicalPath()` 校验结果必须落在根目录内（含软链接逃逸）。
3. 请求头上限 8 KB / 单行 4 KB / 最多 64 个 Header / 请求目标 2 KB / 请求体 1 MB，超出分别返回 431、414、413。
4. 每个连接设置 `soTimeout`（默认 10 秒），避免慢连接长期占用工作线程。
5. 不支持的方法返回 405（带 `Allow`），POST 返回 501；没有上传、删除、命令执行、Lua 代码执行等 HTTP 接口。
6. `/_api/status` 只对本机（loopback）返回数据，局域网客户端得到 403。
7. 服务器不是公网服务：局域网模式仅在可信网络中使用。

## 6. 测试方法

### 6.1 内置自测（真机 Socket 验证，无需人工点击）

在 NeLuaJ+ 中运行 `tools/selftest.lua`，它会在 `18086` 端口启动服务器、用真实 Socket 客户端发请求、
再验证停止后端口释放，最后把结果写入工程根目录的 `selftest_report.txt`。

当前实测结果：**37 项断言全部通过**，覆盖

- `GET /`、`/style.css`、`/app.js`、`/logo.svg` 的状态码与 Content-Type
- HEAD 有 `Content-Length` 且无正文
- 404（不存在文件 / 未知扩展名）、403（`../`、`%2e%2e`、混合穿越）、400（非法请求行）
- 401/405/431/414/413 类限制（405 PUT、501 POST、431 超长头、414 超长目标）
- `/_api/status` 返回可解析 JSON、无 index 目录返回索引页
- 4 个并发连接全部 200
- `stop()` 后端口可重新绑定、活动连接归零
- 切到 `0.0.0.0` + 新端口后监听地址与访问均正确

### 6.2 手工验收（按需求逐条）

| 步骤 | 期望 |
| --- | --- |
| 运行 `main.lua`，点击「启动服务器」 | 首页显示「运行中」、`http://127.0.0.1:8080`，按钮变成「停止服务器」 |
| 手机浏览器打开 `http://127.0.0.1:8080` | 显示默认站点（蓝绿色卡片页面） |
| 访问 `/style.css`、`/app.js`、`/logo.svg` | 分别正常返回 CSS、JS、SVG |
| 访问 `/not-exist.html` | 返回 404 页面 |
| `curl -I http://127.0.0.1:8080/` 或浏览器开发者工具 | HEAD 返回 200 且带 Content-Length、无正文 |
| 首页点击「停止服务器」，再次访问 | 浏览器连接失败（端口已释放）；日志页出现「服务器已停止」事件 |
| 设置页切换为「局域网」并保存 | 首页出现 `http://<手机局域网IP>:8080`；同 Wi-Fi 的可信设备可访问 |
| 日志页 | 每次请求一行：时间、方法、URL、状态码、耗时、客户端 IP |
| 文件页 | 能看到 `index.html`、`style.css`、`app.js`、`logo.svg`；可新建文件夹/HTML、删除 |

> 说明：本次开发在真机上完成了自测脚本、页面构建、UI 刷新链路与服务器启停的验证；
> 上面表格中的「手工点击 + 外部浏览器访问」仍需你按步骤确认，未由我代为执行。

## 7. 已实现 / 未实现

已实现：

- HTTP/1.1 GET、HEAD；POST 返回 501；405/403/404/400/413/414/431/500/501/505 状态与统一错误页
- 静态文件托管（HTML/CSS/JS/JSON/TXT/PNG/JPG/SVG/ICO/WebP/WOFF/WOFF2 等）、未知 MIME 回退
- 目录索引页、默认首页、空文件、URL 编码
- 路径穿越防护（含编码与软链接）
- 启动/停止/重启、端口修改、仅本机/局域网监听、并发上限 1–16、请求超时、根目录与首页可配置
- 配置持久化；首启自动生成默认站点
- 首页统计（累计/成功/错误/活动连接/运行时长）、请求日志（上限 + 清空）、网站文件管理、关于页
- 主线程 UI 更新（工作线程不触碰 View）；退出应用停止服务器并释放端口

未实现（第一版有意不做）：

- POST/PUT 请求体解析（返回 501 / 405）
- 断点续传、Range、gzip 压缩、ETag/If-Modified-Since 缓存协商
- HTTPS、Basic 认证、IP 白名单
- HTTP 文件上传/删除接口（安全考虑，管理操作只在应用界面内）
- Android Foreground Service 常驻运行、通知栏控制
- 文件内容编辑器（只有新建 HTML 与删除）

## 8. 已知问题

1. **服务器只在应用前台/进程存活期间运行。** `thread()` 是 Java 线程，不是 Android Service；
   应用被系统回收或用户主动退出后服务停止。这是第一版的明确边界，界面也有说明。
2. `timer()` 回调运行在 `LuaTimer` 线程（不是主线程），因此 `ui/shell.lua` 的刷新通过 `call()` 回到主线程；
   如果后续新增定时逻辑，务必同样包一层 `call()`，否则会抛 `CalledFromWrongThreadException`。
3. 监听范围切换后若原端口被其他应用占用，重启会失败并提示「端口已被占用」；界面此时保持未运行状态。
4. 局域网 IP 通过 `NetworkInterface` 枚举，VPN/多网卡环境下可能选中非预期网卡（优先返回第一个非回环 IPv4）。
5. 目录索引页不含分页，超大目录（数千文件）会一次性渲染。
6. 未做连接数限流之外的背压：并发上限之外的连接在 `pending` 队列（容量 64）里排队，超出会被直接关闭。
7. 静态文件发送用 `Files.copy(Path, OutputStream)`；客户端中途断开时不再记录为 500，但该请求也不会出现在日志中。

## 9. 后续建议

1. 用 `startService("server_service.lua")` + 前台通知实现常驻服务，并处理 Android 12+ 的后台限制。
2. 引入 `Range` + 分块读取，改善大文件与视频播放体验；配合 `ETag`/`If-None-Match` 减少重复传输。
3. 为 POST 增加有上限的请求体解析，提供受 token 保护的最小 JSON API。
4. 增加 LAN 模式下的访问口令（Basic Auth）与客户端白名单，降低误暴露风险。
5. 把日志落盘（环形文件）并支持导出，便于排查长时间运行的问题。
6. 文件页加入文本编辑、重命名、上传（走应用内选择器，不开放 HTTP 上传）。
7. 增加「收藏地址二维码」，方便局域网内其他设备扫码访问。

## 10. 调试提示

- 工程内保留了 NeLuaJ+ 的 `vConsole.lua`，需要悬浮调试窗时在 `main.lua` 末尾加 `require "vConsole"` 即可；
  默认不加载，以免遮挡正式界面。
- `tools/selftest.lua` 可直接作为回归测试：改动服务器核心后先跑它，再看 `selftest_report.txt`。
