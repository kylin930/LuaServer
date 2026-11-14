-- core/config.lua — 配置读写（SharedPreferences 持久化）+ 校验
local M = {}

local KEY = "luaserver_config_v1"

local DEFAULTS = {
  port = 8080,
  listenLan = false,     -- false: 127.0.0.1  true: 0.0.0.0
  maxConnections = 4,
  timeoutMs = 10000,
  indexFile = "index.html",
  rootPath = nil,        -- nil 表示使用应用私有 www 目录
}

function M.defaultRoot()
  local ok, path = pcall(function() return activity.getLuaDir("www") end)
  if ok and type(path) == "string" and #path > 0 then return path end
  return "/sdcard/LuaServer/www"
end

function M.defaults()
  return {
    port = DEFAULTS.port,
    listenLan = DEFAULTS.listenLan,
    maxConnections = DEFAULTS.maxConnections,
    timeoutMs = DEFAULTS.timeoutMs,
    indexFile = DEFAULTS.indexFile,
    rootPath = M.defaultRoot(),
  }
end

--- 取值范围收敛，保证线程/端口参数始终可用
function M.normalize(cfg)
  cfg = cfg or M.defaults()
  local port = tonumber(cfg.port) or DEFAULTS.port
  if port < 1024 then port = 1024 end
  if port > 65535 then port = 65535 end
  cfg.port = math.floor(port)

  local maxConn = tonumber(cfg.maxConnections) or DEFAULTS.maxConnections
  if maxConn < 1 then maxConn = 1 end
  if maxConn > 16 then maxConn = 16 end
  cfg.maxConnections = math.floor(maxConn)

  local timeout = tonumber(cfg.timeoutMs) or DEFAULTS.timeoutMs
  if timeout < 1000 then timeout = 1000 end
  if timeout > 60000 then timeout = 60000 end
  cfg.timeoutMs = math.floor(timeout)

  cfg.listenLan = cfg.listenLan and true or false

  local indexFile = tostring(cfg.indexFile or "")
  indexFile = string.gsub(indexFile, "[/\\]", "")
  if indexFile == "" then indexFile = DEFAULTS.indexFile end
  cfg.indexFile = indexFile

  local root = tostring(cfg.rootPath or "")
  if root == "" then root = M.defaultRoot() end
  cfg.rootPath = root
  return cfg
end

--- 校验用户输入，返回 ok, 错误说明
function M.validate(cfg)
  local port = tonumber(cfg.port)
  if not port then return false, "端口必须是数字" end
  if port < 1024 or port > 65535 then return false, "端口范围需在 1024 - 65535" end

  local maxConn = tonumber(cfg.maxConnections)
  if not maxConn then return false, "最大并发连接数必须是数字" end
  if maxConn < 1 or maxConn > 16 then return false, "最大并发连接数范围需在 1 - 16" end

  local timeout = tonumber(cfg.timeoutMs)
  if not timeout then return false, "请求超时必须是数字" end
  if timeout < 1000 or timeout > 60000 then return false, "请求超时范围需在 1000 - 60000 毫秒" end

  local indexFile = tostring(cfg.indexFile or "")
  if indexFile == "" then return false, "默认首页文件不能为空" end
  if string.find(indexFile, "[/\\]") then return false, "默认首页文件名不能包含路径分隔符" end

  if tostring(cfg.rootPath or "") == "" then return false, "网站根目录不能为空" end
  return true
end

function M.load()
  local cfg = M.defaults()
  local ok, raw = pcall(function() return activity.getSharedData(KEY) end)
  if ok and type(raw) == "string" and #raw > 2 then
    local decodedOk, saved = pcall(json.decode, raw)
    if decodedOk and type(saved) == "table" then
      if type(saved.port) == "number" then cfg.port = saved.port end
      if type(saved.listenLan) == "boolean" then cfg.listenLan = saved.listenLan end
      if type(saved.maxConnections) == "number" then cfg.maxConnections = saved.maxConnections end
      if type(saved.timeoutMs) == "number" then cfg.timeoutMs = saved.timeoutMs end
      if type(saved.indexFile) == "string" and saved.indexFile ~= "" then cfg.indexFile = saved.indexFile end
      if type(saved.rootPath) == "string" and saved.rootPath ~= "" then cfg.rootPath = saved.rootPath end
    end
  end
  return M.normalize(cfg)
end

function M.save(cfg)
  local ok, err = pcall(function()
    activity.setSharedData(KEY, json.encode(cfg))
  end)
  if not ok then return false, tostring(err) end
  return true
end

--- 恢复默认值（保留网站根目录）
function M.reset(cfg)
  local fresh = M.defaults()
  fresh.rootPath = cfg and cfg.rootPath or fresh.rootPath
  return M.normalize(fresh)
end

return M
