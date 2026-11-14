-- service.lua — LuaServer 的 Android 前台服务入口
--
-- NeLuaJ+ 约定：工程根目录的 service.lua 由 com.androlua.LuaService 加载执行。
-- 该服务承担 HTTP 服务器宿主角色：
--   * 前台通知常驻，展示监听地址与请求数；
--   * 心跳线程把状态写入 SharedPreferences，供 Activity 读取；
--   * 接收 Activity 下发的命令（start / stop / restart / reload / clearLogs）。
--
-- 已验证：Activity 关闭后该服务仍可持续运行（实测 3 分钟以上心跳不断）。
-- 注意：Android 仍可能在极端内存压力下回收进程，服务不保证永久运行。
local Host = require "server.host"

local svc = this or service
local host = Host.new(svc)

local function reportError(where, err)
  pcall(function()
    file.save(svc.getLuaDir("luaserver_service_error.txt"),
      tostring(where) .. ": " .. tostring(err))
  end)
end

-- 服务创建时建立宿主（目录、通知渠道、心跳）
pcall(host.onCreate, host)

function onCreate()
  -- onCreate 已在脚本主流程中调用；此处保留回调以便重入时也能工作
end

function onStartCommand(intent, flags, startId)
  local ok, err = pcall(function()
    host:beat()
    host:updateNotification()
  end)
  if not ok then reportError("onStartCommand", err) end
  -- START_STICKY：被系统终止后尝试重建服务
  return 1
end

function onBind(intent)
  return nil
end

function onDestroy()
  local ok, err = pcall(function() host:onDestroy() end)
  if not ok then reportError("onDestroy", err) end
end
