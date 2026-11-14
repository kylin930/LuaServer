-- server/router.lua — 请求分发：静态资源 + 仅本机可访问的状态/回显 API
local M = {}

local response = require "server.response"
local static = require "server.static_file"
local utils = require "core.utils"

local jsonEncode = json.encode

local ALLOW_STATIC = "Allow: GET, HEAD, OPTIONS"
local ALLOW_API = "Allow: GET, HEAD, POST, OPTIONS"

local function isLoopback(ip)
  if not ip then return false end
  if ip == "127.0.0.1" or ip == "::1" or ip == "0:0:0:0:0:0:0:1" then return true end
  return string.find(ip, "^127%.") ~= nil
end

--- 本机状态接口：仅 loopback 客户端可读，避免局域网设备探测服务信息
local function apiStatus(out, ctx, headOnly)
  if not isLoopback(ctx.clientIp) then
    local code, err = response.errorPage(out, 403, "状态接口仅允许本机访问", headOnly)
    return code, err, 0
  end
  local snapshot = ctx.statusProvider()
  local ok, body = pcall(jsonEncode, snapshot)
  if not ok then body = "{\"error\":\"encode failed\"}" end
  return response.sendText(out, 200,
    { "Content-Type: application/json; charset=utf-8", "Cache-Control: no-store" }, body, headOnly)
end

--- 回显接口（仅本机）：用于验证 POST 请求体读取是否正常
local function apiEcho(out, ctx, req, headOnly)
  if not isLoopback(ctx.clientIp) then
    local code, err = response.errorPage(out, 403, "回显接口仅允许本机访问", headOnly)
    return code, err, 0
  end
  local result = {
    method = req.method,
    path = req.path,
    query = req.query or "",
    contentLength = req.contentLength,
    contentType = req.headers["content-type"] or "",
    params = req.params,
    bodyLength = req.body and #req.body or 0,
    body = req.body or "",
  }
  local ok, body = pcall(jsonEncode, result)
  if not ok then body = "{\"error\":\"encode failed\"}" end
  return response.sendText(out, 200,
    { "Content-Type: application/json; charset=utf-8", "Cache-Control: no-store" }, body, headOnly)
end

--- 统一处理 OPTIONS：返回该路径允许的方法
local function handleOptions(out, req, headOnly, allow)
  local headers = {
    "Allow: " .. allow,
    "Content-Type: text/plain; charset=utf-8",
    "Cache-Control: no-store",
  }
  return response.sendText(out, 204, headers, "", headOnly)
end

--- 返回 状态码, 写出失败原因, 字节数
function M.handle(req, out, ctx)
  local method = req.method
  local headOnly = method == "HEAD"
  local isApi = req.path == "/_api/status" or req.path == "/_api/echo"
    or string.sub(req.path, 1, 6) == "/_api/"
  local allow = isApi and ALLOW_API or ALLOW_STATIC

  -- OPTIONS：对任何路径都明确返回允许的方法
  if method == "OPTIONS" then
    return handleOptions(out, req, headOnly, allow)
  end

  if req.chunked then
    local code, err = response.errorPage(out, 501, "暂不支持 Transfer-Encoding: chunked 请求", headOnly)
    return code, err, 0
  end

  if method ~= "GET" and method ~= "HEAD" and method ~= "POST" then
    local code, err = response.errorPage(out, 405, "不支持的方法：" .. tostring(method), false,
      { "Allow: " .. allow })
    return code, err, 0
  end

  if req.path == "/_api/status" then
    if method == "POST" then
      local code, err = response.errorPage(out, 405, "状态接口不支持 POST", false, { "Allow: " .. allow })
      return code, err, 0
    end
    return apiStatus(out, ctx, headOnly)
  end

  if req.path == "/_api/echo" then
    return apiEcho(out, ctx, req, headOnly)
  end

  if isApi then
    local code, err = response.errorPage(out, 404, "未知的 API 路径：" .. req.path, headOnly)
    return code, err, 0
  end

  -- 静态资源只接受 GET / HEAD；POST 已读取请求体但无法写入磁盘
  if method == "POST" then
    local code, err = response.errorPage(out, 405,
      "静态资源不支持 POST 方法（请求体已读取并丢弃）", false, { "Allow: " .. allow })
    return code, err, 0
  end

  return static.serve(out, ctx, req, headOnly)
end

M.isLoopback = isLoopback

return M
