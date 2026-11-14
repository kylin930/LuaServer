-- core/config.lua — 配置读写（SharedPreferences 持久化）+ 校验
local M = {}

local KEY = "luaserver_config_v1"

-- 缓存策略：静态资源如何声明可缓存性（会同时配合 ETag / Last-Modified 协商）
M.CACHE_MODES = { "off", "validate", "short", "long" }

M.CACHE_LABELS = {
  off = "不缓存（no-store）",
  validate = "协商缓存（ETag / Last-Modified）",
  short = "短缓存（5 分钟）",
  long = "长缓存（1 天）",
}

local CACHE_MAX_AGE = {
  off = nil,
  validate = nil,      -- 使用 no-cache + ETag 协商
  short = 300,
  long = 86400,
}

M.cacheMaxAge = function(mode)
  return CACHE_MAX_AGE[mode] or nil
end

local DEFAULTS = {
  port = 8080,
  listenLan = false,       -- false: 127.0.0.1  true: 0.0.0.0
  maxConnections = 4,
  timeoutMs = 10000,
  indexFile = "index.html",
  directoryIndex = false,  -- 目录索引默认关闭
  cacheMode = "validate",
  rootPath = nil,          -- nil 表示使用默认 www 目录
}

--- 默认网站根目录：应用私有文件目录下的 www
-- 必须与"当前运行的脚本位置"无关：
--   * getLuaDir() 在从子目录（如 tools/）运行时会返回子目录，曾导致默认根目录被污染成 tools/www；
--   * getFilesDir() 由包名决定，Activity 与 Service 取值一致，且属于应用私有目录。
function M.defaultRoot(context)
  local host = context or activity
  local dir = nil
  pcall(function() dir = host.getFilesDir() end)
  if dir ~= nil then
    local path = nil
    pcall(function() path = dir.getAbsolutePath() end)
    if type(path) == "string" and #path > 0 then
      return path .. "/www"
    end
  end
  -- 退化方案：仍使用 Lua 工作目录
  local ok, fallback = pcall(function() return host.getLuaDir("www") end)
  if ok and type(fallback) == "string" and #fallback > 0 then return fallback end
  return "/sdcard/LuaServer/www"
end

function M.defaults(context)
  return {
    port = DEFAULTS.port,
    listenLan = DEFAULTS.listenLan,
    maxConnections = DEFAULTS.maxConnections,
    timeoutMs = DEFAULTS.timeoutMs,
    indexFile = DEFAULTS.indexFile,
    directoryIndex = DEFAULTS.directoryIndex,
    cacheMode = DEFAULTS.cacheMode,
    rootPath = M.defaultRoot(context),
  }
end

--- 取值范围收敛，保证线程/端口参数始终可用
function M.normalize(cfg, context)
  cfg = cfg or M.defaults(context)
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
  cfg.directoryIndex = cfg.directoryIndex and true or false

  local indexFile = tostring(cfg.indexFile or "")
  indexFile = string.gsub(indexFile, "[/\\]", "")
  if indexFile == "" then indexFile = DEFAULTS.indexFile end
  cfg.indexFile = indexFile

  local mode = tostring(cfg.cacheMode or "")
  local valid = false
  for i = 1, #M.CACHE_MODES do
    if M.CACHE_MODES[i] == mode then valid = true break end
  end
  if not valid then mode = DEFAULTS.cacheMode end
  cfg.cacheMode = mode

  local root = tostring(cfg.rootPath or "")
  if root == "" then root = M.defaultRoot(context) end
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

function M.load(context)
  local host = context or activity
  local cfg = M.defaults(host)
  local ok, raw = pcall(function() return host.getSharedData(KEY) end)
  if ok and type(raw) == "string" and #raw > 2 then
    local decodedOk, saved = pcall(json.decode, raw)
    if decodedOk and type(saved) == "table" then
      if type(saved.port) == "number" then cfg.port = saved.port end
      if type(saved.listenLan) == "boolean" then cfg.listenLan = saved.listenLan end
      if type(saved.maxConnections) == "number" then cfg.maxConnections = saved.maxConnections end
      if type(saved.timeoutMs) == "number" then cfg.timeoutMs = saved.timeoutMs end
      if type(saved.indexFile) == "string" and saved.indexFile ~= "" then cfg.indexFile = saved.indexFile end
      if type(saved.directoryIndex) == "boolean" then cfg.directoryIndex = saved.directoryIndex end
      if type(saved.cacheMode) == "string" then cfg.cacheMode = saved.cacheMode end
      if type(saved.rootPath) == "string" and saved.rootPath ~= "" then cfg.rootPath = saved.rootPath end
    end
  end
  return M.normalize(cfg, host)
end

function M.save(cfg, context)
  local host = context or activity
  local ok, err = pcall(function()
    host.setSharedData(KEY, json.encode(cfg))
  end)
  if not ok then return false, tostring(err) end
  return true
end

--- 恢复默认值（保留网站根目录）
function M.reset(cfg, context)
  local fresh = M.defaults(context)
  fresh.rootPath = cfg and cfg.rootPath or fresh.rootPath
  return M.normalize(fresh, context)
end

return M
