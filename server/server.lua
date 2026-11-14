-- server/server.lua — ServerSocket 生命周期、accept 线程、有上限的工作线程池
--
-- 线程模型（与 NeLuaJ+ 运行时验证过的能力保持一致）：
--   * accept 线程：只做 accept + 入队，不解析请求；
--   * 工作线程：固定 N 个（默认 4），从 LinkedBlockingQueue 取连接依次处理，
--     因此并发上限固定，不会为每个连接新建线程；
--   * 停止：设置 stopping 标志 + 关闭 ServerSocket（accept 立即抛 Socket closed 退出）
--     + 关闭排队与活动连接（唤醒阻塞在 read 的线程）。
--   * UI 侧不跨线程操作 View：工作线程只写 AtomicInteger / 日志队列，主线程定时读取。
local M = {}

local parser = require "server.http_parser"
local router = require "server.router"
local response = require "server.response"
local static = require "server.static_file"
local utils = require "core.utils"

local ServerSocket = luajava.bindClass "java.net.ServerSocket"
local InetSocketAddress = luajava.bindClass "java.net.InetSocketAddress"
local ThreadCls = luajava.bindClass "java.lang.Thread"
local SystemClock = luajava.bindClass "android.os.SystemClock"
local LinkedBlockingQueue = luajava.bindClass "java.util.concurrent.LinkedBlockingQueue"
local ConcurrentLinkedQueue = luajava.bindClass "java.util.concurrent.ConcurrentLinkedQueue"
local TimeUnit = luajava.bindClass "java.util.concurrent.TimeUnit"

local PENDING_CAPACITY = 64
local POLL_TIMEOUT_MS = 400

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
    pending = LinkedBlockingQueue(PENDING_CAPACITY),
    active = ConcurrentLinkedQueue(),
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
    rootPath = self.config.rootPath,
    uptimeMs = self:uptimeMs(),
    total = stats.total,
    success = stats.success,
    failure = stats.failure,
    activeConnections = stats.active,
    localUrl = self:localUrl(),
    lanUrl = self:lanUrl() or "",
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
  if not rootFile then return false, rootCanonical end

  local host = config.listenLan and "0.0.0.0" or "127.0.0.1"
  local serverSocket = ServerSocket()
  local ok, err = pcall(function()
    serverSocket.setReuseAddress(true)
    serverSocket.bind(InetSocketAddress(host, config.port), 16)
  end)
  if not ok then
    pcall(function() serverSocket.close() end)
    return false, friendlyBindError(err, config.port)
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

  local run = { stopping = false }
  self.run = run
  drainQueue(self.pending)
  drainQueue(self.active)

  for index = 1, config.maxConnections do
    local selfRef = self
    thread(function() selfRef:worker(run, index) end)
  end
  local selfRef = self
  thread(function() selfRef:acceptLoop(run, serverSocket) end)

  self.logger:event(string.format("已启动：%s:%d（并发上限 %d）", host, boundPort, config.maxConnections))
  return true, boundPort
end

--- accept 循环：拿到连接就交给工作线程
function Server:acceptLoop(run, serverSocket)
  while not run.stopping do
    local ok, client = pcall(function() return serverSocket.accept() end)
    if ok and client ~= nil then
      if run.stopping then
        pcall(function() client.close() end)
      else
        local queued = false
        pcall(function() queued = self.pending.offer(client) end)
        if not queued then pcall(function() client.close() end) end
      end
    else
      local message = tostring(client)
      if run.stopping or string.find(message, "Socket closed", 1, true) then break end
      -- 非预期异常：短暂退避，避免忙循环
      pcall(function() ThreadCls.sleep(100) end)
    end
  end
  run.stopping = true
end

--- 工作线程：固定数量，从队列取连接处理
function Server:worker(run, index)
  while not run.stopping do
    local client = nil
    local ok, polled = pcall(function() return self.pending.poll(POLL_TIMEOUT_MS, TimeUnit.MILLISECONDS) end)
    if ok then client = polled end
    if client ~= nil then
      if run.stopping then
        pcall(function() client.close() end)
      else
        pcall(function() self.active.offer(client) end)
        self:handle(client)
        pcall(function() self.active.remove(client) end)
      end
    end
  end
end

--- 处理单个连接：解析 -> 路由 -> 记录日志，任何异常都不会终止工作线程
function Server:handle(client)
  local logger = self.logger
  local startedAt = SystemClock.elapsedRealtime()
  local clientIp = "-"
  pcall(function() clientIp = client.getInetAddress().getHostAddress() end)
  logger.active.incrementAndGet()

  local output = nil
  local loggerRef = logger
  local method, target, status, logged = "-", "-", 0, false

  local ok, err = pcall(function()
    client.setSoTimeout(self.config.timeoutMs)
    output = client.getOutputStream()
    local reader = parser.newReader(client.getInputStream())
    local req, code, message = parser.parse(reader)

    if req == nil then
      if code == 0 then return end -- 客户端未发请求就断开：不响应也不记录
      status = code
      logged = true
      response.errorPage(output, code, message, false)
      return
    end

    method = req.method
    target = req.target
    logged = true
    if req.contentLength > 0 then
      pcall(function() reader:drain(req.contentLength) end)
    end

    local ctx = {
      rootFile = self.rootFile,
      rootCanonical = self.rootCanonical,
      indexFile = self.config.indexFile,
      clientIp = clientIp,
      statusProvider = function() return self:snapshot() end,
    }
    local handledStatus, writeError = router.handle(req, output, ctx)
    status = handledStatus
    -- 客户端提前断开（Connection reset / broken pipe）属正常现象，不记为服务端错误
    if writeError and not isClientAbort(tostring(writeError)) then
      loggerRef:event("响应写出失败：" .. tostring(writeError))
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
    logger:request(method, target, status, SystemClock.elapsedRealtime() - startedAt, clientIp)
  end
end

--- 停止服务并释放端口
function Server:stop()
  if self.state ~= "running" then return false, "服务器未运行" end

  local run = self.run
  if run then run.stopping = true end
  self.state = "stopping"

  local serverSocket = self.serverSocket
  self.serverSocket = nil
  if serverSocket then pcall(function() serverSocket.close() end) end

  drainQueue(self.pending)
  drainQueue(self.active)

  self.state = "stopped"
  self.run = nil
  self.startMillis = 0
  self.logger:event("服务器已停止，端口 " .. tostring(self.port) .. " 已释放")
  return true
end

--- 重启（配置变更后调用）
function Server:restart()
  local wasRunning = self.state == "running"
  if wasRunning then self:stop() end
  local ok, detail = self:start()
  if not ok then return false, detail end
  return true, detail
end

return M
