-- core/controller.lua — Activity 侧控制器：通过 Service 控制 HTTP 服务器并读取状态
--
-- Activity 不再自己持有 ServerSocket，所有网络工作都在 LuaService 中完成，
-- 因此关闭 Activity 后服务器仍然运行。这里只负责：
--   * 把命令写进 core/store 并唤醒 Service；
--   * 周期性读取快照，供 UI 渲染。
local M = {}

local Store = require "core.store"
local configModule = require "core.config"
local utils = require "core.utils"

local Controller = {}
Controller.__index = Controller

local EMPTY_STATE = {
  running = false,
  state = "stopped",
  port = 8080,
  host = "127.0.0.1",
  listenLan = false,
  total = 0,
  success = 0,
  failure = 0,
  active = 0,
  avgMs = 0,
  bytesOut = 0,
  uptimeMs = 0,
  logs = {},
  lastError = "",
}

function M.new(app)
  return setmetatable({
    app = app,
    store = Store.new(activity),
    state = EMPTY_STATE,
    fresh = false,
    lastCommandId = 0,
    pendingAction = nil,
    pendingSince = 0,
  }, Controller)
end

--- 确保 Service 在运行；已存在存活实例时不再重复 startService
--
-- 重要：每次 startService 都会重新执行 service.lua 并产生一个新的 Lua 状态
-- （旧实例的 ServerSocket 无法被回收）。因此只在没有存活实例时才拉起服务，
-- 其余情况只依赖 SharedPreferences 命令通道，由现有 owner 消费。
function Controller:ensureService()
  local snapshot = self.store:readState()
  if Store.isFresh(snapshot) then return true end
  local ok, err = pcall(function() activity.startService("service.lua") end)
  if not ok then
    self.state.lastError = "无法启动后台服务：" .. tostring(err)
    return false, self.state.lastError
  end
  return true
end

--- 下发命令；payload 会合并进配置
function Controller:send(action, payload)
  local id = self.store:sendCommand(action, payload)
  if not id then return false, "命令写入失败" end
  self.lastCommandId = id
  self.pendingAction = action
  self.pendingSince = Store.millis()
  local ok, err = self:ensureService()
  if not ok then return false, err end
  return true, id
end

--- 从 store 拉取最新状态并判断服务是否存活
function Controller:pull()
  local snapshot = self.store:readState()
  if Store.isFresh(snapshot) then
    self.fresh = true
    -- 用快照补全缺省字段，避免旧版本快照缺少新字段时报错
    local merged = {}
    for key, value in pairs(EMPTY_STATE) do merged[key] = value end
    for key, value in pairs(snapshot) do merged[key] = value end
    merged.logs = snapshot.logs or {}
    self.state = merged
    if self.pendingAction and tonumber(snapshot.ackCommandId) and
      tonumber(snapshot.ackCommandId) >= self.lastCommandId then
      self.pendingAction = nil
    end
  else
    self.fresh = false
    -- 服务不在运行：保留上一块的最后错误信息，便于界面提示
    local lastError = self.state.lastError or ""
    local copy = {}
    for key, value in pairs(EMPTY_STATE) do copy[key] = value end
    copy.lastError = lastError
    copy.port = self.app and self.app.config and self.app.config.port or copy.port
    self.state = copy
    if self.pendingAction and (Store.millis() - self.pendingSince) > 4000 then
      self.pendingAction = nil
    end
  end
  return self.state
end

function Controller:isRunning()
  return self.fresh and self.state.running == true
end

--- 启动服务器：先把当前配置持久化，再随命令下发给 Service
function Controller:start()
  if self.fresh and self.state.running then return false, "服务器已在运行" end
  -- 先写入本地配置，保证 Service 即使没有收到 payload 也能读到正确的值
  pcall(function() configModule.save(self.app.config, activity) end)
  local ok, detail = self:send("start", self.app.config)
  if not ok then return false, detail end
  return true
end

function Controller:stop()
  if not self:isRunning() then
    -- 服务已不在运行，只需清理过期状态
    self.store:clearState()
    self.fresh = false
    self:pull()
    return true
  end
  return self:send("stop")
end

function Controller:restart()
  return self:send("restart", self.app.config)
end

function Controller:clearLogs()
  return self:send("clearLogs")
end

function Controller:reload()
  return self:send("reload")
end

--- 本地地址与局域网地址（根据快照判断，避免界面自行猜测）
function Controller:localUrl()
  local port = self.state.port or 8080
  return "http://127.0.0.1:" .. tostring(port)
end

function Controller:lanUrl()
  if not self.state.listenLan then return nil end
  local ip = utils.firstLanIp()
  if not ip then return nil end
  return "http://" .. ip .. ":" .. tostring(self.state.port or 8080)
end

--- 局域网地址是否存在（用于提示 Wi-Fi 断开）
function Controller:hasLanAddress()
  return utils.firstLanIp() ~= nil
end

return M
