-- tools/selftest.lua — 真实 loopback 自测（在设备上启动服务器并用 Socket 客户端验证）
--
-- 用法：在 NeLuaJ+ 中直接运行本文件。结果同时打印到日志并写入
--       <项目目录>/selftest_report.txt，便于逐项核对。
--
-- 注意：设备不允许主线程做网络操作，因此客户端也运行在 thread() 里。
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

-- 本脚本位于 tools/ 下，而 getLuaDir() 是脚本所在目录，因此显式定位工程根目录
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
      if total > 262144 then break end
      chunks[#chunks + 1] = string.char(byte)
    end
  end)
  pcall(function() socket.close() end)
  if not readOk then return table.concat(chunks), tostring(readErr) end
  return table.concat(chunks)
end

local function split(response)
  local code = tonumber(string.match(response or "", "^HTTP/1%.1 (%d%d%d)")) or 0
  local pos = string.find(response or "", "\r\n\r\n", 1, true)
  local body = pos and string.sub(response, pos + 4) or ""
  local headerText = pos and string.sub(response, 1, pos - 1) or (response or "")
  local headers = {}
  for line in string.gmatch(headerText, "[^\r\n]+") do
    local name, value = string.match(line, "^([%w%-_]+):%s*(.*)$")
    if name then headers[string.lower(name)] = value end
  end
  return code, headers, body
end

local tests = {}

tests[#tests + 1] = { "GET / 返回 200 且含默认首页", function()
  local code, headers, body = split(request("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("GET / -> 200", code == 200, "实际 " .. code)
  check("GET / Content-Type 为 HTML", (headers["content-type"] or ""):find("text/html", 1, true) ~= nil, headers["content-type"] or "nil")
  check("GET / 正文含 LuaServer", body:find("LuaServer", 1, true) ~= nil, "正文长度 " .. #body)
end }

tests[#tests + 1] = { "静态资源 MIME", function()
  local code, headers = split(request("GET /style.css HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("GET /style.css -> 200", code == 200, "实际 " .. code)
  check("CSS MIME", (headers["content-type"] or ""):find("text/css", 1, true) ~= nil, headers["content-type"] or "nil")

  code, headers = split(request("GET /app.js HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("GET /app.js -> 200", code == 200, "实际 " .. code)
  check("JS MIME", (headers["content-type"] or ""):find("javascript", 1, true) ~= nil, headers["content-type"] or "nil")

  code, headers = split(request("GET /logo.svg HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("GET /logo.svg -> 200", code == 200, "实际 " .. code)
  check("SVG MIME", (headers["content-type"] or ""):find("image/svg", 1, true) ~= nil, headers["content-type"] or "nil")

  code, headers = split(request("GET /unknown-extension.xyz HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("未知扩展名 -> 404", code == 404, "实际 " .. code)
end }

tests[#tests + 1] = { "HEAD 请求", function()
  local code, headers, body = split(request("HEAD / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("HEAD / -> 200", code == 200, "实际 " .. code)
  check("HEAD 带 Content-Length", tonumber(headers["content-length"] or "0") > 0, headers["content-length"] or "nil")
  check("HEAD 无正文", #body == 0, "正文长度 " .. #body)
end }

tests[#tests + 1] = { "404 与 403", function()
  local code = split(request("GET /missing-file.html HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("不存在文件 -> 404", code == 404, "实际 " .. code)

  code = split(request("GET /../main.lua HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("路径穿越 ../ -> 403", code == 403, "实际 " .. code)

  code = split(request("GET /%2e%2e/%2e%2e/main.lua HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("编码穿越 %2e%2e -> 403", code == 403, "实际 " .. code)

  code = split(request("GET /sub/../../main.lua HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("混合穿越 -> 403/404", code == 403 or code == 404, "实际 " .. code)
end }

tests[#tests + 1] = { "方法与错误处理", function()
  local code = split(request("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello"))
  check("POST -> 501", code == 501, "实际 " .. code)

  code = split(request("PUT / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"))
  check("PUT -> 405", code == 405, "实际 " .. code)

  code = split(request("BROKEN LINE\r\n\r\n"))
  check("非法请求行 -> 400", code == 400, "实际 " .. code)

  local bigHeader = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: " .. string.rep("a", 9000) .. "\r\n\r\n"
  code = split(request(bigHeader))
  check("超长请求头 -> 431", code == 431, "实际 " .. code)

  code = split(request("GET /" .. string.rep("a", 3000) .. " HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("超长请求目标 -> 414", code == 414, "实际 " .. code)
end }

tests[#tests + 1] = { "状态 API 与目录索引", function()
  local code, headers, body = split(request("GET /_api/status HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("GET /_api/status -> 200", code == 200, "实际 " .. code)
  check("状态 API 为 JSON", (headers["content-type"] or ""):find("json", 1, true) ~= nil, headers["content-type"] or "nil")
  local ok, decoded = pcall(json.decode, body)
  check("状态 JSON 可解析", ok and type(decoded) == "table" and decoded.port == PORT,
    ok and tostring(decoded and decoded.port) or tostring(decoded))

  local code2, _, body2 = split(request("GET /sub/ HTTP/1.1\r\nHost: localhost\r\n\r\n"))
  check("无 index 的目录返回索引页", code2 == 200 and body2:find("目录索引", 1, true) ~= nil, "实际 " .. code2)
end }

tests[#tests + 1] = { "并发连接", function()
  local done = 0
  local success = 0
  for i = 1, 4 do
    spawn(function()
      local code = split(request("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
      if code == 200 then success = success + 1 end
      done = done + 1
    end)
  end
  local waited = 0
  while done < 4 and waited < 6000 do
    ThreadCls.sleep(100)
    waited = waited + 100
  end
  check("4 个并发请求全部 200", success == 4, "完成 " .. done .. "，成功 " .. success)
end }

local function runAll(server, logger)
  local testDir = File(WEB_ROOT, "sub")
  pcall(function() testDir.mkdirs() end)
  pcall(function() fileMod.save(File(testDir, "hello.txt").getAbsolutePath(), "hello") end)

  for i = 1, #tests do
    local ok, err = pcall(tests[i][2])
    if not ok then
      check(tests[i][1] .. "（执行异常）", false, tostring(err))
    end
  end

  -- 停止服务器并验证端口释放
  local stopped = server:stop()
  check("stop() 返回成功", stopped == true, tostring(stopped))
  ThreadCls.sleep(400)

  local rebindOk, rebindErr = pcall(function()
    local socket = ServerSocket()
    socket.setReuseAddress(true)
    socket.bind(InetSocketAddress("127.0.0.1", PORT), 4)
    socket.close()
  end)
  check("停止后端口可重新绑定", rebindOk, rebindOk and "" or tostring(rebindErr))

  local stats = logger:stats()
  check("请求计数已累加", stats.total >= 12, "total=" .. stats.total)
  check("活动连接归零", stats.active == 0, "active=" .. stats.active)

  -- 端口变更 + 局域网监听（0.0.0.0）
  local lanPort = PORT + 1
  local lanConfig = config.normalize({
    port = lanPort,
    listenLan = true,
    maxConnections = 2,
    timeoutMs = 5000,
    indexFile = "index.html",
    rootPath = WEB_ROOT,
  })
  local lanServer = ServerModule.new(lanConfig, logger)
  local lanOk, lanDetail = lanServer:start()
  check("局域网监听启动", lanOk, tostring(lanDetail))
  if lanOk then
    check("监听地址为 0.0.0.0", lanServer.host == "0.0.0.0", tostring(lanServer.host))
    check("端口已切换", tonumber(lanDetail) == lanPort, tostring(lanDetail))
    local lanCode = split(request("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", lanPort))
    check("新端口返回 200", lanCode == 200, "实际 " .. tostring(lanCode))
    lanServer:stop()
    check("局域网服务器已停止", lanServer:isRunning() == false, "")
  end

  -- 清理测试目录
  pcall(function() File(testDir, "hello.txt").delete() end)
  pcall(function() testDir.delete() end)
end

local logger = Logger.new(200)
local cfg = config.normalize({
  port = PORT,
  listenLan = false,
  maxConnections = 4,
  timeoutMs = 5000,
  indexFile = "index.html",
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

-- 主线程等待测试线程完成（不能在主线程做网络，但可以睡眠轮询）
local waited = 0
while not state.done and waited < 20000 do
  ThreadCls.sleep(100)
  waited = waited + 100
end

local passed, failed = 0, 0
local lines = { "LuaServer 自测报告", "端口 " .. PORT, "" }
for i = 1, #results do
  local item = results[i]
  if item.passed then passed = passed + 1 else failed = failed + 1 end
  lines[#lines + 1] = string.format("[%s] %s%s", item.passed and "PASS" or "FAIL", item.name,
    item.detail ~= "" and ("  (" .. item.detail .. ")") or "")
end
lines[#lines + 1] = ""
lines[#lines + 1] = string.format("合计：%d 通过，%d 失败", passed, failed)
if state.error then lines[#lines + 1] = "异常：" .. state.error end
if not state.done then lines[#lines + 1] = "注意：测试未在 20 秒内完成" end

local report = table.concat(lines, "\n")
pcall(function() fileMod.save(REPORT_PATH, report) end)
print(report)
