-- tools/verify.lua — 端到端验证：外壳 + 5 个页面 + 真实请求 + UI 刷新 + 启停
--
-- 结果写入工程根目录 verify_report.txt。可在改动后作为回归检查。
local projectDir = activity.getLuaDir()
if string.sub(projectDir, -6) == "/tools" then
  projectDir = string.sub(projectDir, 1, #projectDir - 6)
end
local REPORT = projectDir .. "/verify_report.txt"

local StringCls = luajava.bindClass "java.lang.String"
local SocketCls = luajava.bindClass "java.net.Socket"
local InetSocketAddress = luajava.bindClass "java.net.InetSocketAddress"
local ThreadCls = luajava.bindClass "java.lang.Thread"

local out, passed, failed = {}, 0, 0
local function log(text)
  out[#out + 1] = tostring(text)
  pcall(function() file.save(REPORT, table.concat(out, "\n")) end)
end
local function check(name, ok, detail)
  if ok then passed = passed + 1 else failed = failed + 1 end
  log(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name,
    detail and ("  (" .. tostring(detail) .. ")") or ""))
end
local function textOf(view)
  local okGet, value = pcall(function() return view.getText() end)
  if not okGet or value == nil then return "" end
  if type(value) == "string" then return value end
  local okTo, text = pcall(function() return value.toString() end)
  return okTo and tostring(text) or ""
end

local okShell, appOrErr = pcall(function() return require("ui.shell").start() end)
check("外壳启动", okShell, okShell and nil or tostring(appOrErr))
if not okShell then log("DONE") return end
local app = appOrErr

check("工具栏存在", app.views.toolbar ~= nil)
check("初始副标题为已停止", tostring(app.views.toolbar.getSubtitle()) == "已停止",
  tostring(app.views.toolbar.getSubtitle()))
check("标签页数量为 5", app.views.tabs.getTabCount() == 5, tostring(app.views.tabs.getTabCount()))
check("首页已挂载", app.pages[1].root ~= nil and app.pages[1].root.getParent() ~= nil)

local started, detail = app.server:start()
check("服务器启动", started == true, detail)
if not started then app.destroy() log("DONE") return end

local port = app.server.port

thread(function()
  -- 真实 HTTP 请求（后台线程，避免 NetworkOnMainThread）
  ThreadCls.sleep(300)
  local function get(path)
    local code = "?"
    pcall(function()
      local socket = SocketCls()
      socket.connect(InetSocketAddress("127.0.0.1", port), 3000)
      socket.setSoTimeout(3000)
      local req = "GET " .. path .. " HTTP/1.1\r\nHost: localhost\r\n\r\n"
      socket.getOutputStream().write(StringCls(req).getBytes("UTF-8"))
      socket.getOutputStream().flush()
      local input = socket.getInputStream()
      local chunks = {}
      while true do
        local byte = input.read()
        if byte == -1 then break end
        chunks[#chunks + 1] = string.char(byte)
        if #chunks > 200000 then break end
      end
      socket.close()
      code = string.match(table.concat(chunks), "^HTTP/1%.1 (%d%d%d)") or "?"
    end)
    return code
  end

  local results = {
    { "/", "200" }, { "/index.html", "200" }, { "/style.css", "200" },
    { "/app.js", "200" }, { "/logo.svg", "200" }, { "/missing.html", "404" },
    { "/../main.lua", "403" }, { "/_api/status", "200" },
  }
  local codes = {}
  for i = 1, #results do
    codes[i] = get(results[i][1])
  end

  ThreadCls.sleep(1500) -- 等主线程跑两次刷新

  call(function()
    for i = 1, #results do
      check("GET " .. results[i][1] .. " -> " .. results[i][2], codes[i] == results[i][2], codes[i])
    end

    check("副标题反映运行状态",
      string.find(tostring(app.views.toolbar.getSubtitle()), "运行中", 1, true) ~= nil,
      tostring(app.views.toolbar.getSubtitle()))

    local stats = app.logger:stats()
    check("统计已累计 8 次请求", stats.total == #results, "total=" .. stats.total)
    -- 8 次请求里 /missing.html(404) 与 /../main.lua(403) 记为错误
    check("成功 6 次 / 错误 2 次", stats.success == 6 and stats.failure == 2,
      stats.success .. "/" .. stats.failure)
    check("活动连接归零", stats.active == 0, "active=" .. stats.active)

    local dash = app.pages[1]
    dash.refresh()
    check("首页显示运行中", textOf(dash.views.dashStateText) == "运行中", textOf(dash.views.dashStateText))
    check("首页显示本机地址", textOf(dash.views.dashLocalUrl) == "http://127.0.0.1:" .. port,
      textOf(dash.views.dashLocalUrl))
    check("首页按钮为停止", textOf(dash.views.dashToggle) == "停止服务器", textOf(dash.views.dashToggle))
    check("首页累计请求数", textOf(dash.views.dashTotal) == tostring(#results), textOf(dash.views.dashTotal))

    local logs = app.pages[3]
    logs.onShow()
    check("日志页有记录", logs.views.logList.getChildCount() > 0,
      "rows=" .. logs.views.logList.getChildCount())
    check("日志页汇总含累计", string.find(textOf(logs.views.logSummary), "累计", 1, true) ~= nil)

    local files = app.pages[4]
    files.onShow()
    check("文件页可列出默认站点", files.views.fileList.getChildCount() >= 4,
      "rows=" .. files.views.fileList.getChildCount())
    check("文件页首页状态", string.find(textOf(files.views.fileIndex), "存在", 1, true) ~= nil,
      textOf(files.views.fileIndex))

    local settings = app.pages[2]
    settings.onShow()
    check("设置页端口回填", textOf(settings.views.setPort) == tostring(port), textOf(settings.views.setPort))

    local about = app.pages[5]
    about.onShow()
    check("关于页显示 Lua 版本", string.find(textOf(about.views.aboutLua), "Lua", 1, true) ~= nil,
      textOf(about.views.aboutLua))
    check("关于页显示监听范围", string.find(textOf(about.views.aboutListen), "127.0.0.1", 1, true) ~= nil,
      textOf(about.views.aboutListen))

    -- 停止并验证端口释放
    local stopped = app.server:stop()
    check("停止成功", stopped == true, tostring(stopped))
    check("停止后状态为未运行", app.server:isRunning() == false)

    thread(function()
      ThreadCls.sleep(400)
      local rebound = pcall(function()
        local ServerSocket = luajava.bindClass("java.net.ServerSocket")
        local socket = ServerSocket()
        socket.setReuseAddress(true)
        socket.bind(InetSocketAddress("127.0.0.1", port), 4)
        socket.close()
      end)
      call(function()
        check("端口已释放，可重新绑定", rebound)
        app.destroy()
        check("destroy 后定时器已停止", app.clock == nil)
        log("")
        log(string.format("合计：%d 通过，%d 失败", passed, failed))
        log("DONE")
      end)
    end)
  end)
end)
