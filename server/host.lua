-- server/host.lua — 服务器宿主：由 Service 持有，负责服务器生命周期、通知与状态广播
--
-- 设计要点（均基于真机探测结论）：
--   * LuaService 与 LuaActivity 是两个独立的 Lua 状态，全局变量不共享；
--   * 两者共享 SharedPreferences，因此状态/命令统一走 core/store；
--   * Service 内没有 activity / call，所以这里不做任何 UI 操作；
--   * 心跳线程（timer）周期把快照写入 store，Activity 侧据此判断存活。
local M = {}

local configModule = require "core.config"
local Logger = require "core.logger"
local ServerModule = require "server.server"
local Store = require "core.store"
local staticFile = require "server.static_file"

local Context = luajava.bindClass "android.content.Context"
local NotificationManager = luajava.bindClass "android.app.NotificationManager"
local NotificationChannel = luajava.bindClass "android.app.NotificationChannel"
local NotificationCompat = luajava.bindClass "androidx.core.app.NotificationCompat"
local PendingIntent = luajava.bindClass "android.app.PendingIntent"
local Intent = luajava.bindClass "android.content.Intent"
local LuaActivity = luajava.bindClass "com.androlua.LuaActivity"

local CHANNEL_ID = "luaserver_service"
local NOTIFICATION_ID = 0x4C53 -- "LS"
local HEARTBEAT_MS = 1000
local POLL_MS = 400

local Host = {}
Host.__index = Host

--- svc：LuaService 实例；svc.getLuaDir() 与 Activity 侧一致
function M.new(svc)
  local config = configModule.load(svc)
  local logger = Logger.new(200)
  local server = ServerModule.new(config, logger)
  local store = Store.new(svc)
  -- 每个 Service 脚本执行体都有唯一 ownerId，用于判定"谁是真正的服务器宿主"
  math.randomseed(os.time() + math.floor(Store.millis() % 100000))
  local ownerId = string.format("%d-%04d", os.time(), math.random(0, 9999))
  return setmetatable({
    svc = svc,
    config = config,
    logger = logger,
    server = server,
    store = store,
    ownerId = ownerId,
    passive = false,       -- true 表示本实例不是 owner，只做旁观察看
    passiveReason = nil,
    clock = nil,
    ackId = 0,
    lastStateJson = nil,
    running = false,
  }, Host)
end

--- 抢占服务器宿主所有权
--
-- 背景（真机实测）：在当前 NeLuaJ+ 运行时下，每次 startService 都会重新执行
-- service.lua，产生一个**全新的 Lua 状态**，旧实例的 ServerSocket 与工作线程
-- 没有任何引用可以停掉，于是出现「8080 与 18095 同时响应」的端口/线程泄漏。
--
-- 因此用 SharedPreferences 里的一份存活声明做跨实例互斥：
--   * 已有存活 owner（serviceAlive 且心跳新鲜）→ 本实例转为被动模式，什么都不做；
--   * 否则把自己写成 owner 并立即发布一次状态，抢占成功。
-- 被动模式不会写状态、不开时钟、不启动服务器，因此不会干扰真正的 owner。
function Host:claimOwnership()
  local snapshot = self.store:readState()
  if type(snapshot) == "table"
    and snapshot.serviceAlive == true
    and Store.isFresh(snapshot) then
    local existing = snapshot.ownerId
    if existing ~= nil and existing == self.ownerId then return true end
    return false, "已有服务实例在运行（owner=" .. tostring(existing or "legacy") .. "）"
  end
  -- 声明所有权：立即写一次，让后续实例能立刻看到
  self.store:writeState({
    ownerId = self.ownerId,
    serviceAlive = true,
    running = false,
    state = "idle",
    port = self.config.port,
    host = self.config.listenLan and "0.0.0.0" or "127.0.0.1",
    listenLan = self.config.listenLan and true or false,
    rootPath = self.config.rootPath,
    total = 0, success = 0, failure = 0, active = 0, avgMs = 0,
    uptimeMs = 0,
    logs = {},
  })
  return true
end

local function safe(getter, fallback)
  local ok, value = pcall(getter)
  if ok and value ~= nil then return value end
  return fallback
end

--- 创建通知渠道（Android 8+ 必需；重复创建无副作用）
function Host:ensureChannel()
  local ok = pcall(function()
    local nm = self.svc.getSystemService(Context.NOTIFICATION_SERVICE)
    if nm == nil then return end
    -- IMPORTANCE_LOW = 2：常驻通知不发出提示音
    local channel = NotificationChannel(CHANNEL_ID, "LuaServer 服务器", 2)
    channel.setDescription("显示本地 HTTP 服务器的运行状态")
    pcall(function() channel.setShowBadge(false) end)
    nm.createNotificationChannel(channel)
  end)
  return ok
end

--- 点击通知回到 LuaServer 主界面
function Host:contentIntent()
  local ok, intent = pcall(function()
    local launch = Intent(self.svc, LuaActivity.class)
    launch.setAction(Intent.ACTION_MAIN)
    launch.addCategory(Intent.CATEGORY_LAUNCHER)
    launch.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    return PendingIntent.getActivity(self.svc, 0, launch,
      PendingIntent.FLAG_UPDATE_CURRENT + PendingIntent.FLAG_IMMUTABLE)
  end)
  if ok then return intent end
  return nil
end

--- 构建常驻通知
function Host:buildNotification()
  local snapshot = self.server:snapshot()
  local title = "LuaServer 正在运行"
  local text
  if snapshot.listenLan then
    text = "监听 0.0.0.0:" .. snapshot.port .. " · 请求 " .. snapshot.total
    local lanUrl = self.server:lanUrl()
    if lanUrl then text = "局域网 " .. lanUrl .. " · 请求 " .. snapshot.total end
  else
    text = "监听 127.0.0.1:" .. snapshot.port .. " · 请求 " .. snapshot.total
  end

  local builder = NotificationCompat.Builder(self.svc, CHANNEL_ID)
  builder.setContentTitle(title)
  builder.setContentText(text)
  builder.setSmallIcon(safe(function() return 0x7f010001 end, 17301543))
  builder.setOngoing(true)
  builder.setOnlyAlertOnce(true)
  builder.setShowWhen(false)
  builder.setPriority(NotificationCompat.PRIORITY_LOW)
  local intent = self:contentIntent()
  if intent then builder.setContentIntent(intent) end
  return builder.build()
end

--- 申请前台并刷新通知
function Host:startForeground()
  self:ensureChannel()
  local ok, err = pcall(function()
    self.svc.startForeground(NOTIFICATION_ID, self:buildNotification())
  end)
  if not ok then
    self.logger:event("前台通知失败：" .. tostring(err))
    return false
  end
  return true
end

--- 更新通知内容（不重建前台状态）
function Host:updateNotification()
  if not self.running then return end
  pcall(function()
    local nm = self.svc.getSystemService(Context.NOTIFICATION_SERVICE)
    if nm then nm.notify(NOTIFICATION_ID, self:buildNotification()) end
  end)
end

--- 移除通知并退出前台
function Host:stopForeground()
  pcall(function() self.svc.stopForeground(true) end)
  pcall(function()
    local nm = self.svc.getSystemService(Context.NOTIFICATION_SERVICE)
    if nm then nm.cancel(NOTIFICATION_ID) end
  end)
end

--- 把当前状态（含日志）写入 store，供 Activity 读取
function Host:publish()
  if self.passive then return end
  self.logger:sync()
  local snapshot = self.server:snapshot()
  local logPart = self.logger:toSnapshot(Store.MAX_LOG_ENTRIES)
  snapshot.total = logPart.total
  snapshot.success = logPart.success
  snapshot.failure = logPart.failure
  snapshot.active = logPart.active
  snapshot.avgMs = logPart.avgMs
  snapshot.bytesOut = logPart.bytesOut
  snapshot.logs = logPart.logs
  snapshot.directoryIndex = self.config.directoryIndex and true or false
  snapshot.cacheMode = self.config.cacheMode
  snapshot.rootPath = self.config.rootPath
  snapshot.ackCommandId = self.ackId
  snapshot.serviceAlive = true
  snapshot.ownerId = self.ownerId

  -- 仅在内容变化时写入，减少 SharedPreferences 压力
  local okEncode, encoded = pcall(json.encode, snapshot)
  if okEncode and encoded == self.lastStateJson then return end
  self.lastStateJson = encoded
  self.store:writeState(snapshot)
end

--- 处理来自 Activity 的命令
function Host:handleCommand(command)
  if self.passive then return end
  local action = command and command.action
  if not action then return end
  local payload = command.payload or {}

  if action == "start" then
    self:applyPayloadConfig(payload)
    self:startServer()
  elseif action == "stop" then
    self:stopServer(true)
  elseif action == "restart" then
    self:applyPayloadConfig(payload)
    self:restartServer()
  elseif action == "reload" then
    self.config = configModule.load(self.svc)
    self.server:applyConfig(self.config)
    self.logger:event("已重新载入配置")
  elseif action == "clearLogs" then
    self.logger:reset()
    self.logger:event("日志已清空")
  end

  self.ackId = tonumber(command.id) or self.ackId
  self:publish()
  self:updateNotification()
end

--- 用命令里携带的配置覆盖本地配置（Activity 已做校验并持久化）
function Host:applyPayloadConfig(payload)
  if type(payload) ~= "table" or next(payload) == nil then return end
  local merged = configModule.load(self.svc)
  if type(payload.port) == "number" then merged.port = payload.port end
  if type(payload.listenLan) == "boolean" then merged.listenLan = payload.listenLan end
  if type(payload.maxConnections) == "number" then merged.maxConnections = payload.maxConnections end
  if type(payload.timeoutMs) == "number" then merged.timeoutMs = payload.timeoutMs end
  if type(payload.indexFile) == "string" and payload.indexFile ~= "" then merged.indexFile = payload.indexFile end
  if type(payload.directoryIndex) == "boolean" then merged.directoryIndex = payload.directoryIndex end
  if type(payload.cacheMode) == "string" then merged.cacheMode = payload.cacheMode end
  if type(payload.rootPath) == "string" and payload.rootPath ~= "" then merged.rootPath = payload.rootPath end
  self.config = configModule.normalize(merged, self.svc)
  self.server:applyConfig(self.config)
end

--- 判断本实例是否已失去所有权（被新实例取代或被显式停止）
-- 供 server.lua 的 accept/worker 线程周期调用，实现孤儿线程自愈。
function Host:isStale()
  local snapshot = self.store:readState()
  if type(snapshot) ~= "table" then return false end
  -- 状态被清空或标记服务已退出，说明不再由本实例负责
  if snapshot.serviceAlive == false then return true end
  -- 有另一个 ownerId 接管：本实例必须让出端口
  local owner = snapshot.ownerId
  if owner ~= nil and owner ~= "" and owner ~= self.ownerId then return true end
  return false
end

--- 启动服务器；返回 ok, 端口 或 false, 错误说明
function Host:startServer()
  if self.server:isRunning() then
    self.logger:event("服务器已在运行")
    return true
  end
  -- 配置已在 handleCommand → applyPayloadConfig 中合并（含 Activity 下发的 payload
  -- 与已持久化的配置），这里不再重新 load，否则会覆盖刚下发的值。
  self.server:applyConfig(self.config)
  -- 注入陈旧检测：一旦本实例不再是 owner，accept/worker 线程会自行退出并释放端口
  local selfRef = self
  self.server.staleCheck = function() return selfRef:isStale() end
  local ok, detail = self.server:start()
  if not ok then
    self.logger:event("启动失败：" .. tostring(detail))
    self:stopForeground()
    return false, detail
  end
  self.running = true
  self:startForeground()
  return true, detail
end

--- 停止服务器；fromCommand 为 true 时同时退出服务
function Host:stopServer(fromCommand)
  if self.server:isRunning() then self.server:stop() end
  self.running = false
  self:publish()
  self:stopForeground()
  if fromCommand then
    pcall(function() self.svc.stopSelf() end)
  end
  return true
end

function Host:restartServer()
  self.server:applyConfig(self.config)
  local wasRunning = self.server:isRunning()
  if wasRunning then self.server:stop() end
  local ok, detail = self.server:start()
  if not ok then
    self.running = false
    self.logger:event("重启失败：" .. tostring(detail))
    self:publish()
    self:stopForeground()
    return false, detail
  end
  self.running = true
  if wasRunning or true then self:startForeground() end
  return true, detail
end

--- 心跳：处理命令 + 发布状态 + 刷新通知
function Host:beat()
  if self.passive then return end
  local command = self.store:readCommand(self.ackId)
  if command then
    local ok, err = pcall(function() self:handleCommand(command) end)
    if not ok then
      self.logger:event("命令执行失败：" .. tostring(err))
      self:publish()
    end
  else
    self:publish()
  end
end

--- 启动心跳定时器（service 环境里 timer 可用）
function Host:startClock()
  if self.clock then return end
  local selfRef = self
  self.clock = timer(function()
    local ok, err = pcall(function() selfRef:beat() end)
    if not ok then
      pcall(function()
        file.save(selfRef.svc.getLuaDir("luaserver_service_error.txt"), tostring(err))
      end)
    end
  end, 200, HEARTBEAT_MS)
end

function Host:stopClock()
  if self.clock then
    pcall(function() self.clock.stop() end)
    self.clock = nil
  end
end

--- 服务创建：抢占宿主所有权；非 owner 直接转为被动模式
function Host:onCreate()
  self:ensureChannel()

  local owned, reason = self:claimOwnership()
  if not owned then
    self.passive = true
    self.passiveReason = reason
    pcall(function()
      file.save(self.svc.getLuaDir("luaserver_passive.txt"),
        tostring(os.date("%H:%M:%S")) .. " 被动实例已退出：" .. tostring(reason))
    end)
    return
  end

  local rootReady, rootInfo = staticFile.ensureRoot(self.config.rootPath)
  if not rootReady then self.logger:event("网站根目录不可用：" .. tostring(rootInfo)) end

  -- 不自动恢复"上次运行中"的状态：避免用户没有预期时占用端口。
  self.logger:event("服务已就绪")
  self:publish()
  self:startClock()
end

--- 服务销毁：只有 owner 才需要停止服务器、撤销所有权
function Host:onDestroy()
  if self.passive then return end
  self:stopClock()
  if self.server:isRunning() then self.server:stop() end
  self.running = false
  pcall(function()
    self.store:writeState({
      ownerId = self.ownerId,
      running = false,
      state = "stopped",
      port = self.config.port,
      host = self.config.listenLan and "0.0.0.0" or "127.0.0.1",
      listenLan = self.config.listenLan and true or false,
      total = 0,
      success = 0,
      failure = 0,
      active = 0,
      avgMs = 0,
      uptimeMs = 0,
      logs = {},
      ackCommandId = self.ackId,
      serviceAlive = false,
      lastError = "服务已退出",
    })
  end)
  self:stopForeground()
end

return M
