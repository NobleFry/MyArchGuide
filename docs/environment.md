# Arch Linux 系统基本配置

> 索引：[项目说明](../README.md) · [虚拟机与显卡直通](virtualization.md) · [安装脚本](../scripts/)

## 1 安装显卡驱动

> 所有 AMD 显卡建议使用开源驱动，英伟达显卡建议使用闭源驱动

### Intel 核芯显卡

```bash
sudo pacman -S mesa lib32-mesa vulkan-intel lib32-vulkan-intel
```

### NVIDIA 独立显卡

```bash
sudo pacman -S nvidia-dkms nvidia-settings lib32-nvidia-utils # 必须安装
```

### AMD 显卡

本人无amd显卡暂不囊括。

## 2 使用dankinstall安装niri和dms

```bash
curl -fsSL <https://install.danklinux.com> | sh
```

## 3 安装并配置zsh

```bash
sudo pacman -S zsh zsh-autosuggestions zsh-syntax-highlighting
nvim ~/.zshrc
```

加入以下内容:

```bash
# ==============================================================================
# Zsh Configuration (Arch Linux + Amber Retro)
# ==============================================================================

# 1. 历史记录配置
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_ALL_DUPS  # 忽略重复命令

# 2. 补全系统配置
autoload -Uz compinit
compinit

zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*:descriptions' format '%B%F{214}--- %d ---%f%b'

# 3. 键绑定 (引入 terminfo 以兼容各大终端)
bindkey -e
zmodload zsh/terminfo

# 上下方向键：根据已输入前缀搜索历史
if [[ -n "$terminfo[kcuu1]" ]]; then
    bindkey "$terminfo[kcuu1]" history-search-backward
    bindkey "$terminfo[kcud1]" history-search-forward
fi
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward

# 4. 自动推导插件 (zsh-autosuggestions)
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_COMPLETION_IGNORE=""
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=240'

source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh

# 右方向键 (→) 逐词采纳，同时恢复普通右移光标功能
if [[ -n "$terminfo[kcuf1]" ]]; then
    bindkey "$terminfo[kcuf1]" forward-char
fi
bindkey '^[[C' forward-char
bindkey '^[OC' forward-char

# 快捷键：Ctrl+F 或 Ctrl+E 采纳整行建议
bindkey '^F' autosuggest-accept
bindkey '^E' autosuggest-accept

# 5. 语法高亮插件 (zsh-syntax-highlighting)
typeset -A ZSH_HIGHLIGHT_STYLES
ZSH_HIGHLIGHT_STYLES[command]='fg=208,bold'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=208,bold'
ZSH_HIGHLIGHT_STYLES[alias]='fg=208,bold'
ZSH_HIGHLIGHT_STYLES[path]='fg=179,underline'
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=160,bold'

source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# 6. 提示符 PROMPT
PROMPT='%B%F{208}%n%f%F{240}@%f%F{179}%m%f %F{208}%~%f%b %(?.%F{214}.%F{160})%#%f '

export EDITOR="nvim"
```

## 4 安装aur助手 paru

```bash
mkdir ~/Git
cd ~/Git
git clone <https://aur.archlinux.org/paru.git>
cd paru
makepkg -si
```

## 5 安装常用应用与xan内核

```bash
sudo pacman -S steam
paru -S linux-xanmod linux-xanmod-headers
paru -S clash-party-bin
```

> KVM 虚拟机的安装与配置（含 Windows 虚拟机、VirtIO-FS 文件共享、独显直通、Looking-glass、VFIO 解绑）已拆分到 [虚拟机与显卡直通](virtualization.md)。

## 6 配置局域网代理

当机器只能通过局域网内的代理（Clash、Mihomo、Squid 等）访问外网时，先导出代理环境变量，再执行 `pacman`、`paru`、`git` 等联网命令。`HTTP/HTTPS` 代理默认端口常见为 `7890`，`SOCKS5` 默认 `7891`，请按实际局域网 IP 与端口替换。

```bash
export http_proxy="http://192.168.1.10:7890"
export https_proxy="$http_proxy"
export ftp_proxy="$http_proxy"
export all_proxy="$http_proxy"
export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy" FTP_PROXY="$http_proxy" ALL_PROXY="$http_proxy"
export no_proxy="localhost,127.0.0.1,::1" NO_PROXY="$no_proxy"
```

- `pacman`/`paru` 走 `http_proxy`/`https_proxy`，升级与装包前先导出即可。
- 使用 SOCKS5 时把 URL 换成 `socks5://192.168.1.10:7891`。
- `no_proxy` 放行本地回环地址，避免本机服务也被代理。
- 只在当前终端生效用上面的 `export`；要持久化可写入 `/etc/environment`（系统级）或 `~/.zshrc`（当前用户）。
- 安装阶段 [install.sh](../scripts/install.sh) 会提示输入局域网 IP 与端口，并在当前终端与 `arch-chroot` 内自动导出，无需手动设置。
