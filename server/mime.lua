-- server/mime.lua — 扩展名到 MIME 的映射
local M = {}

local TEXT = "text/plain; charset=utf-8"

local TYPES = {
  html = "text/html; charset=utf-8",
  htm = "text/html; charset=utf-8",
  xhtml = "application/xhtml+xml",
  css = "text/css; charset=utf-8",
  js = "application/javascript; charset=utf-8",
  mjs = "application/javascript; charset=utf-8",
  json = "application/json; charset=utf-8",
  map = "application/json; charset=utf-8",
  txt = TEXT,
  md = TEXT,
  csv = "text/csv; charset=utf-8",
  xml = "application/xml; charset=utf-8",
  svg = "image/svg+xml",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  bmp = "image/bmp",
  ico = "image/x-icon",
  avif = "image/avif",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf = "font/ttf",
  otf = "font/otf",
  eot = "application/vnd.ms-fontobject",
  mp3 = "audio/mpeg",
  ogg = "audio/ogg",
  wav = "audio/wav",
  mp4 = "video/mp4",
  webm = "video/webm",
  pdf = "application/pdf",
  zip = "application/zip",
  gz = "application/gzip",
  wasm = "application/wasm",
  manifest = "text/cache-manifest; charset=utf-8",
  webmanifest = "application/manifest+json; charset=utf-8",
}

M.DEFAULT = "application/octet-stream"

--- 按文件名/路径取 MIME；未知扩展名回退 octet-stream
function M.typeOf(nameOrPath)
  local ext = string.match(tostring(nameOrPath or ""), "%.([%w]+)$")
  if not ext then return M.DEFAULT end
  return TYPES[string.lower(ext)] or M.DEFAULT
end

function M.isText(mime)
  if not mime then return false end
  return string.find(mime, "^text/", 1) ~= nil
    or string.find(mime, "json", 1, true) ~= nil
    or string.find(mime, "javascript", 1, true) ~= nil
    or string.find(mime, "xml", 1, true) ~= nil
end

return M
