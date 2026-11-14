-- server/response.lua — HTTP 响应写出（状态行、Header、缓存协商、错误页、文件流）
local M = {}

local StringCls = luajava.bindClass "java.lang.String"
local Files = luajava.bindClass "java.nio.file.Files"
local Paths = luajava.bindClass "java.nio.file.Paths"
local utils = require "core.utils"
local MIME = require "server.mime"

M.SERVER_NAME = "LuaServer/0.2"

local REASONS = {
  [200] = "OK",
  [204] = "No Content",
  [206] = "Partial Content",
  [301] = "Moved Permanently",
  [302] = "Found",
  [304] = "Not Modified",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [408] = "Request Timeout",
  [413] = "Payload Too Large",
  [414] = "URI Too Long",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
  [501] = "Not Implemented",
  [503] = "Service Unavailable",
  [505] = "HTTP Version Not Supported",
}

function M.reason(code)
  return REASONS[code] or "Unknown"
end

local function bytesOf(text)
  return StringCls(text).getBytes("UTF-8")
end

--- 写出状态行 + Header（含 Content-Length 与 Connection: close）
function M.sendHead(out, code, headers, contentLength)
  local lines = { "HTTP/1.1 " .. code .. " " .. M.reason(code) }
  lines[#lines + 1] = "Date: " .. utils.httpDate()
  lines[#lines + 1] = "Server: " .. M.SERVER_NAME
  local extra = headers or {}
  for i = 1, #extra do lines[#lines + 1] = extra[i] end
  if contentLength ~= nil then lines[#lines + 1] = "Content-Length: " .. contentLength end
  lines[#lines + 1] = "Connection: close"
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  out.write(bytesOf(table.concat(lines, "\r\n")))
end

--- 通用文本响应；headOnly 时只发头（Content-Length 仍为真实长度）
function M.sendText(out, code, headers, text, headOnly)
  local body = text or ""
  local bytes = bytesOf(body)
  M.sendHead(out, code, headers, #bytes)
  if not headOnly and #bytes > 0 then out.write(bytes) end
  out.flush()
  return code, nil, #bytes
end

local ERROR_STYLE = table.concat({
  "html,body{margin:0;height:100%}",
  "body{display:flex;align-items:center;justify-content:center;",
  "background:#f5fbfa;color:#191c1c;",
  "font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif}",
  "main{max-width:420px;padding:32px}",
  "h1{font-size:44px;margin:0 0 4px;font-weight:600;color:#00696b}",
  "p{margin:6px 0;line-height:1.6;color:#3f4948;font-size:15px}",
  ".muted{color:#6f7978;font-size:13px;margin-top:18px}",
  "code{background:#e3f1ef;padding:2px 6px;border-radius:6px;font-size:13px}",
  "@media (prefers-color-scheme:dark){",
  "body{background:#101414;color:#e0e3e2}h1{color:#80d4d5}",
  "p{color:#bfc9c8}.muted{color:#89938f}code{background:#232928}}",
}, "")

--- 统一错误页（HTML），额外响应头可透传（例如 Allow）
function M.errorPage(out, code, message, headOnly, extraHeaders)
  local title = code .. " " .. M.reason(code)
  local headers = { "Content-Type: text/html; charset=utf-8", "Cache-Control: no-store" }
  local extra = extraHeaders or {}
  for i = 1, #extra do headers[#headers + 1] = extra[i] end
  local body = table.concat({
    "<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
    "<title>", title, "</title><style>", ERROR_STYLE, "</style></head><body><main>",
    "<h1>", tostring(code), "</h1>",
    "<p><strong>", title, "</strong></p>",
    "<p>", utils.escapeHtml(message or M.reason(code)), "</p>",
    "<p class=\"muted\">", M.SERVER_NAME, " · 本地静态文件服务器</p>",
    "</main></body></html>",
  })
  return M.sendText(out, code, headers, body, headOnly)
end

--- 生成静态文件 ETag：大小 + 修改时间 + 名称，弱校验
function M.etagOf(file, length, lastModified)
  local name = file.getName()
  return string.format("\"%x-%x-%x\"", length or 0, lastModified or 0, #name)
end

--- If-None-Match 是否命中（支持 * 与逗号分隔列表）
local function etagMatches(headerValue, etag)
  if not headerValue or headerValue == "" then return false end
  if string.find(headerValue, "*", 1, true) then return true end
  for candidate in string.gmatch(headerValue, "[^,]+") do
    candidate = utils.trim(candidate)
    if candidate == etag then return true end
    -- 忽略 W/ 前缀的弱比较
    if string.sub(candidate, 1, 2) == "W/" and string.sub(candidate, 3) == etag then return true end
  end
  return false
end

--- 根据缓存策略生成 Cache-Control 头
local function cacheControlFor(mode)
  if mode == "off" or mode == nil then return "no-store" end
  if mode == "short" then return "public, max-age=300" end
  if mode == "long" then return "public, max-age=86400" end
  return "no-cache"  -- validate：允许缓存但每次需重新校验
end

M.cacheControlFor = cacheControlFor

--- 以流的方式发送文件：
--   * 支持 ETag / Last-Modified 协商，命中返回 304；
--   * 大文件分块读取写入，不会整体载入内存；
--   * 返回 状态码, 失败原因, 实际写出字节数
function M.sendFile(out, file, headOnly, options)
  options = options or {}
  local length = file.length()
  local lastModifiedMs = 0
  pcall(function() lastModifiedMs = file.lastModified() end)
  local etag = M.etagOf(file, length, lastModifiedMs)
  local lastModified = utils.httpDate(lastModifiedMs)
  local mime = MIME.typeOf(file.getName())

  local headers = {
    "Content-Type: " .. mime,
    "Cache-Control: " .. cacheControlFor(options.cacheMode),
    "ETag: " .. etag,
    "Last-Modified: " .. lastModified,
    "Accept-Ranges: none",
  }

  -- 协商缓存：命中 If-None-Match / If-Modified-Since 直接 304
  if options.cacheMode ~= "off" then
    local reqHeaders = options.requestHeaders or {}
    local hit = etagMatches(reqHeaders["if-none-match"], etag)
    if not hit and lastModifiedMs > 0 then
      local since = utils.parseHttpDate(reqHeaders["if-modified-since"])
      if since and math.floor(lastModifiedMs / 1000) <= since then hit = true end
    end
    if hit then
      M.sendHead(out, 304, headers, nil)
      out.flush()
      return 304, nil, 0
    end
  end

  M.sendHead(out, 200, headers, length)
  if headOnly or length <= 0 then
    out.flush()
    return 200, nil, 0
  end

  -- 分块流式发送：Files.copy 内部使用固定大小缓冲区边读边写（不会把大文件整体载入内存），
  -- 且直接写入 SocketOutputStream，是当前运行时下最省内存的方式
  -- （Lua 侧无法自行创建 byte[]，逐字节 copy 会慢上百倍）。
  local written = 0
  local copyOk, copyErr = pcall(function()
    local copied = Files.copy(Paths.get(file.getAbsolutePath()), out)
    written = tonumber(copied) or 0
    out.flush()
  end)
  if not copyOk then return 200, tostring(copyErr), written end
  return 200, nil, written
end

return M
