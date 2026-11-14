// LuaServer 默认站点脚本：读取本机状态接口并渲染
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
