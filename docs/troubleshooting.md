# 根因分析与排障手册

本文记录搜狗拼音输入法 Linux 版在现代 Ubuntu 上的完整根因分析，
以及实战中用到的排查手段。安装脚本 `sogou-install-ubuntu.sh` 已自动处理全部修复动作。

---

## 一、问题 1：`libgsettings-qt.so.1` 缺失

### 现象

```
$ /opt/sogoupinyin/files/bin/sogoupinyin-service
/opt/sogoupinyin/files/bin/sogoupinyin-service: error while loading shared libraries:
libgsettings-qt.so.1: cannot open shared object file: No such file or directory
```

fcitx 插件同样加载失败：

```
$ grep sogou /proc/$(pgrep -x fcitx)/maps
（空）
```

### 根因

搜狗 deb 的 `postinst` 在检测到 Ubuntu 时执行：

```sh
if [ "$UOS" ] || [ "$DEEPIN" ] || [ "$UBUNTU" ] || [ "$KYLINV10" ]; then
    if [ -d /opt/sogoupinyin/files/lib/qt5 ] ; then
        mv /opt/sogoupinyin/files/lib/qt5 /opt/sogoupinyin/files/lib/qt5.bak
    fi
    ...
fi
```

设计意图是让搜狗使用系统 Qt5，避免捆绑的 2018 年 Qt5（5.11）与新系统冲突。

但搜狗所有二进制的 `RPATH` 写死了两段路径：

```sh
$ readelf -d /opt/sogoupinyin/files/bin/sogoupinyin-service | grep -i path
 0x000000000000000f (RPATH)  Library rpath: [$ORIGIN/../lib:$ORIGIN/../lib/qt5/lib]
```

改名后第二段 `$ORIGIN/../lib/qt5/lib` 失效。而 `libgsettings-qt.so.1`
**只存在于被改名的 `qt5.bak` 目录里**：

```sh
$ dpkg -S libgsettings-qt.so.1
sogoupinyin: /opt/sogoupinyin/files/lib/qt5/lib/libgsettings-qt.so.1
```

注意 dpkg 记录的是**打包时的原路径**，运行时那个目录已不存在。
Ubuntu 官方软件源也不提供这个库（`ldconfig -p | grep gsettings` 为空）。

### 影响面

`libgsettings-qt.so.1` 是 `libSogouIme.so` 的 `NEEDED` 项之一，
所以 fcitx 的搜狗插件（`fcitx-sogoupinyin.so`）在 `dlopen` 它时同样失败。

### 修复

```sh
sudo apt install libgsettings-qt1
```

Ubuntu 官方包 `libgsettings-qt1` 提供 `/usr/lib/x86_64-linux-gnu/libgsettings-qt.so.1`，
依赖 `libglib2.0-0t64` + `libqt5core5a`（系统自带）。
系统 Qt5 继续生效，搜狗包内文件零改动。

---

## 二、问题 2：fcitx4 的 `imes[0]` 约定

### 现象

库补齐、插件加载成功后，按 Ctrl+Space 仍然切不到搜狗；
`fcitx-remote -m sogoupinyin` 返回的却是 `fcitx-keyboard-cn`。

### 根因

fcitx4 源码 `src/lib/fcitx/ime.c` 中 `FcitxInstanceGetIM()`：

```c
int globalIndex = FcitxInstanceGetIMIndexByName(instance, instance->globalIMName);
/* global index is not valid, that's why we need to fix it. */
if (globalIndex <= 0) {
    UT_array *ime = &instance->imes;
    FcitxIM *im = fcitx_array_eltptr(ime, 1);   // ← 回退到 im[1]
    if (im) {
        globalIndex = 1;
    }
}
```

而 `instance->imes` 数组的填充顺序，就是 profile 里 `EnabledIMList` 中 `:True` 项的顺序
（见 `FcitxInstanceUpdateIMList()` 与 `FilterIMList()`）。

fcitx4 的设计约定：**`imes[0]` 是键盘布局**，代表"英文态 / 无输入法"占位符，
真正的输入法从 index 1 开始。源码里多处印证这一点：

```c
/* FcitxInstanceSwitchIMInternal */
if (skipZero && instance->iIMIndex == 0) {
    instance->iIMIndex = 1;
}

/* FcitxInstanceGetIM */
if (ic && ic->state != IS_ACTIVE) {
    targetIMIndex = 0;          // 未激活态 → index 0（键盘布局）
}
```

当 `EnabledIMList` 第一项是搜狗时，搜狗占据 index 0 →
`globalIndex = 0` → 命中 `globalIndex <= 0` → 回退到 `im[1]`（`fcitx-keyboard-cn`）。

**更糟的是**这个回退会写回全局状态：

```c
/* FcitxInstanceUpdateCurrentIM */
if (globalIndex <= 0) {
    FcitxIM *im = fcitx_array_eltptr(ime, 1);
    if (im) {
        fcitx_utils_string_swap(&instance->globalIMName, im->uniqueName);
        globalIndex = 1;
        forceSwtich = true;
        updateGlobal = true;      // ← 会触发 FcitxProfileSave()
    }
}
```

`globalIMName` 被改写成 `fcitx-keyboard-cn` 并保存进 profile 的 `IMName`，
于是**每次重启都重复这个过程**，形成自我强化的死循环。

### 修复

让 `EnabledIMList` 首位是一个键盘布局：

```
EnabledIMList=fcitx-keyboard-us:True,fcitx-keyboard-cn:True,sogoupinyin:True,...
```

这样搜狗落在 index 2，`globalIndex = 2 > 0`，不再触发回退。

### 手动验证

```sh
grep -a '^IMName=' ~/.config/fcitx/profile
# 期望: IMName=sogoupinyin

grep -a -oE '^EnabledIMList=[^,]*' ~/.config/fcitx/profile
# 期望: EnabledIMList=fcitx-keyboard-us:True
```

---

## 三、另外三个坑

### 3.1 `sudo` 改写 `$HOME`

`sudo` 会把 `$HOME` 设为 `/root`。若在 `sudo` 环境里直接调 `im-config`、
或用 `$HOME` 拼 fcitx 配置路径，配置会写到 `/root` 下，用户实际登录时完全读不到。

**处理**：用 `$SUDO_USER` 反查真实用户的 HOME / UID：

```sh
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-root}")}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
UID_REAL="$(id -u "$REAL_USER")"
```

**注意**：会话总线路径也必须用真实用户的 UID：

```sh
# 错误（root 下执行）
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"   # → /run/user/0/bus

# 正确
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_REAL/bus"  # → /run/user/1000/bus
```

用错会导致搜狗 service **静默退出（返回码 0）**，看起来像"没起来"。

### 3.2 `DBus Service Already Exists`

fcitx4 的 ipc/dbus 前端会自建一个私有 dbus-daemon（配置在
`/usr/share/fcitx/dbus/daemon.conf`）。旧实例没退干净时，新实例启动会：

```
(WARN) DBus Service Already Exists
(ERROR) Exiting.
```

然后**直接退出**，不报错到终端。

**处理**：重启前把这三类进程全杀干净：

```sh
pkill -x fcitx
ps -eo pid,args | grep 'fcitx/dbus/daemon.conf' | grep -v grep | awk '{print $1}' | xargs -r kill -9
ps -eo pid,args | grep 'fcitx-dbus-watcher'    | grep -v grep | awk '{print $1}' | xargs -r kill -9
```

### 3.3 service 会 daemonize

`sogoupinyin-service` 启动后父进程立即 fork 并返回 0。
用 `pgrep -f 'sogoupinyin-service'` 判断会误判为"没起来"。

**处理**：用 `ps` 匹配完整命令行：

```sh
ps -eo args | grep -q '[s]ogoupinyin/files/bin/sogoupinyin-service'
```

---

## 四、实战排查手段

### 4.1 端到端按键测试（最可靠）

不要只看"进程活着没有"。fcitx4 的私有 DBus 总线可以直接创建输入上下文并模拟按键：

```sh
# 找到 fcitx 的私有总线地址
ps -ef | grep '[f]citx-dbus-watcher' | grep -oE 'unix:path=[^,]*' | head -1
# → unix:path=/tmp/dbus-XXXXXX
```

用 PyGObject 单连接完成全过程（**必须单连接** —— fcitx 会校验调用方与
创建 IC 的连接一致，否则报 `Invalid sender`）：

```python
from gi.repository import Gio, GLib
bus = Gio.DBusConnection.new_for_address_sync(addr, flags, None, None)

# 1. 创建 IC
res = bus.call_sync("org.fcitx.Fcitx", "/inputmethod",
                    "org.fcitx.Fcitx.InputMethod", "CreateICv3",
                    GLib.Variant("(si)", ("probe", 0)), None,
                    Gio.DBusCallFlags.NONE, 5000, None)
ic = f"/inputcontext_{res.unpack()[0]}"

# 2. 订阅信号（注意要驱动主循环让回调派发）
bus.signal_subscribe(None, "org.fcitx.Fcitx.InputContext", None, ic, None,
                     Gio.DBusSignalFlags.NONE, on_signal)

# 3. FocusIn → Ctrl+Space → n i h a o → 空格
#    ProcessKeyEvent(keyval, keycode, state, type, time)
#    keyval: n=110 i=105 h=104 a=97 o=111 space=32
#    space 的 keycode=65, Ctrl+Space 的 state=4 (ControlMask)
```

捕获到 `CommitString = ['你好']` 就说明整条链路（按键 → fcitx → 搜狗引擎 → 上屏）全通。
完整实现见仓库根目录的 `sogou-install-ubuntu.sh --test`。

### 4.2 fcitx 私有总线上的真实接口

会话总线上的 `org.fcitx.Fcitx` 是个代理，转发到私有总线。
**在会话总线上 introspect 只会看到一堆通用 Properties 方法**，看不到真实接口。
要查真实接口，直接连私有总线：

```sh
PRIV=$(ps -ef | grep '[f]citx-dbus-watcher' | grep -oE 'unix:path=[^,]*' | head -1)
export DBUS_SESSION_BUS_ADDRESS="$PRIV"
dbus-send --session --print-reply --dest=org.fcitx.Fcitx /inputmethod \
          org.freedesktop.DBus.Introspectable.Introspect | sed 's/\\n/\n/g' \
          | grep -oE 'method name="[^"]*"'
```

有用的方法：`GetCurrentIM`、`GetCurrentState`、`SetCurrentIM`、`ActivateIM`、
`CreateICv3`、`ReloadConfig`、`ConfigureIM`。

### 4.3 日志位置

| 位置 | 内容 |
|---|---|
| `~/.config/fcitx/log/` | fcitx 自身日志（addon 加载、ABI 错误等） |
| `~/.config/sogoupinyin/log/sogou.log` | 搜狗服务日志 |
| `~/.config/sogoupinyin/log/fcitx.log` | 搜狗插件侧日志 |
| `journalctl --user -b \| grep -iE 'fcitx\|sogou'` | 系统日志 |

搜狗日志里的 `com.deepin.daemon.Appearance`、`/etc/deepin-version` 相关 ERROR
是 **Deepin 专属探测**，Ubuntu 上属正常噪音，可忽略。

### 4.4 插件是否真的加载了

```sh
grep -o 'sogou[^ ]*' /proc/$(pgrep -x fcitx | head -1)/maps | sort -u
```

期望看到 `sogoupinyin.so`（外加 `sogoupinyinhdm.so` / `sogoupinyinhxm.so` 手写输入相关）。

> ⚠️ `fcitx-sogoupinyinhxm ABI Version Error` 是 fcitx4 对手写插件的 ABI 检查报错，
> 只影响手写输入功能，不影响拼音输入本身。

### 4.5 fcitx 状态速查

```sh
fcitx-remote              # 0=关闭 1=未激活(英文态) 2=已激活(中文态)
fcitx-remote -m sogoupinyin   # 该 IM 对应的 addon 名
fcitx -r                  # 重载配置
fcitx-diagnose            # 一键体检
```

---

## 五、症状 → 原因速查表

| 症状 | 最可能的原因 | 处理 |
|---|---|---|
| 按 Ctrl+Space 无任何反应 | `libgsettings-qt.so.1` 缺失 | 装 `libgsettings-qt1` |
| 切输入法总是切到 `fcitx-keyboard-cn` | `imes[0]` 约定 | 调整 `EnabledIMList` 顺序 |
| profile 里 `IMName` 自己变回 `fcitx-keyboard-cn` | 同上，fcitx 回退后写回 | 同上 |
| 终端能打中文，GUI 不能 | `GTK_IM_MODULE` 没设成 fcitx | `im-config -n fcitx` 后注销 |
| GNOME 搜索框打不出中文 | Shell 直连 ibus，与 fcitx 无关 | 正常现象，用 `ibus-libpinyin` 兜底 |
| 一切正常但没反应 | 当前是 Wayland 会话 | 注销改选「Ubuntu on Xorg」 |
| 插件没加载 | `ldd` 有 not found | 跑脚本自动复查全部依赖 |
| fcitx 启动后立刻消失 | `DBus Service Already Exists` | 清干净私有 dbus 再启动 |

---

## 六、为什么 Wayland 下不行

```sh
$ ls /usr/lib/x86_64-linux-gnu/fcitx/ | grep -i wayland
（空 —— fcitx4 没有任何 Wayland 模块）

$ ldd /usr/lib/x86_64-linux-gnu/fcitx/fcitx-classic-ui.so | grep -E 'libX11|libwayland'
	libX11.so    => /lib/x86_64-linux-gnu/libX11.so
	libxcb.so    => /lib/x86_64-linux-gnu/libxcb.so
（候选窗 UI 是纯 X11 实现）
```

fcitx4 整个框架诞生于 Wayland 之前，搜狗官方也只有 fcitx4 插件，
没有 fcitx5 版本。Wayland 会话下它只能借道 XWayland：

- GTK3 / Qt5 应用：IM 前端走 DBus，打字本身可用，
  但候选窗是 XWayland 里的 X11 窗口，跟不上 Wayland 客户端的光标位置
- GTK4 / libadwaita 应用、GNOME Shell 搜索框：**根本不支持** XIM 和自定义 IM 模块，
  无论什么会话都走 ibus

所以完整可用的组合只有 **Xorg + fcitx4**。

需要原生 Wayland 的话请用 `--rollback` 换回 fcitx5（`fcitx5-chinese-addons`，
自带拼音 + 云拼音），代价是失去搜狗的皮肤、词库等功能。
