-- server/static_file.lua — 静态文件解析与发送（含路径穿越防护、目录索引、默认站点生成）
local M = {}

local File = luajava.bindClass "java.io.File"
local response = require "server.response"
local utils = require "core.utils"

local fileMod = file
local DEFAULT_SITE = require "www.seed"

--- 确保根目录存在，并在首次使用时写入默认站点
function M.ensureRoot(rootPath)
  local root = File(rootPath)
  if not root.exists() then
    local ok = pcall(function() return root.mkdirs() end)
    if not ok or not root.exists() then return nil, "无法创建网站根目录：" .. tostring(rootPath) end
  end
  if not root.isDirectory() then return nil, "网站根目录不是目录：" .. tostring(rootPath) end
  local canonical
  local ok = pcall(function() canonical = root.getCanonicalPath() end)
  if not ok or not canonical then return nil, "无法解析网站根目录：" .. tostring(rootPath) end
  M.seedDefaultSite(root)
  return root, canonical
end

--- 默认站点只在 index.html 不存在时写入，避免覆盖用户内容
function M.seedDefaultSite(root)
  local index = File(root, "index.html")
  local exists = false
  pcall(function() exists = index.exists() end)
  if exists then return false end
  for name, content in pairs(DEFAULT_SITE.files) do
    local target = File(root, name)
    local created = false
    pcall(function() created = target.exists() end)
    if not created then
      pcall(function() fileMod.save(target.getAbsolutePath(), content) end)
    end
  end
  return true
end

local function hasIllegalSegment(segment)
  if string.find(segment, "\\", 1, true) then return true end
  if string.find(segment, "%c") then return true end
  if string.find(segment, "\0", 1, true) then return true end
  return false
end

--- 把已解码的请求路径解析为根目录内的 File 对象
-- 返回 file, 相对路径；非法/穿越返回 nil, 原因
function M.resolve(rootFile, rootCanonical, decodedPath)
  local segments = {}
  for segment in string.gmatch(decodedPath, "[^/]+") do
    if segment == "." then
      -- 忽略当前目录
    elseif segment == ".." then
      return nil, "path-traversal"
    else
      if hasIllegalSegment(segment) then return nil, "illegal-segment" end
      segments[#segments + 1] = segment
    end
  end
  local relative = table.concat(segments, "/")
  local target = File(rootFile, relative)
  local canonical
  local ok = pcall(function() canonical = target.getCanonicalPath() end)
  if not ok or not canonical then return nil, "illegal-segment" end

  local prefix = rootCanonical
  if string.sub(prefix, -1) ~= "/" then prefix = prefix .. "/" end
  if canonical ~= rootCanonical and string.sub(canonical, 1, #prefix) ~= prefix then
    return nil, "outside-root"
  end
  return target, relative
end

local function htmlPage(title, inner)
  return table.concat({
    "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<title>", title, "</title><style>",
    "body{font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;",
    "margin:0;background:#f5fbfa;color:#191c1c}",
    "main{max-width:680px;margin:0 auto;padding:28px 20px 40px}",
    "h1{font-size:20px;margin:0 0 4px;font-weight:600}",
    "p.dir{color:#3f4948;font-size:13px;margin:0 0 18px;word-break:break-all}",
    "ul{list-style:none;margin:0;padding:0}",
    "li a{display:flex;justify-content:space-between;gap:12px;padding:12px 14px;",
    "text-decoration:none;color:#191c1c;background:#fff;border-radius:12px;",
    "margin-bottom:8px;border:1px solid #dee6e5}",
    "li a:hover{border-color:#00696b}",
    "span.size{color:#6f7978;font-size:12px;flex:none}",
    "</style></head><body><main>", inner, "</main></body></html>",
  })
end

local function sortByName(list)
  table.sort(list, function(a, b)
    return string.lower(a.getName()) < string.lower(b.getName())
  end)
end

--- 把相对目录编码成以 / 结尾的 URL 路径（逐段编码，保留分隔符）
local function encodeDirPath(relative)
  if relative == nil or relative == "" then return "/" end
  local parts = {}
  for segment in string.gmatch(relative, "[^/]+") do
    parts[#parts + 1] = utils.urlEncode(segment)
  end
  return "/" .. table.concat(parts, "/") .. "/"
end

--- 目录索引页（没有默认首页时使用）
function M.sendListing(out, dir, relative, headOnly)
  local entries = dir.listFiles()
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

  local base = encodeDirPath(relative)
  local items = {}
  if relative ~= nil and relative ~= "" then
    local parent = string.match(relative, "^(.*)/[^/]+$") or ""
    items[#items + 1] = "<li><a href=\"" .. encodeDirPath(parent) ..
      "\"><span>← 上级目录</span></a></li>"
  end
  for i = 1, #dirs do
    local name = dirs[i].getName()
    items[#items + 1] = "<li><a href=\"" .. base .. utils.urlEncode(name) .. "/\"><span>" ..
      utils.escapeHtml(name) .. "/</span></a></li>"
  end
  for i = 1, #files do
    local name = files[i].getName()
    local size = 0
    pcall(function() size = files[i].length() end)
    items[#items + 1] = "<li><a href=\"" .. base .. utils.urlEncode(name) .. "\"><span>" ..
      utils.escapeHtml(name) .. "</span><span class=\"size\">" .. utils.formatBytes(size) ..
      "</span></a></li>"
  end
  if #items == 0 then
    items[1] = "<li><a><span>空目录</span></a></li>"
  end

  local body = htmlPage("目录索引 · LuaServer", table.concat({
    "<h1>目录索引</h1>",
    "<p class=\"dir\">", utils.escapeHtml(base), "</p>",
    "<ul>", table.concat(items), "</ul>",
  }))
  return response.sendText(out, 200,
    { "Content-Type: text/html; charset=utf-8", "Cache-Control: no-store" }, body, headOnly)
end

--- 处理一次静态资源请求；返回 状态码, 写出失败原因（可选）
function M.serve(out, ctx, req, headOnly)
  local target, info = M.resolve(ctx.rootFile, ctx.rootCanonical, req.path)
  if not target then
    local message = "请求路径不合法"
    if info == "path-traversal" or info == "outside-root" then
      message = "请求路径越出了网站根目录，已拒绝访问"
    end
    response.errorPage(out, 403, message, headOnly)
    return 403
  end

  local isDirectory = false
  pcall(function() isDirectory = target.isDirectory() end)
  if isDirectory then
    local index = File(target, ctx.indexFile)
    local hasIndex = false
    pcall(function() hasIndex = index.isFile() end)
    if hasIndex then return response.sendFile(out, index, headOnly) end
    return M.sendListing(out, target, info, headOnly)
  end

  local isFile = false
  pcall(function() isFile = target.isFile() end)
  if not isFile then
    response.errorPage(out, 404, "文件不存在：" .. req.path, headOnly)
    return 404
  end
  return response.sendFile(out, target, headOnly)
end

return M
