-- www/seed.lua — 默认站点模板
--
-- 运行时由 server/static_file.lua 在网站根目录缺少 index.html 时写入这些文件。
-- 之所以用 Lua 长字符串而不是工程内的真实 html 文件：打包成 APK 后工程文件位于
-- assets，运行期不一定能按普通文件路径读取；内嵌模板可以确保首次启动一定能创建站点。
local M = {}

local INDEX_HTML = [==[<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LuaServer · 站点已就绪</title>
<link rel="icon" href="/logo.svg" type="image/svg+xml">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header class="topbar">
  <img src="/logo.svg" alt="LuaServer" width="40" height="40">
  <div>
    <h1>LuaServer</h1>
    <p class="sub">手机上的轻量 HTTP 服务器</p>
  </div>
</header>

<main>
  <section class="card hero">
    <p class="eyebrow">站点已就绪</p>
    <h2>这个页面由你的手机托管</h2>
    <p class="muted">
      默认站点位于应用的 <code>www</code> 目录。你可以把 HTML、CSS、JS、图片
      放进这个目录，然后通过局域网访问。
    </p>
    <div class="actions">
      <a class="btn primary" href="/style.css">查看样式表</a>
      <a class="btn" href="/app.js">查看脚本</a>
      <a class="btn" href="/logo.svg">查看图标</a>
    </div>
  </section>

  <section class="card">
    <h3>服务器状态</h3>
    <div id="status" class="status">正在读取状态…</div>
    <p class="muted small">
      <code>/_api/status</code> 接口仅允许本机（127.0.0.1）访问，用于验证 HTTP API 是否工作。
    </p>
  </section>

  <section class="card">
    <h3>静态资源测试</h3>
    <ul class="links">
      <li><a href="/index.html">index.html</a><span>HTML</span></li>
      <li><a href="/style.css">style.css</a><span>CSS</span></li>
      <li><a href="/app.js">app.js</a><span>JavaScript</span></li>
      <li><a href="/logo.svg">logo.svg</a><span>SVG</span></li>
      <li><a href="/not-exist.html">not-exist.html</a><span>应返回 404</span></li>
    </ul>
  </section>

  <section class="card">
    <h3>常见状态码</h3>
    <ul class="links">
      <li><span class="tag">404</span><span>文件不存在</span></li>
      <li><span class="tag">403</span><span>路径穿越被拒绝</span></li>
      <li><span class="tag">405</span><span>不支持的方法</span></li>
      <li><span class="tag">501</span><span>POST 暂未实现</span></li>
    </ul>
  </section>
</main>

<footer class="foot">
  <p>LuaServer · 由 NeLuaJ+ 与 Lua 驱动</p>
  <p class="muted small">仅在应用运行期间提供服务；请勿将此服务直接暴露到公网。</p>
</footer>

<script src="/app.js"></script>
</body>
</html>
]==]

local STYLE_CSS = [==[/* LuaServer 默认站点样式：蓝绿色系、MD3 风格卡片 */
:root {
  --primary: #00696b;
  --primary-container: #9cf1f0;
  --on-primary-container: #002020;
  --surface: #f5fbfa;
  --surface-low: #ffffff;
  --surface-container: #e7f2f0;
  --on-surface: #191c1c;
  --on-surface-variant: #3f4948;
  --outline: #bec9c8;
  --error: #ba1a1a;
  --radius: 18px;
}

@media (prefers-color-scheme: dark) {
  :root {
    --primary: #80d4d5;
    --primary-container: #004f50;
    --on-primary-container: #9cf1f0;
    --surface: #101414;
    --surface-low: #1a1f1f;
    --surface-container: #232928;
    --on-surface: #e0e3e2;
    --on-surface-variant: #bfc9c8;
    --outline: #3f4948;
    --error: #ffb4ab;
  }
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--surface);
  color: var(--on-surface);
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
  line-height: 1.6;
  -webkit-font-smoothing: antialiased;
}

.topbar {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 20px 20px 12px;
  max-width: 720px;
  margin: 0 auto;
}

.topbar h1 {
  font-size: 20px;
  margin: 0;
  font-weight: 650;
  letter-spacing: .2px;
}

.topbar .sub {
  margin: 0;
  font-size: 13px;
  color: var(--on-surface-variant);
}

main {
  max-width: 720px;
  margin: 0 auto;
  padding: 0 20px 32px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}

.card {
  background: var(--surface-low);
  border: 1px solid var(--outline);
  border-radius: var(--radius);
  padding: 18px 18px 16px;
}

.hero { background: var(--surface-low); }

.eyebrow {
  margin: 0 0 6px;
  font-size: 12px;
  font-weight: 600;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--primary);
}

.card h2 { font-size: 21px; margin: 0 0 8px; font-weight: 650; }
.card h3 { font-size: 15px; margin: 0 0 10px; font-weight: 650; }

.muted { color: var(--on-surface-variant); margin: 0; }
.small { font-size: 12.5px; margin-top: 10px; }

code {
  background: var(--surface-container);
  border-radius: 6px;
  padding: 1px 5px;
  font-size: 12.5px;
}

.actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; }

.btn {
  display: inline-block;
  padding: 9px 16px;
  border-radius: 999px;
  border: 1px solid var(--outline);
  color: var(--on-surface);
  text-decoration: none;
  font-size: 14px;
  font-weight: 550;
}

.btn.primary {
  background: var(--primary);
  border-color: var(--primary);
  color: #ffffff;
}

.status {
  font-size: 14px;
  background: var(--surface-container);
  border-radius: 12px;
  padding: 12px 14px;
  white-space: pre-wrap;
  word-break: break-word;
  font-variant-numeric: tabular-nums;
}

.status.ok { border-left: 4px solid var(--primary); }
.status.bad { border-left: 4px solid var(--error); }

.links { list-style: none; margin: 0; padding: 0; }

.links li {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 9px 0;
  border-bottom: 1px solid var(--surface-container);
  font-size: 14px;
}

.links li:last-child { border-bottom: 0; }
.links a { color: var(--primary); text-decoration: none; }
.links span { color: var(--on-surface-variant); font-size: 12.5px; }

.tag {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  background: var(--surface-container);
  border-radius: 6px;
  padding: 1px 7px;
}

.foot {
  max-width: 720px;
  margin: 0 auto;
  padding: 0 20px 36px;
  font-size: 13px;
  color: var(--on-surface-variant);
}

.foot p { margin: 2px 0; }
]==]

local APP_JS = [==[// LuaServer 默认站点脚本：读取本机状态接口并渲染
(function () {
  var box = document.getElementById('status');
  if (!box) return;

  function line(key, value) {
    return key + ': ' + value;
  }

  fetch('/_api/status', { cache: 'no-store' })
    .then(function (response) {
      if (response.status === 403) {
        throw new Error('仅本机（127.0.0.1）可读取状态接口');
      }
      if (!response.ok) {
        throw new Error('HTTP ' + response.status);
      }
      return response.json();
    })
    .then(function (data) {
      box.className = 'status ok';
      box.textContent = [
        line('运行状态', data.running ? '运行中' : '已停止'),
        line('监听地址', data.host + ':' + data.port),
        line('并发上限', data.maxConnections),
        line('累计请求', data.total),
        line('成功 / 错误', data.success + ' / ' + data.failure),
        line('活动连接', data.activeConnections),
        line('客户端时间', new Date().toLocaleString())
      ].join('\n');
    })
    .catch(function (error) {
      box.className = 'status bad';
      box.textContent = '状态接口不可用：' + error.message +
        '\n（该接口只对本机开放，属正常现象）';
    });
})();
]==]

local LOGO_SVG = [==[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64" role="img" aria-label="LuaServer">
  <rect width="64" height="64" rx="16" fill="#00696b"/>
  <rect x="14" y="16" width="36" height="10" rx="5" fill="#9cf1f0"/>
  <rect x="14" y="28" width="36" height="10" rx="5" fill="#9cf1f0" opacity="0.75"/>
  <rect x="14" y="40" width="36" height="10" rx="5" fill="#9cf1f0" opacity="0.5"/>
  <circle cx="21" cy="21" r="2.4" fill="#00696b"/>
  <circle cx="21" cy="33" r="2.4" fill="#00696b"/>
  <circle cx="21" cy="45" r="2.4" fill="#00696b"/>
</svg>
]==]

M.files = {
  ["index.html"] = INDEX_HTML,
  ["style.css"] = STYLE_CSS,
  ["app.js"] = APP_JS,
  ["logo.svg"] = LOGO_SVG,
}

return M
