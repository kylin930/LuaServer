-- ui/shell.lua — 应用外壳：工具栏 + 标签页 + 页面切换 + 主线程刷新定时器
local Screen = require "app.screen"
local theme = require "ui.theme"
local configModule = require "core.config"
local Logger = require "core.logger"
local ServerModule = require "server.server"
local staticFile = require "server.static_file"
local shellLayout = require "res.layout.main"

local W = theme.W
local M = {}

local TAB_TITLES = { "首页", "设置", "日志", "文件", "关于" }

--- 创建应用对象并启动界面
function M.start()
  local config = configModule.load()
  local logger = Logger.new(200)
  local server = ServerModule.new(config, logger)

  -- 首次运行生成默认站点；失败不影响界面启动
  local rootReady, rootInfo = staticFile.ensureRoot(config.rootPath)
  if not rootReady then
    logger:event("网站根目录不可用：" .. tostring(rootInfo))
  end

  local app = {
    config = config,
    logger = logger,
    server = server,
    clock = nil,
    pages = {},
  }

  --- 保存设置后应用新配置；运行中则自动重启
  function app.applyConfig(newConfig)
    local wasRunning = server:isRunning()
    app.config = newConfig
    server:applyConfig(newConfig)
    if wasRunning then
      local ok, detail = server:restart()
      if not ok then return false, detail end
      return true
    end
    return nil
  end

  local dashboard = require("ui.dashboard").new(app)
  local settingsPage = require("ui.settings").new(app)
  local logsPage = require("ui.logs").new(app)
  local filesPage = require("ui.files").new(app)
  local aboutPage = require("ui.about").new(app)
  app.pages = { dashboard, settingsPage, logsPage, filesPage, aboutPage }

  local views = Screen.show(shellLayout, "LuaServer")
  local pages = app.pages
  local currentIndex = 0
  app.views = views
  app.currentIndex = function() return currentIndex end

  local function updateSubtitle()
    if not views.toolbar then return end
    if server:isRunning() then
      views.toolbar.setSubtitle("运行中 · " .. server.host .. ":" .. tostring(server.port))
    else
      views.toolbar.setSubtitle("已停止")
    end
  end

  app.onStateChange = updateSubtitle

  local function showTab(index)
    index = math.max(1, math.min(#pages, index))
    local page = pages[index]
    local view = page.view()
    local parent = nil
    pcall(function() parent = view.getParent() end)
    if parent == nil then views.container.addView(view) end
    for i = 1, #pages do
      local other = pages[i]
      if other.root then
        other.root.setVisibility(i == index and W.View.VISIBLE or W.View.GONE)
      end
    end
    currentIndex = index
    if page.onShow then pcall(page.onShow) end
    if page.refresh then pcall(page.refresh) end
  end

  for i = 1, #TAB_TITLES do
    views.tabs.addTab(views.tabs.newTab().setText(TAB_TITLES[i]))
  end
  views.tabs.addOnTabSelectedListener(W.TabLayout.OnTabSelectedListener {
    onTabSelected = function(tab)
      local ok, err = pcall(function() showTab(tab.getPosition() + 1) end)
      if not ok then logger:event("切换页面失败：" .. tostring(err)) end
    end,
    onTabUnselected = function() end,
    onTabReselected = function() end,
  })

  updateSubtitle()
  showTab(1)

  -- 定时刷新：timer 回调运行在 LuaTimer 线程，因此 UI 更新必须经 call() 回到主线程。
  local clock
  clock = timer(function()
    pcall(function()
      call(function()
        local ok, err = pcall(function()
          local entries = logger:drain()
          if #entries > 0 then logger:pushHistory(entries) end
          local page = pages[currentIndex]
          if page and page.refresh then page.refresh() end
          updateSubtitle()
        end)
        if not ok then
          pcall(function() logger:event("界面刷新异常：" .. tostring(err)) end)
        end
      end)
    end)
  end, 200, 500)
  app.clock = clock

  --- 应用退出：停止服务器线程与定时器，释放端口
  function app.destroy()
    if app.clock then pcall(function() app.clock.stop() end) end
    app.clock = nil
    local stopped = false
    pcall(function() stopped = server:stop() end)
    if stopped then logger:event("应用退出：服务器已停止") end
  end

  return app
end

return M
