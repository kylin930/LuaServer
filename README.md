# LuaServer v0.2

安卓手机上的轻量本地 HTTP 服务器，业务逻辑用 Lua 编写，通过 NeLuaJ+ 的 Java 桥接调用 Android 原生 API。
本轮升级重点：**HTTP/1.1 能力补全** + **Android 前台服务常驻** + **管理界面完善**。

- 应用名 / 包名：`LuaServer` / `com.xiaolin.luaserver`（v0.2 / ver_code 2）
- 运行环境：NeLuaJ+（LuaJ++）+ `java.net.ServerSocket`，无 NDK、无 Termux、无 Gradle 依赖
- 界面：Material Design 3，蓝绿色主色，深浅色跟随系统

## 0. v0.2 相对 v0.1 的变化

| 方向 | 变化 |
| --- | --- |
| 后台运行 | **服务器改由 `LuaService` 前台服务托管**，关闭 Activity 后继续提供服务（实测 Activity 关闭后心跳持续 3 分钟以上不断） |
| 状态通道 | 新增 `core/store.lua`：SharedPreferences JSON 心跳 + 命令队列，取代原来 Activity 内的直接引用 |
| HTTP 方法 | 新增 POST 请求体读取、`OPTIONS`、正确的 `Allow` 头；静态路径 POST 返回 405 |
| 缓存 | 新增 `ETag` / `Last-Modified` / `If-None-Match` / `If-Modified-Since` → 304，Cache-Control 可配置 4 档 |
| 安全 | 目录索引**默认关闭**（403）；拦截 `Transfer-Encoding`+`Content-Length` 冲突；文件不可读返回 403 |
| 并发 | 修复停启竞态：每次运行使用独立队列，`stop()` 等待工作线程真正退出 |
| 统计 | 新增平均响应时间、已发送字节数 |
| UI | 首页新增平均耗时/网站目录/已发送/复制地址；日志页新增搜索与状态码过滤；设置页新增目录索引与缓存策略 |

## 1. 快速开始

1. 在 NeLuaJ+ 中打开工程目录，运行 `main.lua`。
2. 首页点「启动服务器」→ 通知栏出现「LuaServer 正在运行」常驻通知。
3. 手机浏览器访问 `http://127.0.0.1:8080`。
4. 切到其他应用或锁屏，服务器继续工作；回到应用可看到统计与日志。
5. 首页点「停止服务器」→ 通知消失，端口释放。

打包：用 NeLuaJ+ 打包功能（`init.lua` 已含 `app_name`、`package_name`、`ver_name`、`ver_code`、`min_sdk`、`target_sdk`、主题与权限）。

## 2. 实际目录结构

```
LuaServer/
├── main.lua                 # Activity 入口：组装界面 + 生命周期（不停止服务器）
├── service.lua              # ★ Android 前台服务入口：托管 HTTP 服务器
├── init.lua                 # 打包配置（版本 0.2 + 权限）
├── app/screen.lua           # 工程自带界面工具（工具栏/主题适配）
├── core/
│   ├── utils.lua            # 时钟、格式化、URL 编解码、HTTP 日期解析、局域网 IP
│   ├── config.lua           # 配置默认值/校验/持久化（含目录索引、缓存策略）
│   ├── logger.lua           # 线程安全日志与计数（含平均响应时间、字节数、快照导出）
│   ├── store.lua            # ★ Service↔Activity 状态与命令通道
│   └── controller.lua       # ★ Activity 侧控制器（下发命令、拉取状态）
├── server/
│   ├── host.lua             # ★ 服务器宿主：通知、心跳、命令处理、前台服务生命周期
│   ├── server.lua           # ServerSocket 生命周期、accept 线程、固定工作线程池
│   ├── http_parser.lua      # 有上限的请求解析（请求行/Header/请求体/TE 冲突校验）
│   ├── response.lua         # 响应写出、缓存协商、错误页、流式文件发送
│   ├── static_file.lua      # 静态托管、穿越防护、目录索引（可选）、默认站点
│   ├── mime.lua             # 扩展名 → MIME
│   └── router.lua           # 方法分发 + 仅本机可访问的 API
├── ui/                      # shell / theme / dashboard / settings / logs / files / about
├── res/layout/main.lua      # 外壳布局（TabLayout + FrameLayout）
├── res/string/              # 字符串资源（保留工程原有文件）
├── www/                     # 默认站点模板（seed.lua + 已生成的静态文件）
└── tools/
    ├── selftest.lua         # HTTP 核心自测（91 项断言，真机 Socket 验证）
    └── verify_service.lua   # 后台服务端到端验证
```

网站根目录：`<应用私有目录>/www`。仅在**目录新建或为空**时写入默认站点，不覆盖用户内容。

## 3. 架构：Activity / Service 如何协作

真机探测确认的三条关键事实（决定了本版架构）：

1. `LuaService` 与 `LuaActivity` 运行在**各自独立的 Lua 状态**，全局变量不共享。
2. 两者的 `getSharedData` / `setSharedData` 指向同一份 SharedPreferences，**双向可见**。
3. Service 内 **没有** `activity`、`call`，只有 `thread` / `timer` / `require` / `json` / `file`。

因此数据流是：

```
Activity（UI）                          Service（服务器）
   │ 写命令 JSON + startService ────────►  onStartCommand → beat()
   │                                        ├─ readCommand → start/stop/restart/reload/clearLogs
   │                                        ├─ Server(ServerSocket, worker pool)
   │                                        └─ 每秒写状态快照（含日志）到 SharedPreferences
   │ ◄──────────── 读快照 + 心跳判断存活 ───┘
```

- Activity 每 300ms 轮询、按运行状态节流（运行 800ms / 停止 2s）刷新界面。
- `Store.isFresh()` 同时校验单调时钟与墙钟：设备重启或服务被回收后都会判为「不新鲜」，避免显示过期状态。
- UI 更新走 `timer → call()` 回到主线程（`timer` 回调运行在 `LuaTimer` 线程，直接操作 View 会抛 `CalledFromWrongThreadException`）。

## 4. 权限说明

```lua
user_permission = {
  "INTERNET",                      -- 创建本地监听 Socket
  "FOREGROUND_SERVICE",            -- 前台服务
  "FOREGROUND_SERVICE_DATA_SYNC",  -- 前台服务类型（数据同步）
  "POST_NOTIFICATIONS",            -- Android 13+ 显示常驻通知
  "WAKE_LOCK",                     -- 锁屏时继续处理请求
}
```

未申请存储、位置、相机等敏感权限；网站根目录位于应用私有目录，无需存储权限。

> 注意：真机探测显示本机 `areNotificationsEnabled()` 返回 false。若通知未显示，需在系统设置中为本应用开启通知权限。

## 5. HTTP 能力清单

| 项 | 实现 |
| --- | --- |
| 方法 | GET、HEAD、POST、OPTIONS；其他方法 405 + `Allow` |
| HEAD | 与 GET 相同的状态行与 Header（含真实 `Content-Length`），不发送正文 |
| POST | 读取 `Content-Length` 指定请求体（上限 1 MB）；`/_api/echo` 回显；静态路径 405 |
| OPTIONS | 204 + `Allow: GET, HEAD, OPTIONS`（API 路径额外含 POST） |
| 请求限制 | 单行 4 KB、请求头总 8 KB、Header 64 个、目标 2 KB、请求体 1 MB |
| 请求走私 | `Transfer-Encoding` 与 `Content-Length` 同时出现 → 400 |
| 缓存 | `ETag` + `Last-Modified`；`If-None-Match` / `If-Modified-Since` → 304 |
| Cache-Control | 4 档：`no-store` / `no-cache`（协商） / `max-age=300` / `max-age=86400` |
| 超时 | 每个连接 `soTimeout`（可配 1000–60000 ms） |
| 并发 | accept 线程 + 固定 N 个工作线程（1–16，默认 4）+ 容量 64 的等待队列 |
| 大文件 | `Files.copy(Path, OutputStream)` 流式分块写入，不整体载入内存（实测 512 KB / 1.9 s） |
| 中文文件名 | 支持 URL 编码与 UTF-8 原名 |

## 6. 安全设计

1. 默认只监听 `127.0.0.1`；局域网必须由用户在设置中主动切换，界面有风险提示。
2. 路径穿越防护四层：百分号解码后拒绝 `..` 段 / 反斜杠 / 控制字符 / `"?*<>|` / 超长名 → `getCanonicalPath()` 复核必须落在根目录内（可防符号链接逃逸）。
3. 目录索引**默认关闭**，无默认首页的目录返回 403，不暴露文件列表。
4. 文件不可读返回 403（不是 500）。
5. 管理 API（`/_api/status`、`/_api/echo`）**仅 loopback 可访问**，局域网客户端得到 403。
6. 不提供 HTTP 文件上传/删除、Lua 执行、系统命令执行。
7. 停止服务时关闭 ServerSocket + 排队连接 + 活动连接，并等待工作线程退出后才返回。

## 7. 测试

### 7.1 已实际执行并通过

**HTTP 核心自测**：运行 `tools/selftest.lua` → 结果写入 `selftest_report.txt`，**91 项断言全部通过**，覆盖：

- 静态资源与 MIME（16 种扩展名 + 未知回落）
- HEAD 与 GET 的 Content-Length 一致、无正文
- POST 请求体读取（含中文 JSON）、空体、静态路径 405
- OPTIONS 204 与 Allow（普通路径 / API 路径 / 405 响应头）
- ETag、Last-Modified、If-None-Match → 304、If-Modified-Since → 304、不匹配 → 200
- 目录索引关闭 → 403；开启 → 200 且列出文件
- 404 / 403（`../`、`%2e%2e`、混合）/ 400 / 431 / 414 / 413 / TE+CL 冲突
- 中文文件名（URL 编码与混合编码）
- 512 KB 大文件完整性与耗时（1.9 s）
- 空文件（Content-Length 0、无正文）
- 4 并发全部 200（原子计数器计数）
- 停止后端口可重新绑定、活动连接归零、平均响应时间已统计
- 0.0.0.0 监听与新端口

**后台服务链路**：`tools/verify_service.lua` 已验证到——命令下发后 Service 真实启动、
状态快照 `running=true / fresh=true` 回传、端口占用错误能正确经 `lastError` 传到 UI。
（该脚本首次运行时因残留实例占用 8080 而中断，已改为使用独立端口 18095 并加入清理步骤，
但修正后的完整跑通尚未执行，见 §7.3。）

### 7.2 手工验收步骤

| 步骤 | 期望 |
| --- | --- |
| 运行 `main.lua`，点「启动服务器」 | 首页显示运行中、地址 `http://127.0.0.1:8080`、按钮变「停止服务器」、通知栏出现常驻通知 |
| 浏览器打开该地址 | 显示默认站点 |
| 按 Home 键切到桌面，等 30 s，再回应用 | 首页仍显示运行中，运行时长在增长（服务未中断） |
| 切到其他 App 期间用另一台设备/浏览器访问（需先开局域网） | 仍能访问 |
| 锁屏 1 分钟后解锁回应用 | 服务仍在运行 |
| 停止服务器后再访问 | 连接失败（端口已释放）、通知消失 |
| 日志页 | 每请求一行；搜索框输入 `/style` 可过滤；点 `4xx` 只显示错误请求 |
| 设置页开启目录索引并保存 | 访问无 index 的子目录从 403 变为文件列表 |
| 设置页切换缓存策略为长缓存并保存 | 响应 `Cache-Control: public, max-age=86400` |

### 7.3 尚未执行（需要你在真机上跑一次）

- `tools/verify_service.lua` 修正后的完整通过（含真实 HTTP 请求、统计回传、停止后端口释放）
- Activity 重建（旋转屏幕）后状态是否正常恢复
- 长时间后台（>30 分钟）与系统省电策略下的存活表现
- 另一台设备经局域网访问

## 8. 已完成 / 未完成

**已完成**：前述全部 HTTP 能力、前台服务常驻与通知、SharedPreferences 状态通道、
启停/重启/配置热更新、路径穿越防护、目录索引开关、缓存策略、平均响应时间统计、
日志搜索与过滤、文件管理、复制访问地址、Activity 销毁不停服。

**未完成 / 有意不做**：
- HTTP/2、WebSocket、chunked 请求体解析（明确返回 501）
- Range 断点续传 / 分块下载（响应头中显式声明 `Accept-Ranges: none`）
- HTTPS、Basic 认证、IP 白名单
- HTTP 层文件上传/删除（管理操作只在应用界面内）
- 通知栏「停止服务」按钮（跨进程广播在当前运行时下未验证，未实现）
- 开机自启、服务崩溃自愈

## 9. 已知限制

1. **Android 后台限制**：前台服务能显著延长存活，但系统在极端内存压力或厂商省电策略下仍可能回收进程。本应用不承诺永久运行，也不使用隐藏进程、自启绕过等不可靠方案。
2. **通知权限**：Android 13+ 需要用户手动授予通知权限；未授予时服务仍能运行，但通知不可见（会影响用户感知与系统保活倾向）。
3. **服务与 Activity 是两个 Lua 状态**：Service 内的日志/统计无法被 Activity 直接读取，必须经 SharedPreferences 序列化；因此日志上限为 120 条，随心跳整体下发。
4. **停止响应有约 1 s 延迟**：Activity 发命令后需等服务下一次心跳（1 s）才反映「已停止」。
5. **端口占用**：若上一次服务实例未完全退出，新实例会提示「端口已被占用，请更换端口」，此时需在设置中换端口或重开应用。
6. **局域网 IP 选择**：`NetworkInterface` 枚举取第一个非回环 IPv4，VPN/多网卡环境可能选中非预期网卡。
7. **目录索引无分页**：超大目录一次性渲染。
8. **大文件发送**：依赖 `Files.copy` 的流式复制；发送期间若文件被修改，实际字节数可能与 `Content-Length` 不一致。

## 10. APK 打包

1. NeLuaJ+ 中打开工程根目录。
2. 确认 `init.lua`：`package_name = "com.xiaolin.luaserver"`、`ver_name = "0.2"`、`ver_code = "2"`、权限列表（见 §4）。
3. 使用 IDE 的打包功能生成 APK。
4. 安装后首次启动：若系统未授予通知权限，进入「应用信息 → 通知」手动开启。
5. 打包后网站根目录为应用私有目录下的 `www`（首次运行自动创建并写入默认站点）。

## 11. 调试

- `tools/selftest.lua`：HTTP 核心回归，改动 `server/` 后先跑它。
- `tools/verify_service.lua`：后台服务链路验证（使用端口 18095）。
- 服务运行期异常会写入应用私有目录的 `luaserver_service_error.txt`；UI 刷新异常写入 `luaserver_ui_error.txt`。
- 需要悬浮调试窗时，在 `main.lua` 末尾加 `require "vConsole"`（默认不加载）。
