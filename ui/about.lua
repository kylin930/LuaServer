-- ui/about.lua — 关于：版本、简介、运行环境、许可
local theme = require "ui.theme"

local W = theme.W
local Build = luajava.bindClass "android.os.Build"
local System = luajava.bindClass "java.lang.System"

local M = {}

local function safe(getter, fallback)
  local ok, value = pcall(getter)
  if ok and value ~= nil then return tostring(value) end
  return fallback
end

function M.new(app)
  local page = { app = app, views = {}, root = nil }

  local function build()
    local c = theme.colors()
    local views = page.views
    local layout = theme.page({
      theme.card({ theme.cardBody({
        {
          W.Text,
          text = "LuaServer",
          textSize = "24sp",
          textStyle = "bold",
          textColor = c.onSurface,
          layout_width = "match",
          layout_height = "wrap",
        },
        theme.caption("aboutVersion", "版本 —", { marginTop = "4dp" }),
        theme.caption(nil,
          "用 Lua 编写的 Android 本地 HTTP 服务器：在手机上托管静态站点、在局域网内访问，"
            .. "并在应用内查看请求日志与运行状态。",
          { marginTop = "12dp" }),
      }, { marginTop = "8dp" }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "运行环境"),
        theme.kv("Android", "aboutAndroid", "—"),
        theme.kv("Lua", "aboutLua", "—"),
        theme.kv("Java VM", "aboutVm", "—"),
        theme.kv("网站根目录", "aboutWebRoot", "—", { size = "12.5sp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "服务说明"),
        theme.kv("默认端口", "aboutPort", "—"),
        theme.kv("默认监听", "aboutListen", "—"),
        theme.kv("并发上限", "aboutConcurrency", "—"),
        theme.kv("请求超时", "aboutTimeout", "—"),
        theme.caption(nil,
          "第一版只在应用运行期间提供服务，尚未实现 Android 前台服务，"
            .. "因此退出应用后服务会停止。若需要常驻运行，需要后续实现 Foreground Service。",
          { marginTop = "12dp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "许可与致谢"),
        theme.caption(nil, "本示例工程采用 MIT 许可证，可以自由修改和分发。"),
        theme.caption(nil, "HTTP 解析、静态文件托管与路由均由 Lua 实现，"
          .. "底层网络使用 Android 自带的 java.net.ServerSocket / java.net.Socket。", { marginTop = "8dp" }),
      }) }),
    }, { paddingBottom = "10dp" })

    page.root = loadlayout(layout, views)
    return page.root
  end

  function page.refresh()
    if not page.root then return end
    local views = page.views
    local cfg = app.config
    views.aboutVersion.setText("版本 " .. safe(function() return activity.getVersionName("1.0") end, "1.0")
      .. " · " .. safe(function() return activity.getPackageName() end, "未知包名"))
    views.aboutAndroid.setText("Android " .. safe(function() return Build.VERSION.RELEASE end, "?")
      .. "（API " .. safe(function() return Build.VERSION.SDK_INT end, "?") .. "）")
    views.aboutLua.setText(safe(function() return _VERSION end, "Lua"))
    views.aboutVm.setText(safe(function() return System.getProperty("java.vm.version") end, "未知"))
    views.aboutWebRoot.setText(cfg.rootPath)
    views.aboutPort.setText(tostring(cfg.port))
    views.aboutListen.setText(cfg.listenLan and "0.0.0.0（局域网）" or "127.0.0.1（仅本机）")
    views.aboutConcurrency.setText(tostring(cfg.maxConnections) .. " 个连接")
    views.aboutTimeout.setText(tostring(cfg.timeoutMs) .. " 毫秒")
  end

  function page.onShow()
    if not page.root then build() end
    page.refresh()
  end

  function page.view()
    if not page.root then build() end
    return page.root
  end

  return page
end

return M
