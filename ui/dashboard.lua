-- ui/dashboard.lua — 首页：运行状态、访问地址、统计数据、启动/停止
local theme = require "ui.theme"
local utils = require "core.utils"

local W = theme.W
local M = {}

function M.new(app)
  local page = { app = app, views = {}, root = nil }

  local function build()
    local c = theme.colors()
    local views = page.views
    local layout = theme.page({
      theme.card({ theme.cardBody({
        {
          W.Text,
          id = "dashStateText",
          text = "已停止",
          textSize = "22sp",
          textStyle = "bold",
          textColor = c.onSurface,
          layout_width = "match",
          layout_height = "wrap",
        },
        theme.caption("dashStateDesc", "服务未启动，点击下方按钮开始监听", { marginTop = "6dp" }),
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "14dp",
          {
            W.Text,
            id = "dashDot",
            text = "●",
            textSize = "13sp",
            textColor = c.outline,
            layout_width = "wrap",
            layout_height = "wrap",
            layout_marginEnd = "6dp",
            layout_gravity = "center_vertical",
          },
          {
            W.Text,
            id = "dashListen",
            text = "监听 127.0.0.1:8080",
            textSize = "13sp",
            textColor = c.onSurfaceVariant,
            layout_width = "0dp",
            layout_height = "wrap",
            layout_weight = 1,
            layout_gravity = "center_vertical",
          },
        },
        theme.button("dashToggle", "启动服务器", { marginTop = "18dp" }),
      }) }, { marginTop = "8dp" }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "访问地址"),
        theme.kv("本机", "dashLocalUrl", "—"),
        theme.kv("局域网", "dashLanUrl", "未开启"),
        theme.caption("dashLanHint", "局域网访问需在「服务设置」中切换监听范围，同一 Wi-Fi 下的设备才能访问。",
          { marginTop = "10dp" }),
      }, { paddingTop = "14dp", paddingBottom = "14dp" }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "运行数据"),
        theme.statRow({
          theme.statCell("dashTotal", "累计请求"),
          theme.statCell("dashSuccess", "成功"),
          theme.statCell("dashFailure", "错误"),
        }, { marginTop = "14dp" }),
        theme.statRow({
          theme.statCell("dashActive", "活动连接"),
          theme.statCell("dashPort", "端口"),
          theme.statCell("dashUptime", "运行时长"),
        }, { marginTop = "16dp" }),
        theme.divider("14dp"),
        theme.caption(nil, "计数从服务启动开始累计，清空日志不会重置运行时长。", { marginTop = "10dp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "关于第一版"),
        theme.caption(nil,
          "服务器仅在应用运行期间工作：退出应用或系统回收进程后服务会停止。"
            .. "默认只监听 127.0.0.1，请勿把该服务直接暴露到公网。",
          { marginTop = "8dp" }),
      }, { paddingTop = "14dp", paddingBottom = "14dp" }) }),
    }, { paddingBottom = "10dp" })

    page.root = loadlayout(layout, views)
    views.dashToggle.setOnClickListener(function() page.toggle() end)
    return page.root
  end

  function page.toggle()
    local server = app.server
    if server:isRunning() then
      local ok, err = server:stop()
      theme.toast(ok and "服务器已停止，端口已释放" or tostring(err))
    else
      local ok, detail = server:start()
      if ok then
        theme.toast("服务器已启动：" .. server:localUrl())
      else
        theme.toast(tostring(detail))
      end
    end
    page.refresh()
    if app.onStateChange then app.onStateChange() end
  end

  function page.refresh()
    if not page.root then return end
    local c = theme.colors()
    local views = page.views
    local server = app.server
    local stats = app.logger:stats()
    local running = server:isRunning()

    views.dashStateText.setText(running and "运行中" or "已停止")
    views.dashStateText.setTextColor(running and c.primary or c.onSurface)
    views.dashDot.setTextColor(running and c.success or c.outline)
    views.dashStateDesc.setText(running
      and "服务器正在监听，可以用浏览器访问下方地址"
      or "服务未启动，点击下方按钮开始监听")
    views.dashListen.setText((running and "监听 " or "计划监听 ") .. server.host .. ":" .. tostring(server.port))
    views.dashToggle.setText(running and "停止服务器" or "启动服务器")

    views.dashLocalUrl.setText(running and server:localUrl() or "—")
    local lanUrl = server:lanUrl()
    if not running then
      views.dashLanUrl.setText("服务器未运行")
    elseif server.config.listenLan then
      views.dashLanUrl.setText(lanUrl or "未检测到局域网地址")
    else
      views.dashLanUrl.setText("未开启局域网监听")
    end

    views.dashTotal.setText(tostring(stats.total))
    views.dashSuccess.setText(tostring(stats.success))
    views.dashFailure.setText(tostring(stats.failure))
    views.dashFailure.setTextColor(stats.failure > 0 and c.error or c.onSurface)
    views.dashActive.setText(tostring(stats.active))
    views.dashPort.setText(tostring(server.port))
    views.dashUptime.setText(running and utils.formatUptime(server:uptimeMs()) or "—")
  end

  function page.view()
    if not page.root then build() end
    return page.root
  end

  return page
end

return M
