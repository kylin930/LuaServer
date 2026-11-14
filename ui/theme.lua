-- ui/theme.lua — MD3 颜色与可复用的布局构件
--
-- 颜色一律在运行时从 activity.themeUtil 取主题色 int，避免依赖可能缺失的 ?attr 名称；
-- 取色失败时回退到一组蓝绿色系的安全色值。
local M = {}

local W = {
  Card = luajava.bindClass "com.google.android.material.card.MaterialCardView",
  Button = luajava.bindClass "com.google.android.material.button.MaterialButton",
  Text = luajava.bindClass "com.google.android.material.textview.MaterialTextView",
  Toolbar = luajava.bindClass "com.google.android.material.appbar.MaterialToolbar",
  InputLayout = luajava.bindClass "com.google.android.material.textfield.TextInputLayout",
  Input = luajava.bindClass "com.google.android.material.textfield.TextInputEditText",
  Divider = luajava.bindClass "com.google.android.material.divider.MaterialDivider",
  TabLayout = luajava.bindClass "com.google.android.material.tabs.TabLayout",
  RadioGroup = luajava.bindClass "android.widget.RadioGroup",
  Radio = luajava.bindClass "com.google.android.material.radiobutton.MaterialRadioButton",
  Switch = luajava.bindClass "com.google.android.material.materialswitch.MaterialSwitch",
  Linear = luajava.bindClass "android.widget.LinearLayout",
  Frame = luajava.bindClass "android.widget.FrameLayout",
  Scroll = luajava.bindClass "android.widget.ScrollView",
  Toast = luajava.bindClass "android.widget.Toast",
  Dialog = luajava.bindClass "com.google.android.material.dialog.MaterialAlertDialogBuilder",
  View = luajava.bindClass "android.view.View",
  File = luajava.bindClass "java.io.File",
}
M.W = W

M.SPACE = "16dp"

local cached = nil

local function pick(getter, fallback)
  local ok, value = pcall(getter)
  if ok and type(value) == "number" then return value end
  return fallback
end

--- 主题色板（浅色/深色由系统主题决定）
function M.colors(refresh)
  if cached and not refresh then return cached end
  local colors
  local ok = pcall(function()
    local util = activity.themeUtil
    local night = false
    pcall(function() night = activity.isNightMode() end)
    colors = {
      night = night,
      primary = pick(function() return util.primary.main end, 0xFF00696B),
      onPrimary = pick(function() return util.primary.on end, 0xFFFFFFFF),
      primaryContainer = pick(function() return util.primary.container end, 0xFF9CF1F0),
      onPrimaryContainer = pick(function() return util.primary.onContainer end, 0xFF002020),
      secondaryContainer = pick(function() return util.secondary.container end, 0xFFCCE8E7),
      onSecondaryContainer = pick(function() return util.secondary.onContainer end, 0xFF051F1F),
      surface = pick(function() return util.surface.main end, 0xFFF5FBFA),
      onSurface = pick(function() return util.surface.on end, 0xFF191C1C),
      onSurfaceVariant = pick(function() return util.surface.onVariant end, 0xFF3F4948),
      surfaceContainer = pick(function() return util.surface.container end, 0xFFE7F2F0),
      surfaceContainerLow = pick(function() return util.surface.containerLow end, 0xFFFFFFFF),
      outline = pick(function() return util.outline.main end, 0xFF6F7978),
      outlineVariant = pick(function() return util.outline.variant end, 0xFFBEC9C8),
      error = pick(function() return util.error.main end, 0xFFBA1A1A),
      errorContainer = pick(function() return util.error.container end, 0xFFF9DEDC),
    }
  end)
  if not colors then
    local night = false
    pcall(function() night = activity.isNightMode() end)
    colors = {
      night = night,
      primary = night and 0xFF80D4D5 or 0xFF00696B,
      onPrimary = night and 0xFF003738 or 0xFFFFFFFF,
      primaryContainer = night and 0xFF004F50 or 0xFF9CF1F0,
      onPrimaryContainer = night and 0xFF9CF1F0 or 0xFF002020,
      secondaryContainer = night and 0xFF324B4B or 0xFFCCE8E7,
      onSecondaryContainer = night and 0xFFCCE8E7 or 0xFF051F1F,
      surface = night and 0xFF101414 or 0xFFF5FBFA,
      onSurface = night and 0xFFE0E3E2 or 0xFF191C1C,
      onSurfaceVariant = night and 0xFFBFC9C8 or 0xFF3F4948,
      surfaceContainer = night and 0xFF232928 or 0xFFE7F2F0,
      surfaceContainerLow = night and 0xFF1A1F1F or 0xFFFFFFFF,
      outline = night and 0xFF89938F or 0xFF6F7978,
      outlineVariant = night and 0xFF3F4948 or 0xFFBEC9C8,
      error = night and 0xFFFFB4AB or 0xFFBA1A1A,
      errorContainer = night and 0xFF93000A or 0xFFF9DEDC,
    }
  end
  colors.success = colors.night and 0xFF7BD88F or 0xFF2E7D32
  colors.warning = colors.night and 0xFFFFCF7A or 0xFF8A5300
  cached = colors
  return colors
end

--- 读取 EditText / TextView 的文本，始终返回 Lua 字符串
-- getText() 在 Java 端是 CharSequence：普通 String 会被 LuaJ 直接转成 Lua 字符串，
-- Editable 则是 userdata，需要再调用 toString()。
function M.textOf(view)
  if view == nil then return "" end
  local ok, value = pcall(function() return view.getText() end)
  if not ok or value == nil then return "" end
  if type(value) == "string" then return value end
  local okText, text = pcall(function() return value.toString() end)
  if okText and type(text) == "string" then return text end
  return tostring(value)
end

function M.toast(message)
  pcall(function()
    W.Toast.makeText(activity, tostring(message), W.Toast.LENGTH_SHORT).show()
  end)
end

--- 卡片：children 为子视图数组
function M.card(children, opts)
  opts = opts or {}
  local c = M.colors()
  local node = {
    W.Card,
    layout_width = "match",
    layout_height = "wrap",
    layout_marginStart = "16dp",
    layout_marginEnd = "16dp",
    layout_marginTop = opts.marginTop or "12dp",
    radius = opts.radius or "18dp",
    cardElevation = 0,
    strokeWidth = opts.noStroke and "0dp" or "1dp",
    strokeColor = c.outlineVariant,
    CardBackgroundColor = opts.color or c.surfaceContainerLow,
  }
  if opts.id then node.id = opts.id end
  for i = 1, #children do node[#node + 1] = children[i] end
  return node
end

--- 卡片内容容器（统一内边距）
function M.cardBody(children, opts)
  opts = opts or {}
  local node = {
    W.Linear,
    orientation = "vertical",
    layout_width = "match",
    layout_height = "wrap",
    paddingStart = opts.padding or "16dp",
    paddingEnd = opts.padding or "16dp",
    paddingTop = opts.paddingTop or "16dp",
    paddingBottom = opts.paddingBottom or "16dp",
  }
  for i = 1, #children do node[#node + 1] = children[i] end
  return node
end

function M.heading(id, text, opts)
  opts = opts or {}
  local c = M.colors()
  local node = {
    W.Text,
    text = text,
    textSize = opts.size or "15sp",
    textStyle = "bold",
    textColor = c.onSurface,
    layout_width = "match",
    layout_height = "wrap",
    layout_marginTop = opts.marginTop or "0dp",
    layout_marginBottom = opts.marginBottom or "0dp",
  }
  if id and id ~= "" then node.id = id end
  return node
end

function M.caption(id, text, opts)
  opts = opts or {}
  local c = M.colors()
  local node = {
    W.Text,
    text = text,
    textSize = opts.size or "12.5sp",
    textColor = opts.color or c.onSurfaceVariant,
    layout_width = opts.width or "match",
    layout_height = "wrap",
    layout_marginTop = opts.marginTop or "0dp",
  }
  if id and id ~= "" then node.id = id end
  return node
end

function M.value(id, text, opts)
  opts = opts or {}
  local c = M.colors()
  local node = {
    W.Text,
    text = text,
    textSize = opts.size or "14sp",
    textColor = opts.color or c.onSurface,
    layout_width = opts.width or "match",
    layout_height = "wrap",
    layout_gravity = opts.gravity,
    gravity = opts.textGravity,
  }
  if id and id ~= "" then node.id = id end
  return node
end

--- 一行“标签 + 值”
function M.kv(labelText, valueId, valueText, opts)
  opts = opts or {}
  local c = M.colors()
  return {
    W.Linear,
    orientation = "horizontal",
    layout_width = "match",
    layout_height = "wrap",
    layout_marginTop = opts.marginTop or "10dp",
    {
      W.Text,
      text = labelText,
      textSize = "13sp",
      textColor = c.onSurfaceVariant,
      layout_width = "wrap",
      layout_height = "wrap",
    },
    {
      W.Text,
      id = valueId,
      text = valueText,
      textSize = opts.size or "14sp",
      textColor = opts.color or c.onSurface,
      layout_width = "0dp",
      layout_height = "wrap",
      layout_weight = 1,
      layout_gravity = "center_vertical",
      gravity = "end",
      maxLines = 3,
    },
  }
end

--- 数值格：大号数值 + 说明文字
function M.statCell(valueId, labelText)
  local c = M.colors()
  return {
    W.Linear,
    orientation = "vertical",
    layout_width = "0dp",
    layout_height = "wrap",
    layout_weight = 1,
    {
      W.Text,
      id = valueId,
      text = "0",
      textSize = "18sp",
      textStyle = "bold",
      textColor = c.onSurface,
      layout_width = "match",
      layout_height = "wrap",
    },
    {
      W.Text,
      text = labelText,
      textSize = "11.5sp",
      textColor = c.onSurfaceVariant,
      layout_width = "match",
      layout_height = "wrap",
      layout_marginTop = "2dp",
    },
  }
end

--- 数值格行（3 列）
function M.statRow(cells, opts)
  opts = opts or {}
  local node = {
    W.Linear,
    orientation = "horizontal",
    layout_width = "match",
    layout_height = "wrap",
    layout_marginTop = opts.marginTop or "14dp",
  }
  for i = 1, #cells do node[#node + 1] = cells[i] end
  return node
end

function M.button(id, text, opts)
  opts = opts or {}
  local node = {
    W.Button,
    id = id,
    text = text,
    textSize = opts.size or "15sp",
    layout_width = opts.width or "match",
    layout_height = opts.height or "48dp",
    layout_marginTop = opts.marginTop or "12dp",
    layout_marginStart = opts.marginStart,
    layout_marginEnd = opts.marginEnd,
    layout_weight = opts.weight,
  }
  if opts.outlined then node.styleAttr = "?attr/materialButtonOutlinedStyle" end
  if opts.flat then node.styleAttr = "?attr/borderlessButtonStyle" end
  return node
end

--- 输入框（TextInputLayout + TextInputEditText）
function M.input(id, hint, opts)
  opts = opts or {}
  return {
    W.InputLayout,
    id = id .. "Layout",
    layout_width = "match",
    layout_height = "wrap",
    layout_marginTop = opts.marginTop or "12dp",
    hint = hint,
    {
      W.Input,
      id = id,
      layout_width = "match",
      layout_height = "wrap",
      inputType = opts.inputType or "number",
      singleLine = true,
    },
  }
end

--- 细分隔线（用普通 View 实现，避免依赖特定 Material 组件属性）
function M.divider(marginTop)
  local c = M.colors()
  return {
    W.Linear,
    layout_width = "match",
    layout_height = "1dp",
    layout_marginTop = marginTop or "14dp",
    BackgroundColor = c.outlineVariant,
  }
end

--- 页面骨架：垂直滚动容器 + 内层纵向 LinearLayout
function M.page(children, opts)
  opts = opts or {}
  local c = M.colors()
  local inner = {
    W.Linear,
    orientation = "vertical",
    layout_width = "match",
    layout_height = "wrap",
    paddingBottom = opts.paddingBottom or "28dp",
  }
  for i = 1, #children do inner[#inner + 1] = children[i] end
  return {
    W.Scroll,
    layout_width = "match",
    layout_height = "match",
    fillViewport = true,
    BackgroundColor = c.surface,
    inner,
  }
end

return M
