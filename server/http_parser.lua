-- server/http_parser.lua — 有长度上限的 HTTP/1.x 请求解析
--
-- 读取全部基于 InputStream.read()，逐字节处理，因此 CRLF、裸 LF、请求行与 Header
-- 都能在明确上限内被解析；不会出现 readLine 无上限导致的内存风险。
local M = {}

local utils = require "core.utils"

M.MAX_REQUEST_LINE = 4096     -- 单行上限（请求行 / 每个 Header）
M.MAX_TARGET = 2048           -- 请求目标（路径 + 查询串）上限
M.MAX_HEADER_BYTES = 8192     -- 整个请求头上限，超出返回 431
M.MAX_HEADER_COUNT = 64       -- Header 数量上限
M.MAX_BODY = 1048576          -- 允许读取/丢弃的请求体上限，超出返回 413
M.MAX_LEADING_BLANKS = 4      -- 容忍客户端在请求行前多发的空行

local Reader = {}
Reader.__index = Reader

function M.newReader(stream)
  return setmetatable({ stream = stream, headerBytes = 0 }, Reader)
end

--- 读一行（不含 CR/LF）。EOF 且无数据时返回 nil；超长时返回 nil, "too-long"
function Reader:readLine(maxLen)
  local chars, count = {}, 0
  while true do
    local byte = self.stream.read()
    if byte == -1 then
      if count == 0 then return nil end
      break
    end
    if byte == 10 then break end
    if byte ~= 13 then
      count = count + 1
      if count > maxLen then return nil, "too-long" end
      chars[count] = string.char(byte)
    end
  end
  self.headerBytes = self.headerBytes + count
  return table.concat(chars)
end

--- 读取指定长度的请求体（原始字节字符串）
-- 返回 body, nil 表示成功；返回 nil, reason 表示失败
function Reader:readBody(count)
  local remaining = tonumber(count) or 0
  if remaining <= 0 then return "" end
  if remaining > M.MAX_BODY then return nil, "too-large" end
  local chunks, read = {}, 0
  while read < remaining do
    local byte = self.stream.read()
    if byte == -1 then return table.concat(chunks), "truncated" end
    read = read + 1
    chunks[read] = string.char(byte)
  end
  return table.concat(chunks)
end

--- 丢弃 count 字节请求体，避免未读数据导致连接被 RST
function Reader:drain(count)
  local remaining = tonumber(count) or 0
  if remaining <= 0 then return true end
  if remaining > M.MAX_BODY then return false, "too-large" end
  local buffer = 4096
  while remaining > 0 do
    local chunk = math.min(buffer, remaining)
    for _ = 1, chunk do
      if self.stream.read() == -1 then return true end
    end
    remaining = remaining - chunk
  end
  return true
end

--- 规范化绝对形式目标（GET http://host/path）为 path
local function stripScheme(target)
  local lowered = string.lower(target)
  if string.sub(lowered, 1, 7) == "http://" then
    local slash = string.find(target, "/", 8)
    return slash and string.sub(target, slash) or "/"
  end
  if string.sub(lowered, 1, 8) == "https://" then
    local slash = string.find(target, "/", 9)
    return slash and string.sub(target, slash) or "/"
  end
  return target
end

--- 解析请求
-- 成功：req 表
-- 失败：nil, statusCode, message；statusCode == 0 表示客户端在发送请求前就断开，不应写响应
function M.parse(reader)
  local line, lineErr
  for _ = 1, M.MAX_LEADING_BLANKS do
    line, lineErr = reader:readLine(M.MAX_REQUEST_LINE)
    if lineErr then return nil, 414, "请求行过长" end
    if line == nil then return nil, 0, "客户端未发送请求" end
    if line ~= "" then break end
  end
  if line == nil or line == "" then return nil, 400, "请求行为空" end

  -- 方法名允许 HTTP token 字符（含 - _ 等，便于识别非法方法并返回 405 而非 400）
  local method, target, version = string.match(line, "^([%w!#%$%%&'%*%+%-.%^_`|~]+) (%S+) (HTTP/%d%.%d)$")
  if not method then return nil, 400, "请求行格式错误" end
  if #target > M.MAX_TARGET then return nil, 414, "请求目标过长" end
  if version ~= "HTTP/1.1" and version ~= "HTTP/1.0" then
    return nil, 505, "仅支持 HTTP/1.0 与 HTTP/1.1"
  end

  target = stripScheme(target)
  local rawPath, query = target, nil
  local qpos = string.find(target, "?", 1, true)
  if qpos then
    rawPath = string.sub(target, 1, qpos - 1)
    query = string.sub(target, qpos + 1)
  end
  if rawPath == "" then rawPath = "/" end
  if string.sub(rawPath, 1, 1) ~= "/" then return nil, 400, "请求路径必须以 / 开头" end

  local path = utils.urlDecode(rawPath, false)
  if not path then return nil, 400, "路径百分号编码无效" end
  if string.find(path, "\0", 1, true) then return nil, 400, "路径包含非法字符" end

  local headers, count = {}, 0
  while true do
    if reader.headerBytes > M.MAX_HEADER_BYTES then return nil, 431, "请求头过大" end
    local headerLine, headerErr = reader:readLine(M.MAX_REQUEST_LINE)
    if headerErr then return nil, 431, "请求头单行过长" end
    if headerLine == nil then return nil, 400, "请求头不完整" end
    if headerLine == "" then break end
    count = count + 1
    if count > M.MAX_HEADER_COUNT then return nil, 431, "请求头数量过多" end
    local name, value = string.match(headerLine, "^([%w%-_%.]+):%s*(.-)%s*$")
    if name then
      local key = string.lower(name)
      if headers[key] == nil then headers[key] = value end
    end
  end
  if reader.headerBytes > M.MAX_HEADER_BYTES then return nil, 431, "请求头过大" end

  local transferEncoding = headers["transfer-encoding"]
  local chunked = transferEncoding ~= nil
    and string.find(string.lower(transferEncoding), "chunked", 1, true) ~= nil

  local contentLength = 0
  local rawLength = headers["content-length"]
  if rawLength ~= nil then
    local parsed = tonumber(rawLength)
    if not parsed or parsed < 0 then return nil, 400, "Content-Length 无效" end
    if parsed > M.MAX_BODY then return nil, 413, "请求体过大" end
    contentLength = math.floor(parsed)
  end

  -- RFC 7230：同时出现 Transfer-Encoding 与 Content-Length 属请求走私风险，直接拒绝
  if chunked and rawLength ~= nil then
    return nil, 400, "不允许同时使用 Transfer-Encoding 与 Content-Length"
  end

  return {
    method = method,
    target = target,
    path = path,
    query = query,
    version = version,
    headers = headers,
    contentLength = contentLength,
    chunked = chunked and true or false,
    params = utils.parseQuery(query),
  }
end

return M
