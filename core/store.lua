-- core/store.lua — Service ↔ Activity 共享状态与命令通道
--
-- 背景（已在真机验证）：
--   * LuaService 与 LuaActivity 运行在**各自独立的 Lua 状态**里，全局变量不共享；
--   * 但两者的 getSharedData/setSharedData 指向同一份 SharedPreferences，双向可见；
--   * Service 内没有 activity / call，UI 更新只能由 Activity 侧主动拉取。
--
-- 因此用 SharedPreferences 里两个 JSON 键做唯一通道：
--   STATE_KEY：Service 周期写入的运行快照（含心跳时间戳与最近日志）
--   CMD_KEY  ：Activity 写入的命令（含自增 id，Service 消费后回写 ackId）
--
-- 心跳用于判断服务是否还活着：Activity 读到的心跳超过 STALE_MS 即视为已停止。
local M = {}

local STATE_KEY = "luaserver_state_v1"
local CMD_KEY = "luaserver_cmd_v1"

M.STALE_MS = 5000          -- 心跳超过该时长视为服务不在运行
M.MAX_LOG_ENTRIES = 120    -- 随快照下发的日志条数上限

local Store = {}
Store.__index = Store

--- context 可以是 LuaActivity（activity）或 LuaService（this/service）
function M.new(context)
  return setmetatable({ context = context }, Store)
end

local function millis()
  local ok, value = pcall(function()
    return luajava.bindClass("android.os.SystemClock").elapsedRealtime()
  end)
  if ok and type(value) == "number" then return value end
  return os.time() * 1000
end

M.millis = millis

local function readJson(context, key)
  local ok, raw = pcall(function() return context.getSharedData(key) end)
  if not ok or type(raw) ~= "string" or #raw < 2 then return nil end
  local decodedOk, decoded = pcall(json.decode, raw)
  if decodedOk and type(decoded) == "table" then return decoded end
  return nil
end

local function writeJson(context, key, value)
  local encodedOk, encoded = pcall(json.encode, value)
  if not encodedOk then return false end
  local ok = pcall(function() context.setSharedData(key, encoded) end)
  return ok
end

--- 读取运行快照；没有快照时返回 nil
function Store:readState()
  return readJson(self.context, STATE_KEY)
end

--- 写入运行快照（Service 侧调用）
function Store:writeState(snapshot)
  snapshot.heartbeatAt = millis()
  snapshot.serverTime = os.time()
  return writeJson(self.context, STATE_KEY, snapshot)
end

--- 判断快照是否仍然新鲜（Service 还在心跳）
-- 同时校验单调时钟与墙钟：
--   * 设备重启后 elapsedRealtime 归零，旧快照的 heartbeatAt 会大于当前值 → 判为不新鲜；
--   * 服务被系统回收后两个时钟都会停止前进 → 超过 STALE_MS 判为不新鲜。
function M.isFresh(snapshot)
  if type(snapshot) ~= "table" then return false end
  if snapshot.serviceAlive == false then return false end
  local beat = tonumber(snapshot.heartbeatAt)
  local wall = tonumber(snapshot.serverTime)
  local now = millis()
  local monotonicOk = beat ~= nil and beat <= now and (now - beat) <= M.STALE_MS
  local wallOk = wall ~= nil and (os.time() - wall) <= math.ceil(M.STALE_MS / 1000) + 1
  return monotonicOk and wallOk
end

--- Activity 侧下发命令；id 自增保证 Service 不会重复执行
function Store:sendCommand(action, payload)
  local previous = readJson(self.context, CMD_KEY)
  local nextId = 1
  if type(previous) == "table" and tonumber(previous.id) then
    nextId = math.floor(tonumber(previous.id)) + 1
  end
  local command = {
    id = nextId,
    action = tostring(action),
    payload = payload,
    createdAt = millis(),
  }
  local ok = writeJson(self.context, CMD_KEY, command)
  if not ok then return nil end
  return nextId
end

--- Service 侧读取命令；lastId 为已执行的 id
function Store:readCommand(lastId)
  local command = readJson(self.context, CMD_KEY)
  if type(command) ~= "table" then return nil end
  local id = tonumber(command.id)
  if not id then return nil end
  if lastId and id <= lastId then return nil end
  return command
end

--- Service 侧回报已处理到的命令 id（用于 Activity 判断命令是否生效）
function Store:ackCommand(id)
  local state = readJson(self.context, STATE_KEY) or {}
  state.ackCommandId = id
  return writeJson(self.context, STATE_KEY, state)
end

--- 清除状态（服务器彻底停止后调用，避免 Activity 读到过期数据）
-- 必须显式写 serviceAlive = false：否则 Store.isFresh 仍会认为服务存活，
-- 导致后续「启动」时不再拉起 Service。
function Store:clearState()
  return writeJson(self.context, STATE_KEY, {
    running = false,
    state = "stopped",
    cleared = true,
    serviceAlive = false,
    heartbeatAt = millis(),
    serverTime = os.time(),
    logs = {},
  })
end

M.STATE_KEY = STATE_KEY
M.CMD_KEY = CMD_KEY

return M
