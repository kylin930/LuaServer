-- res/layout/main.lua — 应用外壳布局：顶部工具栏 + 标签页 + 页面容器
--
-- 具体页面由 ui/dashboard、ui/settings、ui/logs、ui/files、ui/about 动态创建，
-- 并通过 ui/shell.lua 加到 container 中。
local bindClass = luajava.bindClass
local LinearLayout = bindClass "android.widget.LinearLayout"
local FrameLayout = bindClass "android.widget.FrameLayout"
local TabLayout = bindClass "com.google.android.material.tabs.TabLayout"
local Screen = require "app.screen"

-- ActionBar 主题会自带工具栏；NoActionBar 主题下由 Screen.wrap 补一个 MaterialToolbar
local showToolbar = true

return Screen.wrap({
  LinearLayout,
  orientation = "vertical",
  layout_width = "match",
  layout_height = "match",
  {
    TabLayout,
    id = "tabs",
    layout_width = "match",
    layout_height = "wrap",
    TabMode = 1,     -- 可滚动，标签多时不挤压
    TabGravity = 0,  -- 填满宽度
  },
  {
    FrameLayout,
    id = "container",
    layout_width = "match",
    layout_height = "0dp",
    layout_weight = 1,
  },
}, showToolbar)
