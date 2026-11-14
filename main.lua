-- LuaServer 入口：构建 MD3 界面、启动 HTTP 服务管理逻辑
--
-- 业务代码分布在 core/、server/、ui/、www/ 中，本文件只负责组装与生命周期。
local shell = require "ui.shell"

local app = shell.start()

--- 应用销毁（返回键退出、任务被清理）：务必停止服务器线程并释放端口
function onDestroy()
  if app then
    pcall(app.destroy)
    app = nil
  end
end

--- 切到后台时暂停界面刷新定时器，回到前台再恢复
function onPause()
  if app and app.clock then
    pcall(function() app.clock.setEnabled(false) end)
  end
end

function onResume()
  if app and app.clock then
    pcall(function() app.clock.setEnabled(true) end)
  end
end

--- 统一错误出口：完整堆栈写进日志，避免静默失败
function onError(error, message)
  print("LuaServer 运行错误：" .. tostring(error) .. " " .. tostring(message))
  return "trace"
end
