-- server/response.lua — HTTP 响应写出（状态行、Header、错误页、静态文件流）
local M = {}

local StringCls = luajava.bindClass "java.lang.String"
local Files = luajava.bindClass "java.nio.file.Files"
local Paths = luajava.bindClass "java.nio.file.Paths"
local utils = require "core.utils"
local MIME = require "server.mime"

M.SERVER_NAME = "LuaServer/1.0"

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
  return code
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

--- 以流的方式发送文件：Header 由本函数写，正文由 Files.copy 直接推给 Socket
-- 返回 状态码, 失败原因（nil 表示完全成功）。客户端提前断开是正常现象，
-- 由调用方判断是否记录，不应升级为 500。
function M.sendFile(out, file, headOnly)
  local mime = MIME.typeOf(file.getName())
  local length = file.length()
  local headers = {
    "Content-Type: " .. mime,
    "Cache-Control: no-cache",
  }
  M.sendHead(out, 200, headers, length)
  if not headOnly and length > 0 then
    local ok, err = pcall(function()
      Files.copy(Paths.get(file.getAbsolutePath()), out)
      out.flush()
    end)
    if not ok then return 200, tostring(err) end
  else
    out.flush()
  end
  return 200
end

return M
