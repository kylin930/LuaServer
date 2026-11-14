-- LuaServer 入口：构建 MD3 界面，并通过 Android 前台服务托管 HTTP 服务器
--
-- 业务代码分布在 core/、server/、ui/、www/ 中，本文件只负责组装与生命周期。
-- 重要：HTTP 服务器运行在 service.lua 的前台服务里，因此 Activity 销毁
-- （切到其他应用、锁屏、进程内 Activity 重建）都不会中断服务。
local shell = require "ui.shell"

local app = shell.start()

--- Activity 销毁：只停止 UI 刷新，不停止服务器
function onDestroy()
  if app then
    pcall(app.destroy)
    app = nil
  end
end

--- 切到后台：暂停界面刷新（服务器照常工作）
function onPause()
  if app then pcall(function() app.setPaused(true) end) end
end

function onResume()
  if app then pcall(function() app.setPaused(false) end) end
end

--- 统一错误出口：完整堆栈写日志，便于定位
function onError(error, message)
  print("LuaServer 运行错误：" .. tostring(error) .. " " .. tostring(message))
  return "trace"
end
