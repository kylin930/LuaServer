-- server/server.lua — ServerSocket 生命周期、accept 线程、有上限的工作线程池
--
-- 线程模型（均已在真机上验证可用）：
--   * accept 线程：只做 accept + 入队，不解析请求；
--   * 工作线程：固定 N 个（默认 4），从**本次运行的私有队列**取连接依次处理，
--     因此并发上限固定，不会为每个连接新建线程；
--   * 停止：置 stopping → 关闭 ServerSocket（accept 立刻抛 Socket closed 退出）
--     → 关闭队列中的连接 → 关闭活动连接（唤醒阻塞在 read 的线程）
--     → **等待所有工作线程真正退出**，避免重启后新旧 worker 串扰；
--   * UI 侧不跨线程操作 View：工作线程只写 Atomic 计数与日志队列。
local M = {}

local parser = require "server.http_parser"
local router = require "server.router"
local response = require "server.response"
local static = require "server.static_file"
local utils = require "core.utils"
local configModule = require "core.config"

local ServerSocket = luajava.bindClass "java.net.ServerSocket"
local InetSocketAddress = luajava.bindClass "java.net.InetSocketAddress"
local ThreadCls = luajava.bindClass "java.lang.Thread"
local SystemClock = luajava.bindClass "android.os.SystemClock"
local LinkedBlockingQueue = luajava.bindClass "java.util.concurrent.LinkedBlockingQueue"
local ConcurrentLinkedQueue = luajava.bindClass "java.util.concurrent.ConcurrentLinkedQueue"
local TimeUnit = luajava.bindClass "java.util.concurrent.TimeUnit"

local PENDING_CAPACITY = 64
local POLL_TIMEOUT_MS = 200
local ACCEPT_TIMEOUT_MS = 1500   -- accept 唤醒周期，用于检测孤儿实例
local STOP_WAIT_MS = 2000       -- 等待工作线程退出的上限
local STOP_POLL_MS = 50

local Server = {}
Server.__index = Server

local function friendlyBindError(err, port)
  local text = tostring(err)
  if string.find(text, "EADDRINUSE", 1, true)
    or string.find(text, "Address already in use", 1, true) then
    return "端口 " .. port .. " 已被占用，请更换端口"
  end
  if string.find(text, "EACCES", 1, true) or string.find(text, "Permission denied", 1, true) then
    return "没有权限绑定端口 " .. port .. "（1024 以下端口通常需要 root）"
  end
  if string.find(text, "Cannot assign requested address", 1, true) then
    return "监听地址不可用（端口 " .. port .. "）"
  end
  return "启动失败：" .. text
end

function M.new(config, logger)
  return setmetatable({
    config = config,
    logger = logger,
    state = "stopped",
    port = config.port,
    host = config.listenLan and "0.0.0.0" or "127.0.0.1",
    serverSocket = nil,
    run = nil,
    startMillis = 0,
    rootFile = nil,
    rootCanonical = nil,
    lastError = nil,
    -- 可选：宿主注入的"是否已失去所有权"检测函数
    staleCheck = nil,
  }, Server)
end

--- 更新配置（未运行时立即生效，运行中由调用方决定是否重启）
function Server:applyConfig(config)
  self.config = config
  if self.state ~= "running" then
    self.port = config.port
    self.host = config.listenLan and "0.0.0.0" or "127.0.0.1"
  end
end

function Server:isRunning()
  return self.state == "running"
end

function Server:uptimeMs()
  if self.state ~= "running" or self.startMillis == 0 then return 0 end
  return SystemClock.elapsedRealtime() - self.startMillis
end

function Server:localUrl()
  return "http://127.0.0.1:" .. tostring(self.port)
end

function Server:lanUrl()
  if not self.config.listenLan then return nil end
  local ip = utils.firstLanIp()
  if not ip then return nil end
  return "http://" .. ip .. ":" .. tostring(self.port)
end

--- 运行快照：既供 /_api/status 使用，也供 core/store 下发给 Activity
function Server:snapshot()
  local stats = self.logger:stats()
  return {
    running = self.state == "running",
    state = self.state,
    port = self.port,
    host = self.host,
    listenLan = self.config.listenLan and true or false,
    maxConnections = self.config.maxConnections,
    timeoutMs = self.config.timeoutMs,
    indexFile = self.config.indexFile,
    directoryIndex = self.config.directoryIndex and true or false,
    cacheMode = self.config.cacheMode,
    rootPath = self.config.rootPath,
    uptimeMs = self:uptimeMs(),
    total = stats.total,
    success = stats.success,
    failure = stats.failure,
    activeConnections = stats.active,
    avgMs = stats.avgMs,
    bytesOut = stats.bytesOut,
    localUrl = self:localUrl(),
    lanUrl = self:lanUrl() or "",
    lastError = self.lastError or "",
  }
end

--- 客户端中止连接的常见异常文本
local CLIENT_ABORT_PATTERNS = { "Connection reset", "Broken pipe", "EPIPE", "Socket closed" }

local function isClientAbort(text)
  for i = 1, #CLIENT_ABORT_PATTERNS do
    if string.find(text, CLIENT_ABORT_PATTERNS[i], 1, true) then return true end
  end
  return false
end

--- accept 超时（设置了 soTimeout 后属于正常现象，不应视为错误）
local function isTimeoutError(text)
  if string.find(text, "SocketTimeoutException", 1, true) then return true end
  if string.find(text, "timed out", 1, true) then return true end
  if string.find(text, "Timeout", 1, true) then return true end
  return false
end

local function drainQueue(queue)
  while true do
    local item = queue.poll()
    if item == nil then break end
    pcall(function() item.close() end)
  end
end

--- 启动服务；返回 ok, 端口 或 false, 错误说明
function Server:start()
  if self.state == "running" then return false, "服务器已在运行" end

  local config = self.config
  local rootFile, rootCanonical = static.ensureRoot(config.rootPath)
  if not rootFile then
    self.lastError = tostring(rootCanonical)
    return false, rootCanonical
  end

  local host = config.listenLan and "0.0.0.0" or "127.0.0.1"
  local serverSocket = ServerSocket()
  local ok, err = pcall(function()
    serverSocket.setReuseAddress(true)
    serverSocket.bind(InetSocketAddress(host, config.port), 16)
  end)
  if not ok then
    pcall(function() serverSocket.close() end)
    local message = friendlyBindError(err, config.port)
    self.lastError = message
    return false, message
  end

  local boundPort = config.port
  pcall(function() boundPort = serverSocket.getLocalPort() end)

  self.rootFile = rootFile
  self.rootCanonical = rootCanonical
  self.serverSocket = serverSocket
  self.host = host
  self.port = boundPort
  self.startMillis = SystemClock.elapsedRealtime()
  self.state = "running"
  self.lastError = nil

  -- 每次运行使用独立队列与计数对象，彻底隔离上次运行的残留 worker
  local run = {
    stopping = false,
    stale = false,
    pending = LinkedBlockingQueue(PENDING_CAPACITY),
    active = ConcurrentLinkedQueue(),
    alive = 0,           -- 仍在运行的工作线程数
    -- 可选：由宿主注入，用于检测本实例是否已被取代（服务器为孤儿）
    isStale = self.staleCheck,
  }
  self.run = run
  drainQueue(run.pending)

  local selfRef = self
  for index = 1, config.maxConnections do
    run.alive = run.alive + 1
    thread(function()
      pcall(function() selfRef:worker(run, index) end)
      run.alive = run.alive - 1
    end)
  end
  thread(function() selfRef:acceptLoop(run, serverSocket) end)

  self.logger:event(string.format("已启动：%s:%d（并发上限 %d）", host, boundPort, config.maxConnections))
  return true, boundPort
end

--- accept 循环：拿到连接就交给工作线程
--
-- 额外职责：检测"孤儿实例"。在当前运行时下 thread() 创建的是独立 Java 线程，
-- 不会随宿主 Lua 状态销毁而结束，因此必须让线程自己发现"我已不是 owner"并收尾，
-- 否则 ServerSocket 会永久占用端口。
function Server:acceptLoop(run, serverSocket)
  -- 用 soTimeout 定期唤醒，否则 accept 会一直阻塞，无法执行陈旧检测
  pcall(function() serverSocket.setSoTimeout(ACCEPT_TIMEOUT_MS) end)

  while not run.stopping do
    if run.isStale and run.isStale() then
      run.stale = true
      break
    end

    local ok, client = pcall(function() return serverSocket.accept() end)
    if ok and client ~= nil then
      if run.stopping then
        pcall(function() client.close() end)
      else
        local queued = false
        pcall(function() queued = run.pending.offer(client) end)
        if not queued then pcall(function() client.close() end) end
      end
    else
      local message = tostring(client)
      if run.stopping or string.find(message, "Socket closed", 1, true) then break end
      if isTimeoutError(message) then
        -- 正常的 accept 超时：不视为错误，回到循环顶部做陈旧检测
      else
        pcall(function() ThreadCls.sleep(100) end)
      end
    end
  end

  run.stopping = true
  -- 孤儿实例主动关闭监听口，把端口还给系统
  if run.stale then pcall(function() serverSocket.close() end) end
end

--- 工作线程：固定数量，从本次运行的私有队列取连接处理
function Server:worker(run, index)
  while not run.stopping do
    if run.isStale and run.isStale() then
      run.stale = true
      break
    end

    local client = nil
    local ok, polled = pcall(function() return run.pending.poll(POLL_TIMEOUT_MS, TimeUnit.MILLISECONDS) end)
    if ok then client = polled end
    if client ~= nil then
      if run.stopping then
        pcall(function() client.close() end)
      else
        pcall(function() run.active.offer(client) end)
        pcall(function() self:handle(client, run) end)
        pcall(function() run.active.remove(client) end)
      end
    end
  end
end

--- 处理单个连接：解析 → 路由 → 记录日志，任何异常都不会终止工作线程
function Server:handle(client, run)
  local logger = self.logger
  local startedAt = SystemClock.elapsedRealtime()
  local clientIp = "-"
  pcall(function() clientIp = client.getInetAddress().getHostAddress() end)
  logger.active.incrementAndGet()

  local output = nil
  local method, target, status, logged, bytes = "-", "-", 0, false, 0

  local ok, err = pcall(function()
    client.setSoTimeout(self.config.timeoutMs)
    output = client.getOutputStream()
    local reader = parser.newReader(client.getInputStream())
    local req, code, message = parser.parse(reader)

    if req == nil then
      if code == 0 then return end -- 客户端未发请求就断开：不响应也不记录
      status = code
      logged = true
      bytes = select(3, response.errorPage(output, code, message, false)) or 0
      return
    end

    method = req.method
    target = req.target
    logged = true

    -- 读取请求体（有上限）：供回显 API 使用；静态资源会明确拒绝 POST
    if req.chunked then
      req.body = nil
    elseif req.contentLength > 0 then
      local body, bodyErr = reader:readBody(req.contentLength)
      if body == nil then
        status = bodyErr == "too-large" and 413 or 400
        bytes = select(3, response.errorPage(output, status,
          bodyErr == "too-large" and "请求体过大" or "请求体不完整", false))
        return
      end
      req.body = body
    else
      req.body = ""
    end

    local ctx = {
      rootFile = self.rootFile,
      rootCanonical = self.rootCanonical,
      indexFile = self.config.indexFile,
      directoryIndex = self.config.directoryIndex,
      cacheMode = self.config.cacheMode,
      clientIp = clientIp,
      statusProvider = function() return self:snapshot() end,
      fileOptions = {
        cacheMode = self.config.cacheMode,
        requestHeaders = req.headers,
      },
    }
    local handledStatus, writeError, written = router.handle(req, output, ctx)
    status = handledStatus
    bytes = written or 0
    if writeError and not isClientAbort(tostring(writeError)) then
      logger:event("响应写出失败：" .. tostring(writeError))
    end
  end)

  logger.active.decrementAndGet()

  if not ok then
    logger:event("请求处理失败：" .. tostring(err))
    if output ~= nil and status == 0 then
      pcall(function() response.errorPage(output, 500, "服务器内部错误", false) end)
    end
    if logged then status = 500 end
  end

  pcall(function() client.close() end)

  if logged then
    logger:request(method, target, status, SystemClock.elapsedRealtime() - startedAt, clientIp, bytes)
  end
end

--- 停止服务并释放端口（会等待工作线程退出）
function Server:stop()
  if self.state ~= "running" then return false, "服务器未运行" end

  local run = self.run
  self.state = "stopping"
  if run then run.stopping = true end

  local serverSocket = self.serverSocket
  self.serverSocket = nil
  if serverSocket then pcall(function() serverSocket.close() end) end

  if run then
    -- 关闭排队中与正在处理的连接，唤醒阻塞在 read 的线程
    drainQueue(run.pending)
    drainQueue(run.active)

    local waited = 0
    while run.alive > 0 and waited < STOP_WAIT_MS do
      pcall(function() ThreadCls.sleep(STOP_POLL_MS) end)
      waited = waited + STOP_POLL_MS
    end
    drainQueue(run.pending)
    drainQueue(run.active)
  end

  self.state = "stopped"
  self.run = nil
  self.startMillis = 0
  self.logger:event("服务器已停止，端口 " .. tostring(self.port) .. " 已释放")
  return true
end

--- 重启（配置变更后调用）
function Server:restart()
  if self.state == "running" then self:stop() end
  local ok, detail = self:start()
  if not ok then return false, detail end
  return true, detail
end

return M
