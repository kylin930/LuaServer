-- server/router.lua — 请求分发：静态资源 + 只允许本机访问的状态 API
local M = {}

local response = require "server.response"
local static = require "server.static_file"

local jsonEncode = json.encode

local LOOPBACK_PREFIX = "^127%."

local function isLoopback(ip)
  if not ip then return false end
  if ip == "127.0.0.1" or ip == "::1" or ip == "0:0:0:0:0:0:0:1" then return true end
  return string.find(ip, LOOPBACK_PREFIX) ~= nil
end

--- 本机状态接口：仅 loopback 客户端可读，避免局域网设备探测服务信息
local function apiStatus(out, ctx, headOnly)
  if not isLoopback(ctx.clientIp) then
    response.errorPage(out, 403, "状态接口仅允许本机访问", headOnly)
    return 403
  end
  local snapshot = ctx.statusProvider()
  local ok, body = pcall(jsonEncode, snapshot)
  if not ok then body = "{\"error\":\"encode failed\"}" end
  return response.sendText(out, 200,
    { "Content-Type: application/json; charset=utf-8", "Cache-Control: no-store" }, body, headOnly)
end

--- 返回最终状态码，供访问日志记录
function M.handle(req, out, ctx)
  local method = req.method
  local headOnly = method == "HEAD"

  if method == "POST" then
    response.errorPage(out, 501, "第一版未实现 POST 请求体解析", false)
    return 501
  end
  if method ~= "GET" and method ~= "HEAD" then
    response.errorPage(out, 405, "不支持的方法：" .. tostring(method), false, { "Allow: GET, HEAD" })
    return 405
  end
  if req.chunked then
    response.errorPage(out, 501, "暂不支持 Transfer-Encoding: chunked 请求", headOnly)
    return 501
  end

  if req.path == "/_api/status" then
    return apiStatus(out, ctx, headOnly)
  end
  if string.sub(req.path, 1, 6) == "/_api/" then
    response.errorPage(out, 404, "未知的 API 路径：" .. req.path, headOnly)
    return 404
  end

  return static.serve(out, ctx, req, headOnly)
end

return M
