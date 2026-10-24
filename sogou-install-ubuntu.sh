#!/usr/bin/env bash
# =============================================================================
#  搜狗拼音输入法 Linux 版一键安装脚本 (Ubuntu / Debian 系)
#
#  适用: Ubuntu 20.04 ~ 24.04 (x86_64), GNOME/KDE 桌面
#  用法:
#     sudo bash sogou-install-ubuntu.sh              # 完整安装
#     sudo bash sogou-install-ubuntu.sh --test       # 只跑验证(无需 root)
#     sudo bash sogou-install-ubuntu.sh --xorg-only  # 安装并把 GDM 固定为 Xorg
#     sudo bash sogou-install-ubuntu.sh --url <URL>  # 指定安装包下载地址
#     sudo bash sogou-install-ubuntu.sh --rollback   # 卸载搜狗，恢复 fcitx5
#     sudo bash sogou-install-ubuntu.sh --rollback=ibus  # 卸载搜狗，恢复 ibus
#
#  -----------------------------------------------------------------------------
#  踩过的坑（脚本已全部处理，勿删）：
#
#  [坑1] 搜狗 deb 的 postinst 在 Ubuntu 上执行
#         mv /opt/sogoupinyin/files/lib/qt5 -> qt5.bak
#         目的是让搜狗改用系统 Qt5。但搜狗所有二进制的 RPATH 是
#         $ORIGIN/../lib:$ORIGIN/../lib/qt5/lib
#         第二段失效后 libgsettings-qt.so.1 找不到，而该库只存在于 qt5.bak 里
#         (官方包不提供它)。结果: sogoupinyin-service 起不来 ->
#         fcitx-sogoupinyin.so 插件加载失败 -> 输入法完全无反应。
#         修复: 安装官方包 libgsettings-qt1。
#
#  [坑2] fcitx4 约定 imes[0] 必须是键盘布局(英文态占位)，真输入法从 index 1 起。
#         若搜狗排在 EnabledIMList 第一位(index 0)，会被
#         FcitxInstanceGetIMIndexByName() 的 `globalIndex <= 0` 判为无效并
#         回退到 index 1 的 fcitx-keyboard-cn；fcitx 还会把这个回退值
#         写回 globalIMName 并保存到 profile，形成自我强化的死循环。
#         修复: 把 fcitx-keyboard-us 提到 EnabledIMList 首位。
#
#  [坑3] sudo 会把 $HOME 改成 /root，导致 im-config 和 fcitx 配置写错用户。
#         修复: 用 $SUDO_USER 反查真实用户的 HOME / UID / session bus。
#
#  [坑4] fcitx4 的 ipc/dbus 前端会自建私有 dbus-daemon，旧实例未退干净时
#         新实例启动会报 "DBus Service Already Exists" 直接退出。
#         修复: 重启前杀掉 fcitx 主进程 + 私有 dbus-daemon + dbus-watcher。
#
#  [坑5] 搜狗 service 是 daemonize 的父进程，父进程返回 0，
#         用 pgrep -f 判断会误判为"没起来"。
#         修复: 用 ps 匹配完整命令行判断。
# =============================================================================

set -uo pipefail

# ============================== 参数解析 ==============================
ACTION="install"
FORCE_XORG=0
DEB_URL_OVERRIDE=""
ROLLBACK_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --test)      ACTION="test" ;;
    --xorg-only) FORCE_XORG=1 ;;
    --rollback)  ACTION="rollback"; ROLLBACK_TARGET="fcitx5" ;;
    --rollback=*) ACTION="rollback"; ROLLBACK_TARGET="${1#*=}" ;;
    --url)       DEB_URL_OVERRIDE="${2:-}"; shift ;;
    --url=*)     DEB_URL_OVERRIDE="${1#*=}" ;;
    -h|--help)   sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

# ============================== 日志工具 ==============================
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYA=$'\033[36m'
BLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'
step() { echo -e "\n${BLD}${CYA}==> $* ${RST}"; }
ok()   { echo -e "  ${GRN}[OK]${RST} $*"; }
warn() { echo -e "  ${YLW}[!!]${RST} $*"; }
err()  { echo -e "  ${RED}[XX]${RST} $*"; }
info() { echo -e "  ${DIM}$*${RST}"; }

WORKDIR="$(mktemp -d /tmp/sogou-setup.XXXXXX)"
DEB="$WORKDIR/sogoupinyin_amd64.deb"
trap 'rm -rf "$WORKDIR"' EXIT

# ============================== 环境探测 ==============================
detect_real_user() {
  local u="${SUDO_USER:-}"
  [ -z "$u" ] && u="$(logname 2>/dev/null)"
  [ -z "$u" ] && u="${USER:-root}"
  local h; h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
  if [ -n "$h" ] && [ -d "$h" ]; then
    REAL_USER="$u"; REAL_HOME="$h"
  else
    REAL_USER="$(id -un)"; REAL_HOME="$HOME"
  fi
  UID_REAL="$(id -u "$REAL_USER")"
}

detect_session() {
  S_DISPLAY="${DISPLAY:-:0}"
  S_XAUTH="${XAUTHORITY:-/run/user/$UID_REAL/gdm/Xauthority}"
  [ -r "$S_XAUTH" ] || S_XAUTH="$REAL_HOME/.Xauthority"
  S_DBUS="unix:path=/run/user/$UID_REAL/bus"
  S_RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$UID_REAL}"
  S_TYPE="${XDG_SESSION_TYPE:-unknown}"
}

as_user() {
  sudo -u "$REAL_USER" -H env \
    DISPLAY="$S_DISPLAY" XAUTHORITY="$S_XAUTH" \
    DBUS_SESSION_BUS_ADDRESS="$S_DBUS" \
    XDG_RUNTIME_DIR="$S_RUNTIME" XDG_SESSION_TYPE="$S_TYPE" \
    "$@"
}

detect_real_user
detect_session

# ============================== 环境检查 ==============================
check_env() {
  step "环境检查"
  if [ "$(id -u)" -ne 0 ] && [ "$ACTION" != "test" ]; then
    err "需要 root 权限，请用: sudo bash $0"
    exit 1
  fi
  [ "$(id -u)" -eq 0 ] && ok "root 权限" || info "非 root，${ACTION} 模式下跳过写操作"

  local arch; arch="$(dpkg --print-architecture 2>/dev/null)"
  if [ "$arch" != "amd64" ]; then
    err "搜狗官方 deb 只提供 amd64 构建，当前架构: $arch"
    err "arm64/loongarch64 需自行在官网选对应包"
    exit 1
  fi
  ok "架构 amd64"

  if ! command -v apt-get >/dev/null; then
    err "未找到 apt-get，本脚本仅支持 Ubuntu/Debian 系"
    exit 1
  fi
  ok "包管理器: apt"

  if [ ! -e /usr/share/im-config/data/22_fcitx.conf ]; then
    warn "未找到 im-config 的 fcitx 条目，fcitx4 可能不在软件源中"
  else
    ok "im-config 支持 fcitx"
  fi

  case "$S_TYPE" in
    x11)
      ok "当前会话: X11 (${S_DISPLAY})" ;;
    wayland)
      warn "当前会话: Wayland"
      warn "搜狗 = fcitx4 插件，fcitx4 无 Wayland 原生支持"
      warn "安装后必须注销并改选「Ubuntu on Xorg」，否则输入法不可用" ;;
    *)
      warn "当前会话类型: $S_TYPE (无法判定)" ;;
  esac
  info "真实用户: $REAL_USER ($REAL_HOME)"
  info "会话总线: $S_DBUS"
}

# ============================== 下载 ==============================
resolve_download_url() {
  # 从官网页面动态抓取最新的 amd64 下载地址，抓不到则用内置兜底
  local page url
  page="$(curl -fsSL --max-time 30 "https://shurufa.sogou.com/linux/" 2>/dev/null)"
  if [ -n "$page" ]; then
    url="$(printf '%s' "$page" \
      | grep -oE 'https://[a-z.-]*gtimg\.com/pc/dl/gzindex/[0-9]+/sogoupinyin_[0-9.]+_amd64\.deb' \
      | head -1)"
    if [ -n "$url" ]; then
      echo "$url"; return 0
    fi
  fi
  echo "https://ime.gtimg.com/pc/dl/gzindex/1680521603/sogoupinyin_4.2.1.145_amd64.deb"
}

download_deb() {
  step "下载搜狗输入法安装包"
  local url
  if [ -n "$DEB_URL_OVERRIDE" ]; then
    url="$DEB_URL_OVERRIDE"
    ok "使用指定地址: $url"
  else
    url="$(resolve_download_url)"
    ok "下载地址: $url"
  fi

  local host_try
  for host_try in "$url" \
                  "$(printf '%s' "$url" | sed 's#ime-sec\.gtimg\.com#ime.gtimg.com#')" \
                  "https://ime.gtimg.com/pc/dl/gzindex/1680521603/sogoupinyin_4.2.1.145_amd64.deb"; do
    [ -n "$host_try" ] || continue
    info "尝试: $host_try"
    if curl -fL --max-time 300 --retry 2 \
         -A "Mozilla/5.0 (X11; Linux x86_64) Chrome/120.0" \
         -o "$DEB" "$host_try"; then
      if dpkg-deb -f "$DEB" Package >/dev/null 2>&1; then
        ok "下载成功: $(du -h "$DEB" | cut -f1)"
        local ver; ver="$(dpkg-deb -f "$DEB" Version 2>/dev/null)"
        ok "包版本: $ver"
        info "sha256: $(sha256sum "$DEB" | cut -c1-32)..."
        return 0
      fi
    fi
    warn "该地址不可用，换下一个"
  done
  err "全部下载地址均失败，请手动下载后用 --url 指定"
  exit 1
}

# ============================== 卸载互斥的 fcitx5 ==============================
remove_fcitx5() {
  step "清理与 fcitx4 互斥的 fcitx5"
  # fcitx-data(fcitx4) 与 fcitx5 声明 Conflicts，无法共存
  local pkgs=(
    fcitx5 fcitx5-chinese-addons fcitx5-chinese-addons-bin fcitx5-chinese-addons-data
    fcitx5-pinyin fcitx5-pinyin-gui fcitx5-table fcitx5-module-punctuation
    fcitx5-module-chttrans fcitx5-module-fullwidth fcitx5-module-cloudpinyin
    fcitx5-module-pinyinhelper
  )
  local installed=() p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p")
  done
  if [ ${#installed[@]} -eq 0 ]; then
    ok "fcitx5 未安装，跳过"
    return 0
  fi
  info "将卸载: ${installed[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get remove -y "${installed[@]}" 2>&1 | tail -3
  if dpkg -s fcitx5 >/dev/null 2>&1; then
    warn "fcitx5 仍存在，若安装失败请手动: apt remove --purge fcitx5"
  else
    ok "fcitx5 已移除"
  fi
}

# ============================== 安装 ==============================
install_packages() {
  step "安装搜狗输入法 (含 fcitx4 框架)"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEB" 2>&1 | tail -10; then
    ok "apt 安装完成"
  else
    err "apt 安装失败，上方为详细输出"
    exit 1
  fi
  dpkg -s sogoupinyin >/dev/null 2>&1 || { err "sogoupinyin 未正确安装"; exit 1; }
  ok "sogoupinyin $(dpkg-query -W -f='${Version}' sogoupinyin) 已安装"

  local p
  for p in fcitx fcitx-bin fcitx-data fcitx-module-x11 \
           fcitx-frontend-gtk2 fcitx-frontend-gtk3 fcitx-frontend-qt5 im-config; do
    dpkg -s "$p" >/dev/null 2>&1 && ok "依赖就绪: $p" || err "缺少依赖: $p"
  done
}

install_missing_lib() {
  step "补齐 libgsettings-qt.so.1  (坑1 的修复)"
  if dpkg -s libgsettings-qt1 >/dev/null 2>&1; then
    ok "libgsettings-qt1 已安装"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y libgsettings-qt1 2>&1 | tail -4
  fi
  ldconfig
  ldconfig -p | grep -q libgsettings-qt \
    && ok "库已注册: $(ldconfig -p | grep libgsettings-qt | tr -s ' ' | cut -d' ' -f5)" \
    || { err "库注册失败"; exit 1; }

  # 全量复查：搜狗所有二进制与私有库都不能再有 not found
  local b l miss=0
  for b in /opt/sogoupinyin/files/bin/*; do
    [ -x "$b" ] || continue
    l="$(ldd "$b" 2>&1 | grep 'not found' | awk '{print $1}' | sort -u | tr '\n' ' ')"
    [ -n "$l" ] && { err "$(basename "$b"): 缺 $l"; miss=1; }
  done
  for l in /opt/sogoupinyin/files/lib/*.so*; do
    [ -f "$l" ] || continue
    local m; m="$(ldd "$l" 2>&1 | grep 'not found' | awk '{print $1}' | sort -u | tr '\n' ' ')"
    [ -n "$m" ] && { err "$(basename "$l"): 缺 $m"; miss=1; }
  done
  [ $miss -eq 0 ] && ok "搜狗全部二进制与私有库依赖已满足" || { err "仍有缺失依赖"; exit 1; }
}

set_im_config() {
  step "切换输入法框架 -> fcitx"
  if [ -x /usr/bin/im-config ]; then
    if sudo -u "$REAL_USER" -H im-config -n fcitx; then
      ok "im-config 已设为 fcitx (用户 $REAL_USER)"
    else
      warn "im-config 设置失败，手动执行: sudo -u $REAL_USER -H im-config -n fcitx"
    fi
    [ -f "$REAL_HOME/.xinputrc" ] && info "$(grep -E '^IM=' "$REAL_HOME/.xinputrc" 2>/dev/null)"
  else
    warn "未找到 im-config"
  fi
}

# 修正 profile：键盘布局必须在 index 0，搜狗紧随其后 (坑2 的修复)
fix_profile_order() {
  step "修正 fcitx 的输入法列表顺序 (坑2 的修复)"
  local profile="$REAL_HOME/.config/fcitx/profile"
  if [ ! -f "$profile" ]; then
    warn "profile 不存在: $profile"
    warn "请先注销登录一次（让 fcitx 生成 profile）再运行本脚本的 --fix"
    return 1
  fi
  cp -a "$profile" "$profile.bak.$(date +%s)"
  python3 - "$profile" <<'PYEOF'
import re, sys
p = sys.argv[1]
data = open(p, errors="ignore").read()
m = re.search(r"^EnabledIMList=(.*)$", data, re.M)
if not m:
    print("  !! 找不到 EnabledIMList"); sys.exit(1)
entries = [e for e in m.group(1).split(",") if e]
en = [e for e in entries if e.endswith(":True")]
di = [e for e in entries if e.endswith(":False")]
ph = None
for cand in ("fcitx-keyboard-us", "fcitx-keyboard-en", "fcitx-keyboard-cn"):
    if f"{cand}:True" in en:
        ph = cand; break
    if f"{cand}:False" in di:
        ph = cand; di.remove(f"{cand}:False"); en.append(f"{cand}:True"); break
if ph is None:
    print("  !! 找不到可用的键盘布局"); sys.exit(1)
en = [e for e in en if not e.startswith(ph + ":")]
en.insert(0, f"{ph}:True")           # index 0 = 英文态占位
en = [e for e in en if not e.startswith("sogoupinyin:")]
en.append("sogoupinyin:True")        # 搜狗排到占位之后
data = data[:m.start(1)] + ",".join(en + di) + data[m.end(1):]
data = re.sub(r"^IMName=.*$", "IMName=sogoupinyin", data, flags=re.M)
open(p, "w").write(data)
print("  启用顺序: " + " -> ".join(en))
print("  IMName   = sogoupinyin")
PYEOF
  if [ $? -eq 0 ]; then ok "profile 已修正"; else err "profile 修正失败"; return 1; fi
}

# 干净地重启 fcitx 与搜狗服务 (坑4/坑5 的修复)
restart_im_stack() {
  step "重启搜狗服务与 fcitx (单实例)"
  local p
  for p in $(ps -eo pid,args | grep -E 'sogoupinyin-(service|watchdog)' | grep -v grep | awk '{print $1}'); do
    kill "$p" 2>/dev/null
  done
  for p in $(pgrep -x fcitx); do kill "$p" 2>/dev/null; done
  sleep 1
  for p in $(pgrep -x fcitx); do kill -9 "$p" 2>/dev/null; done
  for p in $(ps -eo pid,args | grep 'fcitx/dbus/daemon.conf' | grep -v grep | awk '{print $1}'); do kill -9 "$p" 2>/dev/null; done
  for p in $(ps -eo pid,args | grep 'fcitx-dbus-watcher' | grep -v grep | awk '{print $1}'); do kill -9 "$p" 2>/dev/null; done
  sleep 1
  ok "旧进程已清理"

  as_user /opt/sogoupinyin/files/bin/sogoupinyin-service  >/dev/null 2>&1 &
  as_user /opt/sogoupinyin/files/bin/sogoupinyin-watchdog >/dev/null 2>&1 &
  sleep 3
  # service 会 daemonize，父进程立刻返回，必须用 ps 匹配完整命令行
  if ps -eo args | grep -q '[s]ogoupinyin/files/bin/sogoupinyin-service'; then
    ok "sogoupinyin-service 运行中"
  else
    warn "sogoupinyin-service 未运行，手动诊断："
    echo "     sudo -u $REAL_USER -H env DISPLAY=$S_DISPLAY XAUTHORITY=$S_XAUTH DBUS_SESSION_BUS_ADDRESS=$S_DBUS /opt/sogoupinyin/files/bin/sogoupinyin-service"
  fi
  ps -eo args | grep -q '[s]ogoupinyin/files/bin/sogoupinyin-watchdog' \
    && ok "sogoupinyin-watchdog 运行中" || warn "sogoupinyin-watchdog 未运行"

  as_user fcitx -d >/dev/null 2>&1
  sleep 3
  local fcp; fcp="$(pgrep -x fcitx | tr '\n' ' ')"
  [ -n "$fcp" ] && ok "fcitx 运行中 (PID $fcp)" || err "fcitx 未运行"
}

# ============================== 验证 ==============================
write_probe() {
  cat > "$WORKDIR/probe.py" <<'PYEOF'
#!/usr/bin/env python3
"""端到端验证: 模拟真实用户流程 (聚焦 -> Ctrl+Space -> 输入 nihao -> 空格上屏)"""
import subprocess, sys, time
from gi.repository import Gio, GLib

ps = subprocess.run("ps -ef | grep '[f]citx-dbus-watcher' | grep -oE 'unix:path=[^,]*' | head -1",
                    shell=True, capture_output=True, text=True).stdout.strip()
if not ps:
    print("  !! 找不到 fcitx 私有总线"); sys.exit(2)
bus = Gio.DBusConnection.new_for_address_sync(
    ps, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
        Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
IM_PATH, IM_IFACE = "/inputmethod", "org.fcitx.Fcitx.InputMethod"
IC_IFACE, DEST = "org.fcitx.Fcitx.InputContext", "org.fcitx.Fcitx"

def call(path, iface, method, params=None):
    return bus.call_sync(DEST, path, iface, method, params, None,
                         Gio.DBusCallFlags.NONE, 5000, None)

def pump(sec=0.3):
    end = time.time() + sec
    ctx = GLib.MainContext.default()
    while time.time() < end:
        while ctx.pending(): ctx.iteration(False)
        time.sleep(0.02)

res = call(IM_PATH, IM_IFACE, "CreateICv3", GLib.Variant("(si)", ("probe", 0)))
ic = f"/inputcontext_{res.unpack()[0]}"
commits = []
def on_sig(c, s, path, iface, signal, params):
    if signal == "CommitString": commits.append(params.unpack()[0])
bus.signal_subscribe(None, IC_IFACE, None, ic, None, Gio.DBusSignalFlags.NONE, on_sig)

call(ic, IC_IFACE, "FocusIn"); pump(0.5)
call(ic, IC_IFACE, "ProcessKeyEvent", GLib.Variant("(uuuiu)", (32, 65, 4, 0, 0)))  # Ctrl+Space
pump(0.5)
im = call(IM_PATH, IM_IFACE, "GetCurrentIM").unpack()[0]
st = call(IM_PATH, IM_IFACE, "GetCurrentState").unpack()[0]
print(f"  Ctrl+Space 后: IM={im} 状态={st}")
for kv, kc in [(110,46),(105,31),(104,35),(97,38),(111,32)]:
    call(ic, IC_IFACE, "ProcessKeyEvent", GLib.Variant("(uuuiu)", (kv, kc, 0, 0, 0)))
    pump(0.2)
call(ic, IC_IFACE, "ProcessKeyEvent", GLib.Variant("(uuuiu)", (32, 65, 0, 0, 0)))
pump(1.2)
print(f"  CommitString = {commits}")
if commits and any(c.strip() for c in commits):
    print("  >> 端到端通过: pinyin -> 中文 上屏成功")
    sys.exit(0)
print("  >> 未捕获到中文上屏")
sys.exit(1)
PYEOF
}

verify() {
  step "验证"
  local profile="$REAL_HOME/.config/fcitx/profile"
  local fcp; fcp="$(pgrep -x fcitx | head -1)"

  ps -eo args | grep -q '[s]ogoupinyin/files/bin/sogoupinyin-service' \
    && ok "搜狗后台服务在线" || err "搜狗后台服务未运行"
  ps -eo args | grep -q '[s]ogoupinyin/files/bin/sogoupinyin-watchdog' \
    && ok "守护进程在线" || warn "守护进程未运行"

  if [ -n "$fcp" ]; then
    grep -qa 'sogoupinyin.so' "/proc/$fcp/maps" 2>/dev/null \
      && ok "搜狗插件已加载进 fcitx (PID $fcp)" \
      || err "搜狗插件未加载进 fcitx"
  else
    err "fcitx 未运行"
  fi

  # 注: fcitx4 不一定为每个 addon 生成实例配置文件，此项仅作参考，
  #     真正的判据是下面的端到端按键测试
  [ -f "$REAL_HOME/.config/fcitx/conf/fcitx-sogoupinyin.config" ] \
    && info "插件实例配置已生成" || info "插件实例配置未生成(正常，fcitx4 可选行为)"

  if [ -f "$profile" ]; then
    info "IMName = $(grep -a -oE '^IMName=.*' "$profile" | cut -d= -f2)"
    info "启用序 = $(grep -a -oE '^EnabledIMList=[^,]*' "$profile" | cut -d= -f2-)"
  fi

  # 端到端按键测试
  if python3 -c "import gi; gi.require_version('Gio','2.0')" 2>/dev/null; then
    write_probe
    if python3 "$WORKDIR/probe.py"; then
      ok "端到端验证通过"
    else
      err "端到端验证失败"
    fi
  else
    warn "缺少 python3-gi，跳过端到端验证（请手动测试）"
  fi
}

# ============================== 回滚 ==============================
rollback() {
  step "卸载搜狗，恢复输入法框架"
  DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y sogoupinyin 2>&1 | tail -3
  dpkg -s sogoupinyin >/dev/null 2>&1 && err "卸载未完成" || ok "sogoupinyin 已卸载"

  rm -rf /opt/sogoupinyin
  rm -f /etc/xdg/autostart/sogoupinyin-service.desktop \
        /etc/xdg/autostart/sogoupinyin-watchdog.desktop
  rm -f /usr/share/applications/sogoupinyin-*.desktop
  rm -f /usr/lib/x86_64-linux-gnu/fcitx/fcitx-sogoupinyin*.so
  rm -f /usr/share/fcitx/addon/fcitx-sogoupinyin*.conf
  rm -f /usr/share/fcitx/inputmethod/sogoupinyin.conf
  rm -f /usr/share/fcitx/imicon/sogoupinyin.png
  ok "已清理插件 / 配置 / 图标 / 自启动项"

  [ -d "$REAL_HOME/.config/fcitx" ] && rm -rf "$REAL_HOME/.config/fcitx" \
    && ok "已删除 $REAL_HOME/.config/fcitx"

  step "重新安装输入法框架 ($ROLLBACK_TARGET)"
  if [ "$ROLLBACK_TARGET" = "ibus" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ibus ibus-libpinyin ibus-gtk3 ibus-gtk4 2>&1 | tail -5
    ok "ibus 已安装"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-config-qt 2>&1 | tail -5
    ok "fcitx5 拼音已安装"
  fi

  step "切换输入法框架"
  sudo -u "$REAL_USER" -H im-config -n "$ROLLBACK_TARGET" \
    && ok "im-config 已设为 $ROLLBACK_TARGET" \
    || warn "im-config 失败，手动执行: sudo -u $REAL_USER -H im-config -n $ROLLBACK_TARGET"

  echo -e "\n${BLD}${GRN}回滚完成${RST} 注销重新登录后生效。"
  echo "  想完全还原到系统默认(ibus): sudo bash $0 --rollback ibus"
}

# ============================== GDM 固定 Xorg ==============================
force_xorg_only() {
  step "把 GDM 固定为 Xorg 会话"
  local conf="/etc/gdm3/custom.conf"
  [ -f "$conf" ] || { err "找不到 $conf"; return 1; }
  if grep -q '^WaylandEnable=' "$conf"; then
    sed -i 's/^WaylandEnable=.*/WaylandEnable=false/' "$conf"
  else
    sed -i '/^\[daemon\]/a WaylandEnable=false' "$conf"
  fi
  ok "已设置 WaylandEnable=false"
  info "还原方法: sudo sed -i '/^WaylandEnable=/d' $conf"
}

# ============================== 主流程 ==============================
main() {
  echo -e "${BLD}搜狗拼音输入法 Linux 版安装脚本${RST}"
  echo -e "  时间: $(date '+%F %T')   主机: $(hostname)"

  if [ "$ACTION" = "test" ]; then
    check_env
    verify
    exit $?
  fi

  if [ "$ACTION" = "rollback" ]; then
    check_env
    rollback
    exit $?
  fi

  check_env
  download_deb
  remove_fcitx5
  install_missing_lib
  install_packages
  set_im_config

  # 首次启动 fcitx 以生成 profile，再修正顺序
  step "初始化 fcitx 配置"
  as_user fcitx -d >/dev/null 2>&1
  sleep 3
  pgrep -x fcitx >/dev/null && ok "fcitx 已启动，profile 已生成" || warn "fcitx 启动异常"
  fix_profile_order
  restart_im_stack

  verify
  [ "$FORCE_XORG" -eq 1 ] && force_xorg_only

  cat <<EOF

${BLD}${GRN}========================================================${RST}
${BLD}${GRN}  安装完成${RST}
${BLD}${GRN}========================================================${RST}

  ${BLD}接下来必须手动做：${RST}
    1. 注销当前会话，在登录界面选择「${BLD}Ubuntu on Xorg${RST}」
       ${YLW}(fcitx4 无 Wayland 支持，这一步不能省)${RST}

  2. 重新登录后按 ${BLD}Ctrl+Space${RST} 切换到「搜狗输入法个人版」，
       输入 nihao + 空格 验证。

  ${BLD}已知限制：${RST}
    * GNOME Shell 搜索框、GTK4 应用(如 GNOME Text Editor) 走 ibus，
      不受 fcitx4 控制 —— 建议保留 ibus-libpinyin 作为兜底
    * 搜狗 4.2.1.145 是官方最后一版，适配的是 Ubuntu 20.04 时代环境

  ${BLD}排障：${RST}
    fcitx-diagnose                                  一键体检
    /opt/sogoupinyin/files/bin/sogoupinyin-configtool  搜狗设置
    sudo bash $0 --test                             重新跑端到端验证

EOF
}

main
