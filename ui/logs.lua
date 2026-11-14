-- ui/logs.lua — 请求日志：搜索、按状态码过滤、清空、自动滚动到最新
--
-- 日志由后台服务维护（server/host.lua 随心跳下发到 SharedPreferences），
-- 本页只负责展示与筛选，避免请求量大时重复渲染造成卡顿。
local theme = require "ui.theme"
local utils = require "core.utils"

local TextWatcher = luajava.bindClass "android.text.TextWatcher"

local W = theme.W
local M = {}

local MAX_ROWS = 50          -- 单次最多渲染行数
local MAX_QUERY_ROWS = 200   -- 搜索时最多扫描的日志条数

local FILTERS = {
  { key = "all", label = "全部" },
  { key = "2xx", label = "2xx" },
  { key = "4xx", label = "4xx" },
  { key = "5xx", label = "5xx" },
  { key = "event", label = "事件" },
}

local function statusColor(c, status)
  if status >= 500 then return c.error end
  if status >= 400 then return c.warning end
  if status >= 300 then return c.onSurfaceVariant end
  return c.success
end

local function matchesFilter(entry, filter)
  if filter == "all" then return true end
  if filter == "event" then return entry.k == "event" end
  if filter == "2xx" then return entry.s >= 200 and entry.s < 300 end
  if filter == "4xx" then return entry.s >= 400 and entry.s < 500 end
  if filter == "5xx" then return entry.s >= 500 end
  return true
end

local function matchesQuery(entry, query)
  if query == "" then return true end
  local needle = string.lower(query)
  local haystack = string.lower(table.concat({
    entry.p or "", " ", entry.m or "", " ", entry.c or "", " ", tostring(entry.s or 0),
  }))
  return string.find(haystack, needle, 1, true) ~= nil
end

function M.new(app)
  local page = {
    app = app,
    views = {},
    root = nil,
    filter = "all",
    query = "",
    renderedKey = "",
    renderedCount = 0,
  }

  local function rowLayout(entry)
    local c = theme.colors()
    local isEvent = entry.k == "event"
    local title, statusText, color
    if isEvent then
      title = entry.p or ""
      statusText = "事件"
      color = c.primary
    else
      title = (entry.m or "-") .. " " .. (entry.p or "")
      statusText = tostring(entry.s or 0)
      color = statusColor(c, entry.s or 0)
    end
    local meta = table.concat({
      entry.t or "", " · ", tostring(entry.d or 0), "ms · ", entry.c or "-",
    })
    return {
      W.Card,
      layout_width = "match",
      layout_height = "wrap",
      layout_marginTop = "6dp",
      radius = "12dp",
      cardElevation = 0,
      strokeWidth = "1dp",
      strokeColor = c.outlineVariant,
      CardBackgroundColor = c.surfaceContainerLow,
      {
        W.Linear,
        orientation = "vertical",
        layout_width = "match",
        layout_height = "wrap",
        paddingStart = "12dp",
        paddingEnd = "12dp",
        paddingTop = "9dp",
        paddingBottom = "9dp",
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          {
            W.Text,
            text = title,
            textSize = "12.5sp",
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
            textSize = "11.5sp",
            textStyle = "bold",
            textColor = color,
            layout_width = "wrap",
            layout_height = "wrap",
            layout_marginStart = "8dp",
          },
        },
        {
          W.Text,
          text = meta,
          textSize = "11sp",
          textColor = c.onSurfaceVariant,
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "2dp",
        },
      },
    }
  end

  local function build()
    local c = theme.colors()
    local views = page.views

    -- 过滤条：ChipGroup 用文本按钮实现，避免依赖特定 Chip 行为
    local filterBar = {
      W.Linear,
      orientation = "horizontal",
      layout_width = "match",
      layout_height = "wrap",
      layout_marginTop = "10dp",
    }
    views.filterButtons = {}
    for i = 1, #FILTERS do
      local item = FILTERS[i]
      local buttonNode = theme.button("logFilter" .. i, item.label, {
        outlined = true,
        width = "wrap",
        height = "34dp",
        size = "12sp",
        marginTop = "0dp",
        marginStart = i == 1 and "0dp" or "6dp",
        marginEnd = "0dp",
      })
      filterBar[#filterBar + 1] = buttonNode
    end

    local layout = theme.page({
      theme.card({ theme.cardBody({
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          {
            W.Text,
            text = "请求日志",
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
        {
          W.InputLayout,
          id = "logSearchLayout",
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "12dp",
          hint = "搜索路径 / 方法 / 客户端 IP",
          {
            W.Input,
            id = "logSearch",
            layout_width = "match",
            layout_height = "wrap",
            singleLine = true,
            inputType = "text",
          },
        },
        filterBar,
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
          text = "暂无日志。启动服务器后用浏览器访问即可看到记录。",
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
      app.controller:clearLogs()
      theme.toast("已请求清空日志")
      page.renderedKey = ""
      page.render(true)
    end)

    -- 文本变化监听：接口由 Lua 表代理实现（Java 接口用 createProxy/表实现）
    local watchOk = pcall(function()
      local watcher = TextWatcher {
        afterTextChanged = function(editable)
          local text = ""
          local okText, value = pcall(function() return editable.toString() end)
          if okText and type(value) == "string" then text = value end
          page.query = utils.trim(text)
          page.render(true)
        end,
        beforeTextChanged = function() end,
        onTextChanged = function() end,
      }
      views.logSearch.addTextChangedListener(watcher)
    end)
    if not watchOk then
      -- 退化方案：输入完成后（失焦）再应用搜索词
      pcall(function()
        views.logSearch.setOnFocusChangeListener(function(_, hasFocus)
          if not hasFocus then
            page.query = utils.trim(theme.textOf(views.logSearch))
            page.render(true)
          end
        end)
      end)
    end

    for i = 1, #FILTERS do
      local button = views["logFilter" .. i]
      if button then
        button.setOnClickListener(function()
          page.filter = FILTERS[i].key
          page.updateFilterStyles()
          page.render(true)
        end)
      end
    end
    page.updateFilterStyles()
    return page.root
  end

  --- 用文字与颜色表达选中态，不依赖 MaterialButton 的 checked 语义
  function page.updateFilterStyles()
    if not page.views.filterButtons then return end
    local c = theme.colors()
    for i = 1, #FILTERS do
      local button = page.views["logFilter" .. i]
      if button then
        local active = FILTERS[i].key == page.filter
        pcall(function()
          button.setText((active and "● " or "") .. FILTERS[i].label)
        end)
        pcall(function()
          button.setTextColor(active and c.primary or c.onSurfaceVariant)
        end)
      end
    end
  end

  --- 依据当前筛选条件渲染列表；内容未变化时跳过重建
  function page.render(force)
    if not page.root then return end
    local logs = app.controller.state.logs or {}

    -- 先过滤
    local filtered = {}
    local scanned = 0
    for i = 1, #logs do
      if scanned >= MAX_QUERY_ROWS then break end
      scanned = scanned + 1
      local entry = logs[i]
      if matchesFilter(entry, page.filter) and matchesQuery(entry, page.query) then
        filtered[#filtered + 1] = entry
        if #filtered >= MAX_ROWS then break end
      end
    end

    -- 生成渲染指纹，避免每 800ms 无谓重建视图
    local key = table.concat({ page.filter, page.query, tostring(#logs), tostring(#filtered),
      tostring(logs[1] and logs[1].t or ""), tostring(logs[1] and logs[1].s or "") })
    if not force and key == page.renderedKey then return end
    page.renderedKey = key

    local list = page.views.logList
    list.removeAllViews()
    for i = 1, #filtered do
      local holder = {}
      local rowView = loadlayout(rowLayout(filtered[i]), holder)
      list.addView(rowView)
    end

    local empty = #filtered == 0
    page.views.logEmpty.setVisibility(empty and W.View.VISIBLE or W.View.GONE)
    if empty then
      if #logs == 0 then
        page.views.logEmpty.setText("暂无日志。启动服务器后用浏览器访问即可看到记录。")
      else
        page.views.logEmpty.setText("当前筛选条件下没有匹配的日志。")
      end
    end
    page.renderedCount = #filtered
  end

  function page.onShow()
    if not page.root then build() end
    page.render(true)
    page.refresh()
  end

  function page.refresh()
    if not page.root then return end
    page.render(false)
    local stats = app.controller.state
    local shown = page.renderedCount or 0
    page.views.logSummary.setText(string.format(
      "累计 %d 次 · 成功 %d · 错误 %d · 活动 %d · 平均 %.0fms · 显示 %d 条",
      stats.total or 0, stats.success or 0, stats.failure or 0, stats.active or 0,
      tonumber(stats.avgMs) or 0, shown))
  end

  function page.view()
    if not page.root then build() end
    return page.root
  end

  return page
end

return M
