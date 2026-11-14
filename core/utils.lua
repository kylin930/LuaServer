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

--- HTTP 日期：Fri, 14 Nov 2026 19:19:41 GMT
function M.httpDate()
  local Calendar = luajava.bindClass "java.util.Calendar"
  local TimeZone = luajava.bindClass "java.util.TimeZone"
  local cal = Calendar.getInstance(TimeZone.getTimeZone("GMT"))
  local dow = cal.get(Calendar.DAY_OF_WEEK)
  local day = cal.get(Calendar.DAY_OF_MONTH)
  local month = MONTHS[cal.get(Calendar.MONTH) + 1]
  local year = cal.get(Calendar.YEAR)
  local h = cal.get(Calendar.HOUR_OF_DAY)
  local mi = cal.get(Calendar.MINUTE)
  local s = cal.get(Calendar.SECOND)
  local week = ({ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" })[dow]
  return string.format("%s, %02d %s %04d %02d:%02d:%02d GMT", week, day, month, year, h, mi, s)
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
