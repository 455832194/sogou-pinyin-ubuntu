# 搜狗拼音输入法 Linux 版 · Ubuntu 一键安装

[![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%20~%2024.04-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.desktop/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)

> **⚠️ 搜狗 Linux 版是 fcitx4 插件，只能在 Xorg (X11) 会话下使用。**
> fcitx4 没有任何 Wayland 原生支持，官方也不提供 fcitx5 版本。
> 安装后**必须注销并改选「Ubuntu on Xorg」**，否则输入法无法工作。

在 Ubuntu / Debian 系上安装搜狗拼音输入法 Linux 版（fcitx4 插件），
并自动修复官方安装包在现代 Ubuntu 上的两个致命问题。

---

## 快速开始

```bash
# 1. 下载并安装
git clone https://github.com/455832194/sogou-pinyin-ubuntu.git
cd sogou-pinyin-ubuntu
sudo bash sogou-install-ubuntu.sh

# 2. 注销，在登录界面选择「Ubuntu on Xorg」(不是 Wayland)

# 3. 重新登录后按 Ctrl+Space 切到「搜狗输入法个人版」，输入 nihao + 空格
```

或者不 clone，直接跑：

```bash
curl -fsSL https://raw.githubusercontent.com/455832194/sogou-pinyin-ubuntu/main/sogou-install-ubuntu.sh \
  | sudo bash
```

---

## 命令行参数

| 参数 | 说明 |
|---|---|
| *(无)* | 完整安装（下载 → 装依赖 → 装搜狗 → 修配置 → 重启 → 验证） |
| `--test` | 只跑验证，**无需 root**，用于体检现有安装 |
| `--xorg-only` | 安装后顺便把 GDM 固定为只提供 Xorg 会话 |
| `--url <URL>` | 指定安装包下载地址（离线/镜像场景） |
| `--rollback` | 卸载搜狗，恢复 fcitx5（原生支持 Wayland） |
| `--rollback=ibus` | 卸载搜狗，恢复系统默认 ibus |

---

## 官方安装包在现代 Ubuntu 上的两个致命问题

这是本脚本存在的全部理由。装完搜狗后"完全没反应"，几乎都是下面两条导致的。

### 问题 1：官方 postinst 自己把 RPATH 弄断了

搜狗 deb 的 `postinst` 在 Ubuntu 分支上执行：

```sh
mv /opt/sogoupinyin/files/lib/qt5  /opt/sogoupinyin/files/lib/qt5.bak
```

它的本意是让搜狗改用系统 Qt5（避免 2018 年的旧 Qt5 与新系统冲突）。
但搜狗所有二进制的 `RPATH` 是：

```
$ORIGIN/../lib : $ORIGIN/../lib/qt5/lib
```

第二段路径被改名后失效了。而 `libgsettings-qt.so.1` **只存在于被改名的 `qt5.bak` 里** ——
`dpkg -S` 会确认 Ubuntu 官方软件源并不提供这个库（只有 `sogoupinyin` 自己拥有它）。

于是形成一条死链：

```
libgsettings-qt.so.1 找不到
   └─> sogoupinyin-service 起不来
          └─> fcitx-sogoupinyin.so 插件加载失败（libSogouIme.so 同样需要这个库）
                 └─> ~/.config/fcitx/conf/fcitx-sogoupinyin.config 从未生成
                        └─> 输入法毫无反应
```

**修复**：安装 Ubuntu 官方包 `libgsettings-qt1`（正好提供 `libgsettings-qt.so.1`）。
系统 Qt5 5.15 继续生效，`postinst` 的原始意图也保住了 —— 不需要改动搜狗包里的任何文件。

### 问题 2：fcitx4 的 `imes[0]` 约定导致搜狗永远选不中

即使库补齐了，插件能加载了，按 Ctrl+Space 仍然切不到搜狗。
根因在 fcitx4 源码 `src/lib/fcitx/ime.c`：

```c
int globalIndex = FcitxInstanceGetIMIndexByName(instance, instance->globalIMName);
if (globalIndex <= 0) {                       // ← 索引 0 被当作"无效"
    FcitxIM *im = fcitx_array_eltptr(&instance->imes, 1);
    fcitx_utils_string_swap(&instance->globalIMName, im->uniqueName);
    globalIndex = 1;
}
```

fcitx4 约定 `imes[0]` 必须是**键盘布局**（充当"英文态 / 无输入法"的占位符），
真正的输入法从 index 1 开始。而 `EnabledIMList` 的第一项若恰好是搜狗，
它就占了 index 0 → 被判为无效 → 永远回退到 index 1 的 `fcitx-keyboard-cn`。
更糟的是 fcitx 会把这个回退值写回 `globalIMName` 并保存进 profile，
形成**自我强化的死循环**，重启也救不回来。

**修复**：把 `fcitx-keyboard-us` 提到 `EnabledIMList` 首位，让搜狗落到 index ≥ 1。

### 另外三个容易踩的坑

| 坑 | 现象 | 处理 |
|---|---|---|
| `sudo` 改写 `$HOME` | `im-config` 和 fcitx 配置写到 `/root` 而不是当前用户 | 用 `$SUDO_USER` 反查真实 HOME / UID / session bus |
| 旧实例未退干净 | 新 fcitx 启动报 `DBus Service Already Exists` 后**静默退出** | 重启前杀掉 fcitx 主进程 + 它的私有 dbus-daemon + dbus-watcher |
| service 会 daemonize | 父进程立刻返回 0，用 `pgrep` 判断会误判"没起来" | 改用 `ps` 匹配完整命令行判断 |

完整根因分析见 [`docs/troubleshooting.md`](docs/troubleshooting.md)。

---

## 验证

```bash
sudo bash sogou-install-ubuntu.sh --test
```

这不是简单的"看进程活着没有"，而是**端到端模拟真实用户流程**：

1. 连上 fcitx 的私有 DBus 总线
2. 创建一个输入上下文（相当于一个 GTK 应用），发送 `FocusIn`
3. 模拟按下 `Ctrl+Space`
4. 逐个发送 `n` `i` `h` `a` `o` 的按键事件
5. 发送空格，捕获 `CommitString` 信号

输出示例：

```
  Ctrl+Space 后: IM=sogoupinyin 状态=2
  CommitString = ['你好']
  >> 端到端通过: pinyin -> 中文 上屏成功
```

只要 `CommitString` 里有 `你好`，就说明从按键到引擎到上屏的整条链路都是通的。

---

## 兼容性

| 项目 | 状态 |
|---|---|
| Ubuntu | 20.04 / 22.04 / 24.04 ✅（Debian 系一般可用） |
| 架构 | amd64 ✅（搜狗另提供 arm64 / loongarch64，需自行选包） |
| 桌面环境 | GNOME / KDE / XFCE 等 X11 桌面 ✅ |
| 会话类型 | **Xorg (X11) ✅ / Wayland ❌** |
| 搜狗版本 | 4.2.1.145（官方 Linux 最后一版） |

### 已知限制

- **GNOME Shell 搜索框**、**GTK4 / libadwaita 应用**（如 GNOME Text Editor）
  始终走 ibus，不受 fcitx4 控制 —— 这与本脚本无关，是 fcitx4 的固有限制。
  建议保留 `ibus-libpinyin` 作为这部分场景的兜底。
- 搜狗 4.2.1.145 是官方最后一版，适配的是 Ubuntu 20.04 时代的环境，
  个别云输入 / 皮肤功能可能因服务端调整而失效（不影响基本输入）。
- 需要在 Xorg 会话下使用；fcitx4 无 Wayland 原生支持。

---

## 卸载 / 回滚

```bash
sudo bash sogou-install-ubuntu.sh --rollback        # 恢复 fcitx5（原生支持 Wayland）
sudo bash sogou-install-ubuntu.sh --rollback=ibus   # 恢复系统默认 ibus
```

回滚会卸载 `sogoupinyin`、清理 `/opt/sogoupinyin` 与残留的插件/配置/图标/自启动项，
并删除 `~/.config/fcitx`。

---

## 常见问题

**Q：装完按 Ctrl+Space 没反应？**
A：先确认当前是 Xorg 会话（右上角 → 会话下拉）。Wayland 下 fcitx4 无法工作。

**Q：终端能打中文，GUI 应用不行？**
A：检查 `echo $GTK_IM_MODULE`，应为 `fcitx`。若为空，说明 `im-config` 没生效，
重新执行 `im-config -n fcitx` 后注销。

**Q：GNOME 搜索框打不出中文？**
A：正常。GNOME Shell 直连 ibus，搜狗管不到。`ibus-libpinyin` 可兜底。

**Q：想固定用 Xorg，不想每次登录都选？**
A：`sudo bash sogou-install-ubuntu.sh --xorg-only`
（等价于在 `/etc/gdm3/custom.conf` 的 `[daemon]` 段加 `WaylandEnable=false`）

---

## 免责声明

本项目为**非官方**的第三方安装辅助脚本，与搜狗 / 腾讯公司无任何关联。
搜狗拼音输入法为搜狗公司的产品，其许可条款请以官方发布渠道为准。
本脚本仅在你的机器上自动化执行官方安装包并修复已知兼容问题。

## License

[MIT](LICENSE) © 2026 lxm
