-- ui/shell.lua — 应用外壳：工具栏 + 标签页 + 页面切换 + 主线程刷新
--
-- 服务器运行在 LuaService 中（见 service.lua / server/host.lua），
-- 本文件只做 UI 与命令下发，因此在 Activity 关闭后服务器仍能继续工作。
local Screen = require "app.screen"
local theme = require "ui.theme"
local configModule = require "core.config"
local Controller = require "core.controller"
local Store = require "core.store"
local shellLayout = require "res.layout.main"

local W = theme.W
local M = {}

local TAB_TITLES = { "首页", "设置", "日志", "文件", "关于" }

-- 刷新节奏：服务运行时快一些（统计要跟手），停止时慢一些（省电）
local REFRESH_RUNNING_MS = 800
local REFRESH_IDLE_MS = 2000

--- 创建应用对象并启动界面
function M.start()
  local config = configModule.load(activity)

  local app = {
    config = config,
    clock = nil,
    pages = {},
    paused = false,
    lastRefreshAt = 0,
  }

  app.controller = Controller.new(app)
  -- 兼容旧页面对 app.logger 的引用：日志现在由服务提供
  app.logger = {
    stats = function()
      local s = app.controller.state
      return {
        total = s.total or 0,
        success = s.success or 0,
        failure = s.failure or 0,
        active = s.active or 0,
        avgMs = s.avgMs or 0,
        bytesOut = s.bytesOut or 0,
      }
    end,
    logs = function() return app.controller.state.logs or {} end,
  }

  --- 保存设置并同步到 Service（运行中会按需重启）
  function app.applyConfig(newConfig)
    app.config = newConfig
    local saved, saveErr = configModule.save(newConfig, activity)
    if not saved then return false, "保存失败：" .. tostring(saveErr) end
    local running = app.controller:isRunning()
    local ok, detail = app.controller:restart()
    if not ok then return false, detail end
    return running and true or nil
  end

  local dashboard = require("ui.dashboard").new(app)
  local settingsPage = require("ui.settings").new(app)
  local logsPage = require("ui.logs").new(app)
  local filesPage = require("ui.files").new(app)
  local aboutPage = require("ui.about").new(app)
  app.pages = { dashboard, settingsPage, logsPage, filesPage, aboutPage }

  local views = Screen.show(shellLayout, "LuaServer")
  app.views = views
  local pages = app.pages
  local currentIndex = 1

  local function updateSubtitle()
    if not views.toolbar then return end
    local state = app.controller.state
    if app.controller:isRunning() then
      views.toolbar.setSubtitle("运行中 · " .. tostring(state.host or "") .. ":" .. tostring(state.port))
    elseif app.controller.pendingAction then
      views.toolbar.setSubtitle("正在" .. tostring(app.controller.pendingAction) .. "…")
    else
      views.toolbar.setSubtitle("已停止")
    end
  end

  app.onStateChange = function()
    app.controller:pull()
    updateSubtitle()
  end

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
      if not ok then print("切换页面失败：" .. tostring(err)) end
    end,
    onTabUnselected = function() end,
    onTabReselected = function() end,
  })

  -- 首次进入：拉一次状态（若 Service 仍在运行可直接显示真实状态）
  app.controller:pull()
  updateSubtitle()
  showTab(1)

  -- 刷新循环：timer 回调运行在 LuaTimer 线程，UI 更新必须经 call() 回到主线程。
  -- 内部按运行状态节流：运行时 800ms 一次，停止后降为 2s，避免无谓刷新。
  local clock
  clock = timer(function()
    pcall(function()
      call(function()
        if app.paused then return end
        local now = Store.millis()
        local interval = app.controller:isRunning() and REFRESH_RUNNING_MS or REFRESH_IDLE_MS
        if (now - app.lastRefreshAt) < interval then return end
        app.lastRefreshAt = now

        local ok, err = pcall(function()
          app.controller:pull()
          local page = pages[currentIndex]
          if page and page.refresh then page.refresh() end
          updateSubtitle()
        end)
        if not ok then
          pcall(function()
            file.save(activity.getLuaDir("luaserver_ui_error.txt"), tostring(err))
          end)
        end
      end)
    end)
  end, 300, 300)
  app.clock = clock

  --- 前台/后台切换：暂停期间的界面刷新（服务器不受影响）
  function app.setPaused(value)
    app.paused = value and true or false
  end

  --- Activity 销毁：只停止 UI 定时器，**不停止服务器**
  -- 服务器由 Service 承载，用户主动「停止服务器」或系统回收进程时才结束。
  function app.destroy()
    app.paused = true
    if app.clock then pcall(function() app.clock.stop() end) end
    app.clock = nil
  end

  return app
end

return M
