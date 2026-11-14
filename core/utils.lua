-- core/utils.lua — 通用工具：时间、大小、URL 编解码、HTML 转义、局域网地址
local M = {}

local NetworkInterface = luajava.bindClass "java.net.NetworkInterface"
local SystemClock = luajava.bindClass "android.os.SystemClock"

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- 单调时钟（毫秒），用于运行时长与耗时统计
function M.millis()
  return SystemClock.elapsedRealtime()
end

function M.trim(text)
  return (string.gsub(tostring(text or ""), "^%s*(.-)%s*$", "%1"))
end

function M.truncate(text, limit)
  text = tostring(text or "")
  if #text <= limit then return text end
  return string.sub(text, 1, limit - 1) .. "…"
end

--- 字节数人类可读
function M.formatBytes(bytes)
  bytes = tonumber(bytes) or 0
  if bytes < 1024 then return bytes .. " B" end
  if bytes < 1024 * 1024 then return string.format("%.1f KB", bytes / 1024) end
  if bytes < 1024 * 1024 * 1024 then return string.format("%.1f MB", bytes / 1048576) end
  return string.format("%.2f GB", bytes / 1073741824)
end

--- 运行时长：73 -> "1分13秒"
function M.formatUptime(ms)
  ms = tonumber(ms) or 0
  if ms < 0 then ms = 0 end
  local total = math.floor(ms / 1000)
  local hours = math.floor(total / 3600)
  local minutes = math.floor((total % 3600) / 60)
  local seconds = total % 60
  if hours > 0 then return string.format("%d小时%02d分", hours, minutes) end
  if minutes > 0 then return string.format("%d分%02d秒", minutes, seconds) end
  return string.format("%d秒", seconds)
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

--- HTTP 日期：Fri, 14 Nov 2026 19:19:41 GMT
-- epochMs 可选：传入毫秒时间戳时输出该时刻，否则输出当前时间
function M.httpDate(epochMs)
  local Calendar = luajava.bindClass "java.util.Calendar"
  local TimeZone = luajava.bindClass "java.util.TimeZone"
  local cal = Calendar.getInstance(TimeZone.getTimeZone("GMT"))
  if type(epochMs) == "number" and epochMs > 0 then
    cal.setTimeInMillis(math.floor(epochMs))
  end
  local dow = cal.get(Calendar.DAY_OF_WEEK)
  local day = cal.get(Calendar.DAY_OF_MONTH)
  local month = MONTHS[cal.get(Calendar.MONTH) + 1]
  local year = cal.get(Calendar.YEAR)
  local h = cal.get(Calendar.HOUR_OF_DAY)
  local mi = cal.get(Calendar.MINUTE)
  local s = cal.get(Calendar.SECOND)
  return string.format("%s, %02d %s %04d %02d:%02d:%02d GMT",
    WEEKDAYS[dow] or "Thu", day, month, year, h, mi, s)
end

--- 解析 HTTP 日期头为 epoch 秒；无法解析返回 nil
-- 支持 RFC 1123 (Sun, 06 Nov 1994 08:49:37 GMT) 与 RFC 850 / asctime 常见形式
local MONTH_INDEX = {
  Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

function M.parseHttpDate(text)
  if type(text) ~= "string" or text == "" then return nil end
  local day, monName, year, h, mi, s = string.match(text,
    "(%d%d?)%s+([A-Za-z]+)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)")
  if not day then
    -- asctime: Sun Nov  6 08:49:37 1994
    monName, day, h, mi, s, year = string.match(text,
      "^[A-Za-z]+%s+([A-Za-z]+)%s+(%d%d?)%s+(%d%d):(%d%d):(%d%d)%s+(%d%d%d%d)")
  end
  if not day then return nil end
  local month = MONTH_INDEX[monName]
  if not month then return nil end
  local ok, epoch = pcall(function()
    local Calendar = luajava.bindClass "java.util.Calendar"
    local TimeZone = luajava.bindClass "java.util.TimeZone"
    local cal = Calendar.getInstance(TimeZone.getTimeZone("GMT"))
    cal.clear()
    cal.set(tonumber(year), month - 1, tonumber(day), tonumber(h), tonumber(mi), tonumber(s))
    return math.floor(cal.getTimeInMillis() / 1000)
  end)
  if ok and type(epoch) == "number" then return epoch end
  return nil
end

function M.escapeHtml(text)
  text = tostring(text or "")
  text = string.gsub(text, "&", "&amp;")
  text = string.gsub(text, "<", "&lt;")
  text = string.gsub(text, ">", "&gt;")
  text = string.gsub(text, "\"", "&quot;")
  text = string.gsub(text, "'", "&#39;")
  return text
end

--- 百分号解码；失败返回 nil
function M.urlDecode(text, plusAsSpace)
  if text == nil then return nil end
  if plusAsSpace then text = string.gsub(text, "%+", " ") end
  local out = {}
  local i, len = 1, #text
  while i <= len do
    local char = string.sub(text, i, i)
    if char == "%" then
      local hex = string.sub(text, i + 1, i + 2)
      if #hex < 2 then return nil end
      local value = tonumber(hex, 16)
      if value == nil then return nil end
      out[#out + 1] = string.char(value)
      i = i + 3
    else
      out[#out + 1] = char
      i = i + 1
    end
  end
  return table.concat(out)
end

function M.urlEncode(text)
  return (string.gsub(tostring(text or ""), "[^%w%-%._~]", function(char)
    return string.format("%%%02X", string.byte(char))
  end))
end

--- 查询串 -> 表（重复键保留首个，值已解码）
function M.parseQuery(query)
  local params = {}
  if not query or query == "" then return params end
  for pair in string.gmatch(query, "[^&]+") do
    local eq = string.find(pair, "=", 1, true)
    local rawKey, rawValue
    if eq then
      rawKey = string.sub(pair, 1, eq - 1)
      rawValue = string.sub(pair, eq + 1)
    else
      rawKey, rawValue = pair, ""
    end
    local key = M.urlDecode(rawKey, true)
    local value = M.urlDecode(rawValue, true)
    if key then
      if params[key] == nil then params[key] = value or "" end
    end
  end
  return params
end

--- 局域网 IPv4 地址（10 秒缓存，避免每秒轮询网卡）
local lanCache, lanStamp = nil, 0

function M.lanAddresses()
  local now = M.millis()
  if lanCache and (now - lanStamp) < 10000 then return lanCache end
  local list = {}
  pcall(function()
    local interfaces = NetworkInterface.getNetworkInterfaces()
    while interfaces.hasMoreElements() do
      local iface = interfaces.nextElement()
      local up = false
      pcall(function() up = iface.isUp() end)
      if up then
        local addresses = iface.getInetAddresses()
        while addresses.hasMoreElements() do
          local address = addresses.nextElement()
          local skip = false
          pcall(function()
            skip = address.isLoopbackAddress() or address.isLinkLocalAddress()
          end)
          local ip = address.getHostAddress()
          if not skip and ip and not string.find(ip, ":", 1, true) then
            local name = iface.getName()
            if ip ~= "0.0.0.0" then
              list[#list + 1] = { ip = ip, name = name }
            end
          end
        end
      end
    end
  end)
  lanCache, lanStamp = list, now
  return list
end

function M.firstLanIp()
  local list = M.lanAddresses()
  for i = 1, #list do
    if not string.find(list[i].ip, "^127%.") then return list[i].ip end
  end
  return nil
end

return M
