-- core/logger.lua — 线程安全的请求日志与计数
--
-- 工作线程只做两件事：累加 Atomic 计数、把日志行 offer 进 LinkedBlockingQueue。
-- 主线程/Service 心跳线程用 drain() 取走日志并写入 history，因此不会跨线程操作 View。
local M = {}

local LinkedBlockingQueue = luajava.bindClass "java.util.concurrent.LinkedBlockingQueue"
local AtomicInteger = luajava.bindClass "java.util.concurrent.atomic.AtomicInteger"
local AtomicLong = luajava.bindClass "java.util.concurrent.atomic.AtomicLong"

local SEP = string.char(31)
local osdate = os.date

local Logger = {}
Logger.__index = Logger

M.SEP = SEP

--- 清理日志字段，避免分隔符/换行破坏行格式
local function clean(text, limit)
  text = tostring(text or "")
  text = string.gsub(text, "[\r\n\t]", " ")
  text = string.gsub(text, SEP, " ")
  if #text > limit then text = string.sub(text, 1, limit - 1) .. "…" end
  return text
end

function M.new(limit)
  limit = limit or 200
  return setmetatable({
    limit = limit,
    queue = LinkedBlockingQueue(limit),
    total = AtomicInteger(0),
    success = AtomicInteger(0),
    failure = AtomicInteger(0),
    active = AtomicInteger(0),
    totalMs = AtomicLong(0),
    countedMs = AtomicInteger(0),
    bytesOut = AtomicLong(0),
    history = {},
    version = 0,
  }, Logger)
end

local function encode(kind, time, method, path, status, ms, client)
  return table.concat({ kind, time, method, path, tostring(status), tostring(ms), client }, SEP)
end

--- 工作线程调用：记录一次请求
-- bytes 为本次响应正文字节数（未知时传 nil）
function Logger:request(method, path, status, ms, client, bytes)
  self.total.incrementAndGet()
  if status and status >= 400 then
    self.failure.incrementAndGet()
  else
    self.success.incrementAndGet()
  end
  local cost = tonumber(ms) or 0
  if cost > 0 then
    self.totalMs.addAndGet(math.floor(cost))
    self.countedMs.incrementAndGet()
  end
  if bytes and bytes > 0 then self.bytesOut.addAndGet(bytes) end
  self.queue.offer(encode("req", osdate("%H:%M:%S"), clean(method, 12), clean(path, 160),
    status or 0, cost, clean(client, 40)))
end

--- 工作线程调用：记录一条服务器事件
function Logger:event(text)
  self.queue.offer(encode("event", osdate("%H:%M:%S"), "-", clean(text, 160), 0, 0, "-"))
end

--- 主线程调用：取走全部待处理日志
function Logger:drain()
  local list = {}
  while true do
    local item = self.queue.poll()
    if item == nil then break end
    local line = tostring(item)
    local parts = {}
    local start = 1
    while true do
      local pos = string.find(line, SEP, start, true)
      if not pos then
        parts[#parts + 1] = string.sub(line, start)
        break
      end
      parts[#parts + 1] = string.sub(line, start, pos - 1)
      start = pos + 1
    end
    if #parts >= 7 then
      list[#list + 1] = {
        kind = parts[1],
        time = parts[2],
        method = parts[3],
        path = parts[4],
        status = tonumber(parts[5]) or 0,
        ms = tonumber(parts[6]) or 0,
        client = parts[7],
      }
    end
  end
  return list
end

--- 主线程调用：把日志并入历史（新的在前，长度有上限）
function Logger:pushHistory(entries)
  for i = 1, #entries do
    table.insert(self.history, 1, entries[i])
  end
  while #self.history > self.limit do
    table.remove(self.history)
  end
  self.version = self.version + 1
end

function Logger:historySnapshot()
  return self.history
end

--- 把队列里的新日志并入历史，返回是否有变化
function Logger:sync()
  local entries = self:drain()
  if #entries > 0 then
    self:pushHistory(entries)
    return true
  end
  return false
end

--- 平均响应时间（毫秒）
function Logger:averageMs()
  local count = self.countedMs.get()
  if count <= 0 then return 0 end
  return self.totalMs.get() / count
end

function Logger:stats()
  return {
    total = self.total.get(),
    success = self.success.get(),
    failure = self.failure.get(),
    active = self.active.get(),
    avgMs = self:averageMs(),
    bytesOut = self.bytesOut.get(),
  }
end

--- 导出为可 JSON 化的快照（供 core/store 下发给 Activity）
function Logger:toSnapshot(maxEntries)
  maxEntries = maxEntries or 120
  local stats = self:stats()
  local logs = {}
  local count = math.min(#self.history, maxEntries)
  for i = 1, count do
    local entry = self.history[i]
    logs[i] = {
      k = entry.kind,
      t = entry.time,
      m = entry.method,
      p = entry.path,
      s = entry.status,
      d = entry.ms,
      c = entry.client,
    }
  end
  return {
    total = stats.total,
    success = stats.success,
    failure = stats.failure,
    active = stats.active,
    avgMs = stats.avgMs,
    bytesOut = stats.bytesOut,
    logs = logs,
  }
end

--- 清空计数与日志（不影响运行中的服务器）
function Logger:reset()
  self.queue.clear()
  self.total.set(0)
  self.success.set(0)
  self.failure.set(0)
  self.totalMs.set(0)
  self.countedMs.set(0)
  self.bytesOut.set(0)
  self.history = {}
  self.version = self.version + 1
end

return M
