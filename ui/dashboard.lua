-- ui/dashboard.lua — 首页：运行状态、访问地址、统计数据、启动/停止、复制地址
local theme = require "ui.theme"
local utils = require "core.utils"

local W = theme.W
local M = {}

local ClipboardManager = luajava.bindClass "android.content.ClipboardManager"
local ClipData = luajava.bindClass "android.content.ClipData"
local Context = luajava.bindClass "android.content.Context"

function M.new(app)
  local page = { app = app, views = {}, root = nil }

  local function copyToClipboard(text)
    local ok = pcall(function()
      local manager = activity.getSystemService(Context.CLIPBOARD_SERVICE)
      manager.setPrimaryClip(ClipData.newPlainText("LuaServer 地址", text))
    end)
    return ok
  end

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
        theme.caption("dashServiceHint",
          "服务器运行在 Android 前台服务中：切到其他应用或锁屏后仍会继续工作，"
            .. "点击「停止服务器」才会释放端口。",
          { marginTop = "12dp" }),
      }) }, { marginTop = "8dp" }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "访问地址"),
        theme.kv("本机", "dashLocalUrl", "—"),
        theme.kv("局域网", "dashLanUrl", "未开启"),
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "14dp",
          theme.button("dashCopyLocal", "复制本机地址",
            { outlined = true, width = "0dp", weight = 1, height = "44dp", size = "13sp",
              marginTop = "0dp", marginStart = "0dp", marginEnd = "4dp" }),
          theme.button("dashCopyLan", "复制局域网地址",
            { outlined = true, width = "0dp", weight = 1, height = "44dp", size = "13sp",
              marginTop = "0dp", marginStart = "4dp", marginEnd = "0dp" }),
        },
        theme.caption("dashLanHint",
          "局域网访问需在「服务设置」中切换为局域网监听，且手机与其他设备处于同一 Wi-Fi。",
          { marginTop = "12dp" }),
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
          theme.statCell("dashAvgMs", "平均耗时"),
          theme.statCell("dashUptime", "运行时长"),
        }, { marginTop = "16dp" }),
        theme.divider("14dp"),
        theme.kv("监听端口", "dashPort", "—", { marginTop = "12dp" }),
        theme.kv("网站目录", "dashRoot", "—", { size = "12.5sp", marginTop = "8dp" }),
        theme.kv("已发送", "dashBytes", "—", { marginTop = "8dp" }),
        theme.caption(nil, "统计由后台服务维护；点击「停止服务器」后计数会随服务一起重置。",
          { marginTop = "12dp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "安全提示"),
        theme.caption(nil,
          "默认只监听 127.0.0.1，只有本机可以访问。开启局域网监听后，同一 Wi-Fi 内的设备都能访问，"
            .. "请只在可信网络中使用，不要把该服务直接暴露到公网。",
          { marginTop = "8dp" }),
      }, { paddingTop = "14dp", paddingBottom = "14dp" }) }),
    }, { paddingBottom = "10dp" })

    page.root = loadlayout(layout, views)
    views.dashToggle.setOnClickListener(function() page.toggle() end)
    views.dashCopyLocal.setOnClickListener(function()
      local url = page.app.controller:localUrl()
      theme.toast(copyToClipboard(url) and ("已复制 " .. url) or "复制失败")
    end)
    views.dashCopyLan.setOnClickListener(function()
      local url = page.app.controller:lanUrl()
      if not url then
        theme.toast("当前没有可复制的局域网地址")
        return
      end
      theme.toast(copyToClipboard(url) and ("已复制 " .. url) or "复制失败")
    end)
    return page.root
  end

  function page.toggle()
    local controller = app.controller
    local running = controller:isRunning()
    local ok, detail
    if running then
      ok, detail = controller:stop()
      theme.toast(ok and "已请求停止服务器" or tostring(detail))
    else
      ok, detail = controller:start()
      if ok then
        theme.toast("正在启动服务器…")
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
    local controller = app.controller
    local state = controller.state
    local running = controller:isRunning()
    local pending = controller.pendingAction

    -- 状态标题
    if pending == "start" and not running then
      views.dashStateText.setText("正在启动…")
      views.dashStateText.setTextColor(c.primary)
    elseif pending == "stop" and running then
      views.dashStateText.setText("正在停止…")
      views.dashStateText.setTextColor(c.onSurface)
    else
      views.dashStateText.setText(running and "运行中" or "已停止")
      views.dashStateText.setTextColor(running and c.primary or c.onSurface)
    end

    views.dashDot.setTextColor(running and c.success or c.outline)

    if running then
      views.dashStateDesc.setText("服务器正在监听，可以用浏览器访问下方地址")
    elseif state.lastError and state.lastError ~= "" then
      views.dashStateDesc.setText("上次错误：" .. tostring(state.lastError))
    else
      views.dashStateDesc.setText("服务未启动，点击下方按钮开始监听")
    end

    views.dashListen.setText((running and "监听 " or "计划监听 ")
      .. tostring(state.host or "127.0.0.1") .. ":" .. tostring(state.port))
    views.dashToggle.setText(running and "停止服务器" or "启动服务器")
    views.dashToggle.setEnabled(pending == nil)

    -- 地址
    views.dashLocalUrl.setText(running and controller:localUrl() or "—")
    if not running then
      views.dashLanUrl.setText("服务器未运行")
    elseif state.listenLan then
      local lanUrl = controller:lanUrl()
      if lanUrl then
        views.dashLanUrl.setText(lanUrl)
      elseif controller:hasLanAddress() then
        views.dashLanUrl.setText("未检测到局域网地址")
      else
        views.dashLanUrl.setText("Wi-Fi 未连接")
      end
    else
      views.dashLanUrl.setText("未开启局域网监听")
    end

    -- 统计
    views.dashTotal.setText(tostring(state.total or 0))
    views.dashSuccess.setText(tostring(state.success or 0))
    views.dashFailure.setText(tostring(state.failure or 0))
    views.dashFailure.setTextColor((state.failure or 0) > 0 and c.error or c.onSurface)
    views.dashActive.setText(tostring(state.active or 0))
    views.dashAvgMs.setText(string.format("%.0fms", tonumber(state.avgMs) or 0))
    views.dashUptime.setText(running and utils.formatUptime(state.uptimeMs) or "—")
    views.dashPort.setText(tostring(state.port or "—"))
    views.dashRoot.setText(tostring(state.rootPath or app.config.rootPath or "—"))
    views.dashBytes.setText(utils.formatBytes(state.bytesOut or 0))
  end

  function page.view()
    if not page.root then build() end
    return page.root
  end

  return page
end

return M
