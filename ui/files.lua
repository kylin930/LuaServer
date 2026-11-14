-- ui/files.lua — 网站目录管理：浏览、新建文件夹、新建 HTML、删除
local theme = require "ui.theme"
local utils = require "core.utils"

local W = theme.W
local File = luajava.bindClass "java.io.File"
local fileMod = file

local M = {}

local function sortByName(list)
  table.sort(list, function(a, b)
    return string.lower(a.getName()) < string.lower(b.getName())
  end)
end

local function listDir(rootPath, relative)
  local dir = File(rootPath, relative)
  local entries = nil
  pcall(function() entries = dir.listFiles() end)
  local dirs, files = {}, {}
  if entries then
    local count = #entries
    for i = 0, count - 1 do
      local entry = entries[i]
      local isDir = false
      pcall(function() isDir = entry.isDirectory() end)
      if isDir then
        dirs[#dirs + 1] = entry
      else
        files[#files + 1] = entry
      end
    end
  end
  sortByName(dirs)
  sortByName(files)
  return dirs, files
end

function M.new(app)
  local page = { app = app, views = {}, root = nil, rel = "" }

  local function absoluteDir()
    return File(app.config.rootPath, page.rel)
  end

  local function prompt(title, hint, positiveText, onConfirm, extraInput)
    local holder = {}
    local children = {
      W.Linear,
      orientation = "vertical",
      layout_width = "match",
      layout_height = "wrap",
      paddingStart = "20dp",
      paddingEnd = "20dp",
      paddingTop = "8dp",
      {
        W.InputLayout,
        id = "dlgNameLayout",
        layout_width = "match",
        layout_height = "wrap",
        hint = hint,
        {
          W.Input,
          id = "dlgName",
          layout_width = "match",
          layout_height = "wrap",
          singleLine = true,
          inputType = "text",
        },
      },
    }
    if extraInput then
      children[#children + 1] = {
        W.InputLayout,
        id = "dlgBodyLayout",
        layout_width = "match",
        layout_height = "wrap",
        layout_marginTop = "12dp",
        hint = "HTML 内容",
        {
          W.Input,
          id = "dlgBody",
          layout_width = "match",
          layout_height = "wrap",
          minLines = 4,
          maxLines = 10,
          inputType = "textMultiLine",
        },
      }
    end
    local dialogView = loadlayout(children, holder)
    W.Dialog(activity)
      .setTitle(title)
      .setView(dialogView)
      .setPositiveButton(positiveText, function()
        local name = utils.trim(theme.textOf(holder.dlgName))
        local body = extraInput and theme.textOf(holder.dlgBody) or nil
        onConfirm(name, body)
      end)
      .setNegativeButton("取消", nil)
      .show()
  end

  local function validateName(name)
    if name == nil or name == "" then return false, "名称不能为空" end
    if string.find(name, "/", 1, true) or string.find(name, "\\", 1, true) then
      return false, "名称不能包含路径分隔符"
    end
    if name == "." or name == ".." then return false, "名称不合法" end
    return true
  end

  local function createFolder()
    prompt("新建文件夹", "文件夹名称", "创建", function(name)
      local ok, err = validateName(name)
      if not ok then theme.toast(err) return end
      local target = File(absoluteDir(), name)
      local created = false
      local callOk, callErr = pcall(function() created = target.mkdirs() end)
      if not callOk or not created then
        theme.toast("创建失败：" .. tostring(callErr or "目录已存在或无权限"))
        return
      end
      theme.toast("已创建文件夹 " .. name)
      page.reload()
    end)
  end

  local function createHtml()
    prompt("新建 HTML 文件", "文件名，例如 about.html", "创建", function(name, body)
      local ok, err = validateName(name)
      if not ok then theme.toast(err) return end
      local fileName = name
      if not string.find(string.lower(fileName), "%.html?$") then
        fileName = fileName .. ".html"
      end
      local target = File(absoluteDir(), fileName)
      local exists = false
      pcall(function() exists = target.exists() end)
      if exists then
        theme.toast("同名文件已存在：" .. fileName)
        return
      end
      local content = body
      if content == nil or utils.trim(content) == "" then
        content = "<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n<meta charset=\"utf-8\">\n"
          .. "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
          .. "<title>" .. fileName .. "</title>\n</head>\n<body>\n"
          .. "<h1>" .. fileName .. "</h1>\n<p>由 LuaServer 创建。</p>\n</body>\n</html>\n"
      end
      local saved, saveErr = fileMod.save(target.getAbsolutePath(), content)
      if not saved then
        theme.toast("写入失败：" .. tostring(saveErr))
        return
      end
      theme.toast("已创建 " .. fileName)
      page.reload()
    end, true)
  end

  local function deleteFile(entry)
    local name = entry.getName()
    W.Dialog(activity)
      .setTitle("删除确认")
      .setMessage("确定删除「" .. name .. "」吗？此操作不可撤销。")
      .setPositiveButton("删除", function()
        local deleted = false
        local callOk, callErr = pcall(function() deleted = entry.delete() end)
        if callOk and deleted then
          theme.toast("已删除 " .. name)
        else
          theme.toast("删除失败：" .. tostring(callErr or "目录可能非空"))
        end
        page.reload()
      end)
      .setNegativeButton("取消", nil)
      .show()
  end

  local function showInfo(entry)
    local name = entry.getName()
    local size, modified = 0, 0
    pcall(function()
      size = entry.length()
      modified = entry.lastModified()
    end)
    local timeText = "未知"
    pcall(function()
      local Date = luajava.bindClass "java.util.Date"
      local SimpleDateFormat = luajava.bindClass "java.text.SimpleDateFormat"
      local format = SimpleDateFormat("yyyy-MM-dd HH:mm:ss")
      timeText = format.format(Date(modified))
    end)
    local relative = page.rel == "" and name or (page.rel .. "/" .. name)
    W.Dialog(activity)
      .setTitle(name)
      .setMessage("大小：" .. utils.formatBytes(size) .. "\n修改时间：" .. timeText
        .. "\n访问路径：/" .. relative)
      .setPositiveButton("删除", function() deleteFile(entry) end)
      .setNegativeButton("关闭", nil)
      .show()
  end

  local function entryRow(entry, isDir)
    local c = theme.colors()
    local name = entry.getName()
    local sizeText = "文件夹"
    if not isDir then
      local size = 0
      pcall(function() size = entry.length() end)
      sizeText = utils.formatBytes(size)
    end
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
      clickable = true,
      {
        W.Linear,
        orientation = "horizontal",
        layout_width = "match",
        layout_height = "wrap",
        paddingStart = "14dp",
        paddingEnd = "14dp",
        paddingTop = "12dp",
        paddingBottom = "12dp",
        {
          W.Text,
          text = (isDir and "📁  " or "📄  ") .. name,
          textSize = "13.5sp",
          textColor = c.onSurface,
          layout_width = "0dp",
          layout_height = "wrap",
          layout_weight = 1,
          maxLines = 1,
          ellipsize = "END",
        },
        {
          W.Text,
          text = sizeText,
          textSize = "11.5sp",
          textColor = c.onSurfaceVariant,
          layout_width = "wrap",
          layout_height = "wrap",
          layout_marginStart = "8dp",
          layout_gravity = "center_vertical",
        },
      },
    }
  end

  local function defaultIndexText()
    local indexName = app.config.indexFile
    local indexFile = File(absoluteDir(), indexName)
    local exists = false
    pcall(function() exists = indexFile.isFile() end)
    return (exists and "存在" or "缺失") .. " · " .. indexName
  end

  local function render()
    local views = page.views
    local c = theme.colors()
    views.fileList.removeAllViews()
    views.filePath.setText("/" .. (page.rel == "" and "" or (page.rel .. "/")))

    local root = app.config.rootPath
    local rootFile = File(root)
    local rootExists = false
    pcall(function() rootExists = rootFile.isDirectory() end)
    if not rootExists then
      views.fileEmpty.setText("根目录不存在或不可访问：" .. root)
      views.fileEmpty.setVisibility(W.View.VISIBLE)
      views.fileIndex.setText(defaultIndexText())
      return
    end

    if page.rel ~= "" then
      local holder = {}
      local upRow = loadlayout({
        W.Card,
        layout_width = "match",
        layout_height = "wrap",
        layout_marginTop = "8dp",
        radius = "14dp",
        cardElevation = 0,
        strokeWidth = "1dp",
        strokeColor = c.outlineVariant,
        CardBackgroundColor = c.surfaceContainerLow,
        clickable = true,
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          paddingStart = "14dp",
          paddingEnd = "14dp",
          paddingTop = "12dp",
          paddingBottom = "12dp",
          {
            W.Text,
            text = "←  上级目录",
            textSize = "13.5sp",
            textColor = c.primary,
            layout_width = "match",
            layout_height = "wrap",
          },
        },
      }, holder)
      upRow.setOnClickListener(function() page.up() end)
      views.fileList.addView(upRow)
    end

    local dirs, files = listDir(root, page.rel)
    local total = 0
    for i = 1, #dirs do
      total = total + 1
      local holder = {}
      local row = loadlayout(entryRow(dirs[i], true), holder)
      local entry = dirs[i]
      row.setOnClickListener(function() page.enter(entry.getName()) end)
      row.setOnLongClickListener(function()
        deleteFile(entry)
        return true
      end)
      views.fileList.addView(row)
    end
    for i = 1, #files do
      total = total + 1
      local holder = {}
      local row = loadlayout(entryRow(files[i], false), holder)
      local entry = files[i]
      row.setOnClickListener(function() showInfo(entry) end)
      row.setOnLongClickListener(function()
        deleteFile(entry)
        return true
      end)
      views.fileList.addView(row)
    end

    views.fileEmpty.setVisibility(total == 0 and W.View.VISIBLE or W.View.GONE)
    views.fileEmpty.setText("这个目录还是空的，可以用上方按钮添加文件。")
    views.fileIndex.setText(defaultIndexText())
    views.fileCount.setText(total .. " 项")
  end

  local function build()
    local c = theme.colors()
    local views = page.views
    local layout = theme.page({
      theme.card({ theme.cardBody({
        theme.heading(nil, "网站根目录"),
        theme.caption("fileRootPath", "—", { marginTop = "6dp" }),
        theme.kv("默认首页", "fileIndex", "—", { marginTop = "12dp" }),
        theme.kv("当前目录", "filePath", "/", { marginTop = "8dp" }),
        theme.kv("条目", "fileCount", "0 项", { marginTop = "8dp" }),
        {
          W.Linear,
          orientation = "horizontal",
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "14dp",
          theme.button("fileNewFolder", "新建文件夹",
            { outlined = true, width = "0dp", weight = 1, height = "44dp", size = "13sp", marginStart = "0dp", marginEnd = "4dp" }),
          theme.button("fileNewHtml", "新建 HTML",
            { outlined = true, width = "0dp", weight = 1, height = "44dp", size = "13sp", marginStart = "4dp", marginEnd = "4dp" }),
          theme.button("fileReload", "刷新",
            { outlined = true, width = "0dp", weight = 1, height = "44dp", size = "13sp", marginStart = "4dp", marginEnd = "0dp" }),
        },
      }, { marginTop = "8dp" }) }),

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
          id = "fileEmpty",
          text = "这个目录还是空的，可以用上方按钮添加文件。",
          textSize = "13sp",
          textColor = c.onSurfaceVariant,
          layout_width = "match",
          layout_height = "wrap",
          layout_marginTop = "12dp",
        },
        {
          W.Linear,
          id = "fileList",
          orientation = "vertical",
          layout_width = "match",
          layout_height = "wrap",
        },
        theme.caption(nil, "点击文件夹进入，点击文件查看信息，长按可删除。", { marginTop = "14dp" }),
      },
    }, { paddingBottom = "10dp" })

    page.root = loadlayout(layout, views)
    views.fileRootPath.setText(app.config.rootPath)
    views.fileNewFolder.setOnClickListener(function() createFolder() end)
    views.fileNewHtml.setOnClickListener(function() createHtml() end)
    views.fileReload.setOnClickListener(function() page.reload() end)
    return page.root
  end

  function page.enter(name)
    page.rel = page.rel == "" and name or (page.rel .. "/" .. name)
    page.reload()
  end

  function page.up()
    if page.rel == "" then return end
    page.rel = string.match(page.rel, "^(.*)/[^/]+$") or ""
    page.reload()
  end

  function page.reload()
    if not page.root then build() end
    page.views.fileRootPath.setText(app.config.rootPath)
    render()
  end

  function page.onShow()
    if not page.root then build() end
    page.reload()
  end

  function page.refresh()
    -- 目录内容不随定时器刷新，避免打断用户操作
  end

  function page.view()
    if not page.root then build() end
    return page.root
  end

  return page
end

return M
