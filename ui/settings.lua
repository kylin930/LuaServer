-- ui/settings.lua — 服务设置：端口、监听范围、并发、超时、首页、根目录
local theme = require "ui.theme"
local configModule = require "core.config"
local utils = require "core.utils"

local W = theme.W
local M = {}

function M.new(app)
  local page = { app = app, views = {}, root = nil }

  local function collect()
    return {
      port = tonumber(utils.trim(theme.textOf(page.views.setPort))),
      maxConnections = tonumber(utils.trim(theme.textOf(page.views.setMaxConn))),
      timeoutMs = tonumber(utils.trim(theme.textOf(page.views.setTimeout))),
      indexFile = utils.trim(theme.textOf(page.views.setIndex)),
      listenLan = page.views.setScopeLan.isChecked() and true or false,
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
    local normalized = configModule.normalize(candidate)
    local saved, saveErr = configModule.save(normalized)
    if not saved then
      theme.toast("保存失败：" .. tostring(saveErr))
      return
    end
    local restarted, restartErr = app.applyConfig(normalized)
    if restarted == false and restartErr then
      theme.toast("设置已保存，但重启失败：" .. tostring(restartErr))
    else
      theme.toast(restarted and "设置已保存，服务器已重启" or "设置已保存")
    end
    page.refresh()
    if app.onStateChange then app.onStateChange() end
  end

  local function build()
    local c = theme.colors()
    local views = page.views
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
          "局域网模式下同一 Wi-Fi 内的其他设备可以访问本服务器，请只在可信网络中开启。",
          { color = c.warning, marginTop = "8dp" }),
      }, { marginTop = "8dp" }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "性能与超时"),
        theme.input("setMaxConn", "最大并发连接数"),
        theme.input("setTimeout", "请求超时（毫秒）"),
        theme.caption(nil, "并发连接数 1 - 16，请求超时 1000 - 60000 毫秒。", { marginTop = "6dp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.heading(nil, "站点"),
        theme.input("setIndex", "默认首页文件", { inputType = "text", marginTop = "14dp" }),
        theme.kv("根目录", "setRootPath", "—", { marginTop = "16dp" }),
        theme.button("setRootDefault", "使用应用默认目录",
          { outlined = true, marginTop = "12dp", height = "44dp", size = "14sp" }),
      }) }),

      theme.card({ theme.cardBody({
        theme.button("setSave", "保存设置", { marginTop = "2dp" }),
        theme.caption(nil, "保存后若服务器正在运行且网络参数变化，会自动重启以生效。",
          { marginTop = "10dp" }),
      }) }),
    }, { paddingBottom = "10dp" })

    page.root = loadlayout(layout, views)
    views.setSave.setOnClickListener(function() save() end)
    views.setRootDefault.setOnClickListener(function()
      app.config.rootPath = configModule.defaultRoot()
      page.refresh()
      theme.toast("已切回默认目录，点击保存生效")
    end)
    views.setScopeLan.setOnCheckedChangeListener(function(_, isChecked)
      page.updateLanWarning(isChecked)
    end)
    return page.root
  end

  function page.updateLanWarning(isChecked)
    if not page.root then return end
    page.views.setLanWarning.setVisibility(isChecked and W.View.VISIBLE or W.View.GONE)
  end

  --- 进入页面时把当前配置回填到输入框（避免定时刷新覆盖用户输入）
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
