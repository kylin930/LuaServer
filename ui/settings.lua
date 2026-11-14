-- ui/settings.lua — 服务设置：端口、监听范围、并发、超时、站点、目录索引、缓存策略
local theme = require "ui.theme"
local configModule = require "core.config"
local utils = require "core.utils"

local W = theme.W
local M = {}

local CACHE_CHOICES = {
  { key = "off", label = "不缓存（no-store）", desc = "每次都重新下载，最省心但流量最大" },
  { key = "validate", label = "协商缓存（推荐）", desc = "带 ETag / Last-Modified，未变更时返回 304" },
  { key = "short", label = "短缓存 5 分钟", desc = "适合会偶尔更新的静态资源" },
  { key = "long", label = "长缓存 1 天", desc = "适合不常变动的图片、字体" },
}

function M.new(app)
  local page = { app = app, views = {}, root = nil, cacheIndex = 2 }

  local function currentCacheIndex(mode)
    for i = 1, #CACHE_CHOICES do
      if CACHE_CHOICES[i].key == mode then return i end
    end
    return 2
  end

  local function collect()
    return {
      port = tonumber(utils.trim(theme.textOf(page.views.setPort))),
      maxConnections = tonumber(utils.trim(theme.textOf(page.views.setMaxConn))),
      timeoutMs = tonumber(utils.trim(theme.textOf(page.views.setTimeout))),
      indexFile = utils.trim(theme.textOf(page.views.setIndex)),
      listenLan = page.views.setScopeLan.isChecked() and true or false,
      directoryIndex = page.views.setDirIndex.isChecked() and true or false,
      cacheMode = CACHE_CHOICES[page.cacheIndex].key,
      rootPath = app.config.rootPath,
    }
  end

  local function save()
    local candidate = collect()
    local ok, err = configModule.validate(candidate)
    if not ok then
      theme.toast(err)
      return
    end
    local normalized = configModule.normalize(candidate, activity)
    local wasRunning = app.controller:isRunning()
    local portChanged = normalized.port ~= (app.config.port or 0)
    local scopeChanged = normalized.listenLan ~= (app.config.listenLan and true or false)

    local applied, applyErr = app.applyConfig(normalized)
    if applied == false and applyErr then
      theme.toast("设置已保存，但同步失败：" .. tostring(applyErr))
    elseif wasRunning and (portChanged or scopeChanged) then
      theme.toast("设置已保存，服务器已按新配置重启")
    else
      theme.toast("设置已保存")
    end
    page.refresh()
    if app.onStateChange then app.onStateChange() end
  end

  local function build()
    local c = theme.colors()
    local views = page.views

    -- 缓存策略选择
    local cacheGroup = {
      W.RadioGroup,
      id = "setCacheGroup",
      orientation = "vertical",
      layout_width = "match",
      layout_height = "wrap",
      layout_marginTop = "6dp",
    }
    for i = 1, #CACHE_CHOICES do
      cacheGroup[#cacheGroup + 1] = {
        W.Radio,
        id = "setCache" .. i,
        text = CACHE_CHOICES[i].label,
        textSize = "14sp",
        textColor = c.onSurface,
        layout_width = "match",
        layout_height = "wrap",
      }
    end

    local layout = theme.page({
      theme.card({ theme.cardBody({
        theme.heading(nil, "网络"),
        theme.input("setPort", "HTTP 端口", { marginTop = "14dp" }),
        theme.caption(nil, "端口范围 1024 - 65535，默认 8080。", { marginTop = "6dp" }),
        theme.divider("16dp"),
        theme.heading(nil, "监听范围", { marginTop = "16dp" }),
        {
          W.RadioGroup,
          id = "setScopeGroup",
          orientation = "vertical",
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "4dp",
          {
            W.Radio,
            id = "setScopeLocal",
            text = "仅本机（127.0.0.1）",
            textSize = "14sp",
            textColor = c.onSurface,
            layout_width = "match",
            layout_height = "wrap",
            checked = true,
          },
          {
            W.Radio,
            id = "setScopeLan",
            text = "局域网（0.0.0.0）",
            textSize = "14sp",
            textColor = c.onSurface,
            layout_width = "match",
            layout_height = "wrap",
          },
        },
        theme.caption("setLanWarning",
          "局域网模式下同一 Wi-Fi 内的其他设备都可以访问本服务器，请只在可信网络中开启。",
          { color = c.warning, marginTop = "8dp" }),
      }, { marginTop = "8dp" }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "性能与超时"),
        theme.input("setMaxConn", "最大并发连接数"),
        theme.input("setTimeout", "请求超时（毫秒）"),
        theme.caption(nil, "并发连接数 1 - 16，请求超时 1000 - 60000 毫秒。",
          { marginTop = "6dp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "站点"),
        theme.input("setIndex", "默认首页文件", { inputType = "text", marginTop = "14dp" }),
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "16dp",
          {
            W.Text,
            text = "允许目录索引",
            textSize = "14sp",
            textColor = c.onSurface,
            layout_width = "0dp",
            layout_height = "wrap",
            layout_weight = 1,
            layout_gravity = "center_vertical",
          },
          {
            W.Switch,
            id = "setDirIndex",
            layout_width = "wrap",
            layout_height = "wrap",
          },
        },
        theme.caption(nil,
          "默认关闭：没有默认首页的目录会返回 403，不会暴露目录文件列表。",
          { marginTop = "6dp" }),
        theme.divider("16dp"),
        theme.kv("根目录", "setRootPath", "—", { marginTop = "12dp" }),
        theme.button("setRootDefault", "使用应用默认目录",
          { outlined = true, marginTop = "12dp", height = "44dp", size = "14sp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "缓存策略"),
        theme.caption("setCacheDesc", "", { marginTop = "6dp" }),
        cacheGroup,
        theme.caption(nil,
          "协商缓存会为静态文件生成 ETag 与 Last-Modified，浏览器再次请求时若文件未变返回 304，"
            .. "既省流量又能及时看到更新。",
          { marginTop = "10dp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.button("setSave", "保存设置", { marginTop = "2dp" }),
        theme.caption(nil,
          "保存后立即写入本地配置；若服务器正在运行，会按新配置重启（端口或监听范围变化时）。",
          { marginTop = "10dp" }),
      }) }),
    }, { paddingBottom = "10dp" })

    page.root = loadlayout(layout, views)
    views.setSave.setOnClickListener(function() save() end)
    views.setRootDefault.setOnClickListener(function()
      app.config.rootPath = configModule.defaultRoot(activity)
      page.refresh()
      theme.toast("已切回默认目录，点击保存生效")
    end)
    views.setScopeLan.setOnCheckedChangeListener(function(_, isChecked)
      page.updateLanWarning(isChecked)
    end)
    views.setCacheGroup.setOnCheckedChangeListener(function(_, checkedId)
      for i = 1, #CACHE_CHOICES do
        if views["setCache" .. i] and views["setCache" .. i].getId() == checkedId then
          page.cacheIndex = i
          page.updateCacheDesc()
          return
        end
      end
    end)
    return page.root
  end

  function page.updateCacheDesc()
    if not page.root then return end
    local choice = CACHE_CHOICES[page.cacheIndex]
    page.views.setCacheDesc.setText(choice and choice.desc or "")
  end

  function page.updateLanWarning(isChecked)
    if not page.root then return end
    page.views.setLanWarning.setVisibility(isChecked and W.View.VISIBLE or W.View.GONE)
  end

  --- 进入页面时把当前配置回填到输入框，并同步 "正在运行" 的提示
  function page.onShow()
    if not page.root then build() end
    local cfg = app.config
    local views = page.views
    views.setPort.setText(tostring(cfg.port))
    views.setMaxConn.setText(tostring(cfg.maxConnections))
    views.setTimeout.setText(tostring(cfg.timeoutMs))
    views.setIndex.setText(tostring(cfg.indexFile))
    views.setScopeLan.setChecked(cfg.listenLan and true or false)
    views.setScopeLocal.setChecked(not cfg.listenLan)
    views.setDirIndex.setChecked(cfg.directoryIndex and true or false)

    page.cacheIndex = currentCacheIndex(cfg.cacheMode)
    local cacheRadio = views["setCache" .. page.cacheIndex]
    if cacheRadio then cacheRadio.setChecked(true) end
    page.updateCacheDesc()
    page.refresh()
  end

  function page.refresh()
    if not page.root then return end
    local views = page.views
    views.setRootPath.setText(app.config.rootPath)
    page.updateLanWarning(views.setScopeLan.isChecked())
  end

  function page.view()
    if not page.root then build() end
    return page.root
  end

  return page
end

return M
