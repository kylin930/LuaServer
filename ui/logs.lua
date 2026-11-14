-- ui/logs.lua — 请求日志列表（最新的排在最前，行数有上限）
local theme = require "ui.theme"

local W = theme.W
local M = {}

local MAX_ROWS = 60

function M.new(app)
  local page = { app = app, views = {}, root = nil, renderedVersion = -1 }

  local function rowLayout(entry)
    local c = theme.colors()
    local isEvent = entry.kind == "event"
    local title, statusText, statusColor
    if isEvent then
      title = entry.path
      statusText = "事件"
      statusColor = c.primary
    else
      title = entry.method .. " " .. entry.path
      statusText = tostring(entry.status)
      statusColor = c.success
      if entry.status >= 500 then
        statusColor = c.error
      elseif entry.status >= 400 then
        statusColor = c.warning
      end
    end
    local meta = entry.time .. " · " .. tostring(entry.ms) .. "ms · " .. entry.client
    return {
      W.Card,
      layout_width = "match",
      layout_height = "wrap",
      layout_marginTop = "8dp",
      radius = "14dp",
      cardElevation = 0,
      strokeWidth = "1dp",
      strokeColor = c.outlineVariant,
      CardBackgroundColor = c.surfaceContainerLow,
      {
        W.Linear,
        orientation = "vertical",
        layout_width = "match",
        layout_height = "wrap",
        paddingStart = "14dp",
        paddingEnd = "14dp",
        paddingTop = "10dp",
        paddingBottom = "10dp",
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          {
            W.Text,
            text = title,
            textSize = "13sp",
            textColor = c.onSurface,
            layout_width = "0dp",
            layout_height = "wrap",
            layout_weight = 1,
            maxLines = 1,
            ellipsize = "END",
          },
          {
            W.Text,
            text = statusText,
            textSize = "12sp",
            textStyle = "bold",
            textColor = statusColor,
            layout_width = "wrap",
            layout_height = "wrap",
            layout_marginStart = "8dp",
          },
        },
        {
          W.Text,
          text = meta,
          textSize = "11.5sp",
          textColor = c.onSurfaceVariant,
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "3dp",
        },
      },
    }
  end

  local function build()
    local c = theme.colors()
    local views = page.views
    local layout = theme.page({
      theme.card({ theme.cardBody({
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          {
            W.Text,
            text = "最近请求",
            textSize = "15sp",
            textStyle = "bold",
            textColor = c.onSurface,
            layout_width = "0dp",
            layout_height = "wrap",
            layout_weight = 1,
            layout_gravity = "center_vertical",
          },
          theme.button("logClear", "清空",
            { flat = true, width = "wrap", height = "40dp", size = "13sp", marginTop = "0dp" }),
        },
        theme.caption("logSummary", "尚无请求", { marginTop = "6dp" }),
      }, { paddingTop = "12dp", paddingBottom = "12dp", padding = "12dp" }) }, { marginTop = "8dp" }),

      {
        W.Linear,
        orientation = "vertical",
        layout_width = "match",
        layout_height = "wrap",
        layout_marginStart = "16dp",
        layout_marginEnd = "16dp",
        layout_marginTop = "4dp",
        {
          W.Text,
          id = "logEmpty",
          text = "暂无请求记录，启动服务器后用浏览器访问即可看到日志。",
          textSize = "13sp",
          textColor = c.onSurfaceVariant,
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "16dp",
        },
        {
          W.Linear,
          id = "logList",
          orientation = "vertical",
          layout_width = "match",
          layout_height = "wrap",
        },
      },
    }, { paddingBottom = "10dp" })

    page.root = loadlayout(layout, views)
    views.logClear.setOnClickListener(function()
      app.logger:reset()
      page.render(true)
      page.refresh()
    end)
    return page.root
  end

  function page.render(force)
    if not page.root then return end
    local views = page.views
    if not force and page.renderedVersion == app.logger.version then return end
    page.renderedVersion = app.logger.version

    local history = app.logger:historySnapshot()
    views.logList.removeAllViews()
    local count = math.min(#history, MAX_ROWS)
    for i = 1, count do
      local holder = {}
      local rowView = loadlayout(rowLayout(history[i]), holder)
      views.logList.addView(rowView)
    end
    views.logEmpty.setVisibility(count == 0 and W.View.VISIBLE or W.View.GONE)
  end

  function page.onShow()
    if not page.root then build() end
    page.render(true)
    page.refresh()
  end

  function page.refresh()
    if not page.root then return end
    page.render(false)
    local stats = app.logger:stats()
    page.views.logSummary.setText(string.format("累计 %d 次 · 成功 %d · 错误 %d · 活动连接 %d",
      stats.total, stats.success, stats.failure, stats.active))
  end

  function page.view()
    if not page.root then build() end
    return page.root
  end

  return page
end

return M
