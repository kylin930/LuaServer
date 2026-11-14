-- tools/selftest.lua — HTTP 核心自测（在真机上用真实 Socket 验证）
--
-- 用法：在 NeLuaJ+ 中直接运行本文件。结果写入工程根目录 selftest_report.txt。
-- 注意：设备禁止主线程做网络操作，因此客户端也运行在 thread() 里。
local config = require "core.config"
local Logger = require "core.logger"
local ServerModule = require "server.server"

local StringCls = luajava.bindClass "java.lang.String"
local SocketCls = luajava.bindClass "java.net.Socket"
local InetSocketAddress = luajava.bindClass "java.net.InetSocketAddress"
local ServerSocket = luajava.bindClass "java.net.ServerSocket"
local ThreadCls = luajava.bindClass "java.lang.Thread"
local File = luajava.bindClass "java.io.File"
local fileMod = file
local spawn = thread

local PORT = 18086

-- 本脚本位于 tools/ 下，getLuaDir() 是脚本所在目录，需显式定位工程根
local projectDir = activity.getLuaDir()
if string.sub(projectDir, -6) == "/tools" then
  projectDir = string.sub(projectDir, 1, #projectDir - 6)
end
local WEB_ROOT = projectDir .. "/www"
local REPORT_PATH = projectDir .. "/selftest_report.txt"

local results = {}
local state = { done = false, error = nil }

local function check(name, passed, detail)
  results[#results + 1] = { name = name, passed = passed and true or false, detail = detail or "" }
end

--- 发一个原始 HTTP 请求，返回响应全文
local function request(rawRequest, port)
  port = port or PORT
  local socket = SocketCls()
  local ok, err = pcall(function()
    socket.connect(InetSocketAddress("127.0.0.1", port), 3000)
    socket.setSoTimeout(4000)
    local out = socket.getOutputStream()
    out.write(StringCls(rawRequest).getBytes("UTF-8"))
    out.flush()
  end)
  if not ok then
    pcall(function() socket.close() end)
    return nil, tostring(err)
  end
  local input = socket.getInputStream()
  local chunks, total = {}, 0
  local readOk, readErr = pcall(function()
    while true do
      local byte = input.read()
      if byte == -1 then break end
      total = total + 1
      -- 上限放宽到 4 MB，避免大文件测试时把正文截断（header 也占额度）
      if total > 4194304 then break end
      chunks[#chunks + 1] = string.char(byte)
    end
  end)
  pcall(function() socket.close() end)
  if not readOk then return table.concat(chunks), tostring(readErr) end
  return table.concat(chunks)
end

--- 拆分状态码、Header 表、正文
local function split(response)
  local text = response or ""
  local code = tonumber(string.match(text, "^HTTP/1%.1 (%d%d%d)")) or 0
  local pos = string.find(text, "\r\n\r\n", 1, true)
  local body = pos and string.sub(text, pos + 4) or ""
  local headerText = pos and string.sub(text, 1, pos - 1) or text
  local headers = {}
  for line in string.gmatch(headerText, "[^\r\n]+") do
    local name, value = string.match(line, "^([%w%-_]+):%s*(.*)$")
    if name then headers[string.lower(name)] = value end
  end
  return code, headers, body
end

local function get(path, extraHeaders)
  local raw = "GET " .. path .. " HTTP/1.1\r\nHost: localhost\r\n" .. (extraHeaders or "") .. "\r\n"
  return split(request(raw))
end

local tests = {}

-- 1. 基础静态资源与 MIME
tests[#tests + 1] = { "静态资源与 MIME", function()
  local code, headers, body = get("/")
  check("GET / -> 200", code == 200, "实际 " .. code)
  check("HTML Content-Type", (headers["content-type"] or ""):find("text/html", 1, true) ~= nil,
    headers["content-type"] or "nil")
  check("正文含 LuaServer", body:find("LuaServer", 1, true) ~= nil, "长度 " .. #body)

  local expect = {
    { "/style.css", "text/css" },
    { "/app.js", "javascript" },
    { "/logo.svg", "image/svg" },
  }
  for i = 1, #expect do
    local c, h = get(expect[i][1])
    check(expect[i][1] .. " -> 200", c == 200, "实际 " .. c)
    check(expect[i][1] .. " MIME 含 " .. expect[i][2],
      (h["content-type"] or ""):find(expect[i][2], 1, true) ~= nil, h["content-type"] or "nil")
  end

  local c2, h2 = get("/unknown-ext.xyz")
  check("未知扩展名 -> 404", c2 == 404, "实际 " .. c2)
end }

-- 2. 补充 MIME 类型（图片/PDF/字体/音视频）
tests[#tests + 1] = { "扩展 MIME 映射", function()
  local MIME = require "server.mime"
  local cases = {
    { "a.png", "image/png" }, { "a.jpg", "image/jpeg" }, { "a.jpeg", "image/jpeg" },
    { "a.gif", "image/gif" }, { "a.webp", "image/webp" }, { "a.ico", "image/x-icon" },
    { "a.pdf", "application/pdf" }, { "a.zip", "application/zip" },
    { "a.woff", "font/woff" }, { "a.woff2", "font/woff2" },
    { "a.mp3", "audio/mpeg" }, { "a.mp4", "video/mp4" },
    { "a.xml", "application/xml" }, { "a.json", "application/json" },
    { "a.txt", "text/plain" }, { "a.htm", "text/html" },
  }
  for i = 1, #cases do
    local actual = MIME.typeOf(cases[i][1])
    check("MIME " .. cases[i][1], actual:find(cases[i][2], 1, true) ~= nil, actual)
  end
  check("未知类型回落 octet-stream",
    MIME.typeOf("a.unknownext") == "application/octet-stream", MIME.typeOf("a.unknownext"))
end }

-- 3. HEAD 请求
tests[#tests + 1] = { "HEAD 请求", function()
  local code, headers, body = split(request("HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("HEAD / -> 200", code == 200, "实际 " .. code)
  check("HEAD 带 Content-Length", tonumber(headers["content-length"] or "0") > 0,
    headers["content-length"] or "nil")
  check("HEAD 无正文", #body == 0, "长度 " .. #body)
  check("HEAD 与 GET 的 Content-Length 一致", tonumber(headers["content-length"] or "0")
    == #(select(3, get("/"))), headers["content-length"] or "nil")
end }

-- 4. POST 请求体读取（回显 API）
tests[#tests + 1] = { "POST 请求体", function()
  local payload = '{"name":"张三","ok":true}'
  local raw = "POST /_api/echo HTTP/1.1\r\nHost: localhost\r\n"
    .. "Content-Type: application/json\r\nContent-Length: " .. #payload .. "\r\n\r\n" .. payload
  local code, headers, body = split(request(raw))
  check("POST /_api/echo -> 200", code == 200, "实际 " .. code)
  local ok, decoded = pcall(json.decode, body)
  check("回显 JSON 可解析", ok and type(decoded) == "table", tostring(body):sub(1, 120))
  if ok and type(decoded) == "table" then
    check("回显 body 内容一致", decoded.body == payload, tostring(decoded.body))
    check("回显 bodyLength 正确", decoded.bodyLength == #payload, tostring(decoded.bodyLength))
    check("回显 method 为 POST", decoded.method == "POST", tostring(decoded.method))
    check("回显 contentType 透传",
      tostring(decoded.contentType):find("application/json", 1, true) ~= nil,
      tostring(decoded.contentType))
  end

  -- 静态资源拒绝 POST
  local c2 = split(request("POST /index.html HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello"))
  check("静态路径 POST -> 405", c2 == 405, "实际 " .. c2)

  -- 空请求体
  local c3 = split(request("POST /_api/echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"))
  check("POST 空请求体 -> 200", c3 == 200, "实际 " .. c3)
end }

-- 5. OPTIONS（Allow 头）
tests[#tests + 1] = { "OPTIONS 与 Allow", function()
  local code, headers = split(request("OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("OPTIONS / -> 204", code == 204, "实际 " .. code)
  check("Allow 含 GET/HEAD/OPTIONS",
    (headers["allow"] or ""):find("GET", 1, true) ~= nil
      and (headers["allow"] or ""):find("HEAD", 1, true) ~= nil
      and (headers["allow"] or ""):find("OPTIONS", 1, true) ~= nil,
    headers["allow"] or "nil")

  local c2, h2 = split(request("OPTIONS /_api/echo HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("API OPTIONS -> 204", c2 == 204, "实际 " .. c2)
  check("API Allow 含 POST", (h2["allow"] or ""):find("POST", 1, true) ~= nil, h2["allow"] or "nil")

  -- 405 也要带 Allow
  local c3, h3 = split(request("PUT / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"))
  check("PUT -> 405", c3 == 405, "实际 " .. c3)
  check("405 带 Allow", (h3["allow"] or ""):find("GET", 1, true) ~= nil, h3["allow"] or "nil")
end }

-- 6. 缓存协商：ETag / Last-Modified / 304
tests[#tests + 1] = { "缓存协商 304", function()
  local code, headers = get("/style.css")
  check("首次请求 -> 200", code == 200, "实际 " .. code)
  local etag = headers["etag"]
  check("响应带 ETag", etag ~= nil and #etag > 2, tostring(etag))
  check("响应带 Last-Modified", headers["last-modified"] ~= nil, tostring(headers["last-modified"]))
  check("响应带 Cache-Control", headers["cache-control"] ~= nil, tostring(headers["cache-control"]))

  if etag then
    local c2, h2, b2 = get("/style.css", "If-None-Match: " .. etag .. "\r\n")
    check("If-None-Match 命中 -> 304", c2 == 304, "实际 " .. c2)
    check("304 无正文", #b2 == 0, "长度 " .. #b2)
  end

  local lastMod = headers["last-modified"]
  if lastMod then
    local c3 = get("/style.css", "If-Modified-Since: " .. lastMod .. "\r\n")
    check("If-Modified-Since 命中 -> 304", c3 == 304, "实际 " .. c3)
  end

  local c4 = get("/style.css", "If-None-Match: \"different-etag\"\r\n")
  check("不匹配的 ETag -> 200", c4 == 200, "实际 " .. c4)
end }

-- 7. 目录索引默认关闭 / 开启
tests[#tests + 1] = { "目录索引开关", function()
  -- 默认配置关闭（本测试用 defaultConfig.dirIndex 控制的两个服务器验证）
  local c1, _, b1 = split(request("GET /noindex/ HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("索引关闭时目录 -> 403", c1 == 403, "实际 " .. c1)
  check("403 正文说明索引未启用", b1:find("目录索引未启用", 1, true) ~= nil, "长度 " .. #b1)
end }

-- 8. 404 / 403 / 400 / 431 / 414
tests[#tests + 1] = { "错误处理", function()
  local c1 = get("/missing-file.html")
  check("不存在文件 -> 404", c1 == 404, "实际 " .. c1)

  local c2 = get("/../main.lua")
  check("../ 穿越 -> 403", c2 == 403, "实际 " .. c2)

  local c3 = get("/%2e%2e/%2e%2e/main.lua")
  check("编码穿越 -> 403", c3 == 403, "实际 " .. c3)

  local c4 = get("/sub/../../main.lua")
  check("混合穿越 -> 403/404", c4 == 403 or c4 == 404, "实际 " .. c4)

  local c5 = split(request("BROKEN LINE\r\n\r\n"))
  check("非法请求行 -> 400", c5 == 400, "实际 " .. c5)

  local bigHeader = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: " .. string.rep("a", 9000) .. "\r\n\r\n"
  local c6 = split(request(bigHeader))
  check("超长请求头 -> 431", c6 == 431, "实际 " .. c6)

  local c7 = split(request("GET /" .. string.rep("a", 3000) .. " HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("超长目标 -> 414", c7 == 414, "实际 " .. c7)

  -- 请求走私：同时带 TE 与 CL
  local c8 = split(request("POST /_api/echo HTTP/1.1\r\nHost: localhost\r\n"
    .. "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello"))
  check("TE+CL 冲突 -> 400/501", c8 == 400 or c8 == 501, "实际 " .. c8)

  -- 超长请求体声明
  local c9 = split(request("POST /_api/echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9999999\r\n\r\n"))
  check("超大 Content-Length -> 413", c9 == 413, "实际 " .. c9)
end }

-- 9. 中文文件名与 URL 编码
tests[#tests + 1] = { "中文与编码文件名", function()
  local dir = File(WEB_ROOT)
  local cnName = "中文 文件名.html"
  local target = File(dir, cnName)
  pcall(function() fileMod.save(target.getAbsolutePath(), "<h1>中文</h1>") end)

  local encoded = "%E4%B8%AD%E6%96%87%20%E6%96%87%E4%BB%B6%E5%90%8D.html"
  local code, headers, body = split(request("GET /" .. encoded .. " HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("URL 编码的中文文件名 -> 200", code == 200, "实际 " .. code)
  check("中文内容正确返回", body:find("中文", 1, true) ~= nil, "长度 " .. #body)

  -- 空格未编码的情况
  local c2 = split(request("GET /中文%20文件名.html HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("混合编码中文名 -> 200", c2 == 200, "实际 " .. c2)

  pcall(function() target.delete() end)
end }

-- 10. 大文件下载（分块流式）
tests[#tests + 1] = { "大文件下载", function()
  local dir = File(WEB_ROOT)
  local bigFile = File(dir, "_selftest_big.bin")
  local size = 512 * 1024
  local chunk = string.rep("0123456789abcdef", 4096) -- 64 KB
  local content = {}
  for _ = 1, size // #chunk do content[#content + 1] = chunk end
  local payload = table.concat(content)
  pcall(function() fileMod.save(bigFile.getAbsolutePath(), payload) end)

  local startedAt = luajava.bindClass("android.os.SystemClock").elapsedRealtime()
  local response = request("GET /_selftest_big.bin HTTP/1.1\r\nHost: localhost\r\n\r\n")
  local elapsed = luajava.bindClass("android.os.SystemClock").elapsedRealtime() - startedAt

  local code, headers, body = split(response)
  check("大文件 GET -> 200", code == 200, "实际 " .. code)
  check("大文件长度正确", tonumber(headers["content-length"] or "0") == #payload,
    "声明 " .. tostring(headers["content-length"]) .. " 实际 " .. #payload)
  check("大文件正文完整", #body == #payload, "收到 " .. #body)
  check("大文件下载耗时合理（<8s）", elapsed < 8000, tostring(elapsed) .. "ms")

  pcall(function() bigFile.delete() end)
end }

-- 11. 空文件
tests[#tests + 1] = { "空文件", function()
  local dir = File(WEB_ROOT)
  local empty = File(dir, "_selftest_empty.txt")
  pcall(function() empty.createNewFile() end)
  pcall(function() fileMod.save(empty.getAbsolutePath(), "") end)
  local exists = false
  pcall(function() exists = empty.isFile() end)
  check("空文件已创建", exists, empty.getAbsolutePath())
  local code, headers, body = split(request("GET /_selftest_empty.txt HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("空文件 -> 200", code == 200, "实际 " .. code)
  check("空文件 Content-Length 为 0", tonumber(headers["content-length"] or "1") == 0,
    tostring(headers["content-length"]))
  check("空文件无正文", #body == 0, "长度 " .. #body)
  pcall(function() empty.delete() end)
end }

-- 12. 并发（跨线程计数必须用原子类型：Lua 变量自增不是原子操作）
tests[#tests + 1] = { "并发连接", function()
  local AtomicInteger = luajava.bindClass "java.util.concurrent.atomic.AtomicInteger"
  local doneCounter = AtomicInteger(0)
  local okCounter = AtomicInteger(0)
  local total = 4

  for _ = 1, total do
    spawn(function()
      local code = get("/")
      if code == 200 then okCounter.incrementAndGet() end
      doneCounter.incrementAndGet()
    end)
  end

  local waited = 0
  while doneCounter.get() < total and waited < 10000 do
    ThreadCls.sleep(100)
    waited = waited + 100
  end
  check(total .. " 个并发请求全部 200", okCounter.get() == total,
    "完成 " .. doneCounter.get() .. "，成功 " .. okCounter.get())
end }

local function runAll(server, logger)
  -- 准备测试目录：有/无 index 各一个
  local noIndex = File(WEB_ROOT, "noindex")
  pcall(function() noIndex.mkdirs() end)
  pcall(function() fileMod.save(File(noIndex, "a.txt").getAbsolutePath(), "a") end)

  local indexDir = File(WEB_ROOT, "withindex")
  pcall(function() indexDir.mkdirs() end)
  pcall(function() fileMod.save(File(indexDir, "index.html").getAbsolutePath(), "<h1>dir index</h1>") end)

  for i = 1, #tests do
    local ok, err = pcall(tests[i][2])
    if not ok then check(tests[i][1] .. "（执行异常）", false, tostring(err)) end
  end

  -- 有默认首页的子目录
  local code, _, body = split(request("GET /withindex/ HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("子目录有 index.html -> 200", code == 200, "实际 " .. code)
  check("返回的是该目录的 index", body:find("dir index", 1, true) ~= nil, "长度 " .. #body)

  -- 停止服务器并验证端口释放
  check("stop() 返回成功", server:stop() == true)
  ThreadCls.sleep(400)

  local rebindOk, rebindErr = pcall(function()
    local socket = ServerSocket()
    socket.setReuseAddress(true)
    socket.bind(InetSocketAddress("127.0.0.1", PORT), 4)
    socket.close()
  end)
  check("停止后端口可重新绑定", rebindOk, rebindOk and "" or tostring(rebindErr))

  local stats = logger:stats()
  check("请求计数已累加", stats.total >= 20, "total=" .. stats.total)
  check("活动连接归零", stats.active == 0, "active=" .. stats.active)
  check("平均响应时间已统计", (stats.avgMs or 0) > 0,
    string.format("%.2fms", stats.avgMs or 0))

  -- 目录索引开启后应返回列表
  local openConfig = config.normalize({
    port = PORT + 2, listenLan = false, maxConnections = 2, timeoutMs = 5000,
    indexFile = "index.html", directoryIndex = true, cacheMode = "validate",
    rootPath = WEB_ROOT,
  })
  local openServer = ServerModule.new(openConfig, logger)
  local openOk = openServer:start()
  check("索引开启的服务器启动", openOk == true, tostring(openOk))
  if openOk then
    local c, _, b = split(request("GET /noindex/ HTTP/1.1\r\nHost: localhost\r\n\r\n", PORT + 2))
    check("索引开启时目录 -> 200", c == 200, "实际 " .. c)
    check("索引页含文件名", b:find("a.txt", 1, true) ~= nil, "长度 " .. #b)
    openServer:stop()
  end

  -- 0.0.0.0 监听
  local lanConfig = config.normalize({
    port = PORT + 1, listenLan = true, maxConnections = 2, timeoutMs = 5000,
    indexFile = "index.html", directoryIndex = false, cacheMode = "short",
    rootPath = WEB_ROOT,
  })
  local lanServer = ServerModule.new(lanConfig, logger)
  local lanOk, lanDetail = lanServer:start()
  check("局域网监听启动", lanOk, tostring(lanDetail))
  if lanOk then
    check("监听地址为 0.0.0.0", lanServer.host == "0.0.0.0", tostring(lanServer.host))
    local c = split(request("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", PORT + 1))
    check("0.0.0.0 端口返回 200", c == 200, "实际 " .. c)
    lanServer:stop()
    check("局域网服务器已停止", lanServer:isRunning() == false)
  end

  -- 清理测试目录
  pcall(function() File(noIndex, "a.txt").delete() end)
  pcall(function() noIndex.delete() end)
  pcall(function() File(indexDir, "index.html").delete() end)
  pcall(function() indexDir.delete() end)
end

local logger = Logger.new(200)
local cfg = config.normalize({
  port = PORT,
  listenLan = false,
  maxConnections = 4,
  timeoutMs = 5000,
  indexFile = "index.html",
  directoryIndex = false,
  cacheMode = "validate",
  rootPath = WEB_ROOT,
})

local server = ServerModule.new(cfg, logger)
local started, detail = server:start()
if not started then
  check("服务器启动", false, tostring(detail))
  state.done = true
  state.error = detail
else
  check("服务器启动", true, "端口 " .. tostring(detail))
  spawn(function()
    local ok, err = pcall(runAll, server, logger)
    if not ok then state.error = tostring(err) end
    state.done = true
  end)
end

-- 主线程等待（不能在主线程做网络，但可以睡眠轮询）
local waited = 0
while not state.done and waited < 40000 do
  ThreadCls.sleep(100)
  waited = waited + 100
end

local passed, failed = 0, 0
local lines = { "LuaServer v0.2 自测报告", "端口 " .. PORT, "" }
for i = 1, #results do
  local item = results[i]
  if item.passed then passed = passed + 1 else failed = failed + 1 end
  lines[#lines + 1] = string.format("[%s] %s%s", item.passed and "PASS" or "FAIL", item.name,
    item.detail ~= "" and ("  (" .. item.detail .. ")") or "")
end
lines[#lines + 1] = ""
lines[#lines + 1] = string.format("合计：%d 通过，%d 失败", passed, failed)
if state.error then lines[#lines + 1] = "异常：" .. state.error end
if not state.done then lines[#lines + 1] = "注意：测试未在 40 秒内完成" end

local report = table.concat(lines, "\n")
pcall(function() fileMod.save(REPORT_PATH, report) end)
print(report)
