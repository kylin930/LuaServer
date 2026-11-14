app_name = "LuaServer"
package_name = "com.xiaolin.luaserver"
ver_name = "0.2"
ver_code = "2"
min_sdk = "26"
target_sdk = "33"
debug_mode = true
NeLuaJ_Theme = "Theme_NeLuaJ_Material3_NoActionBar_ActionOverlay"
-- INTERNET：创建本地监听 Socket
-- FOREGROUND_SERVICE + FOREGROUND_SERVICE_DATA_SYNC：服务器在 Android 前台服务中常驻运行
-- POST_NOTIFICATIONS：Android 13+ 显示常驻运行通知
-- WAKE_LOCK：保证后台服务在锁屏时仍能处理请求
user_permission = {
  "INTERNET",
  "FOREGROUND_SERVICE",
  "FOREGROUND_SERVICE_DATA_SYNC",
  "POST_NOTIFICATIONS",
  "WAKE_LOCK",
}
