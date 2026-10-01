#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
switch_gui.py — switch 脚本的 tkinter 图形界面前端

权限模型（Arch / KDE Plasma / Wayland 均适用）
==============================================
GUI 进程**始终以普通用户身份运行**，绝不整体提权、绝不重启：

    * 点击任一切换按钮并确认后，程序通过 ``pkexec``（系统 Polkit）弹出
      密码验证窗口（由 KDE 等桌面的 polkit 代理提供）；若会话中尚未运行
      任何认证代理（niri 等合成器常见），会自动拉起
      ``polkit-kde-authentication-agent-1`` 并自动重试一次；
    * 密码仅对本次操作有效，原 ``switch`` 脚本以 root 身份在一个**纯命令行
      子进程**中执行（不接触图形服务，因此没有 root 连不上 X/Wayland 的
      问题）；
    * 子进程的实时日志以彩色方式回流到本窗口。

直接以普通用户运行即可（**不要加 sudo**——Wayland 下 root 无法连接显示）：

    ./switch_gui.py
"""

import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import types
from pathlib import Path

import tkinter as tk
import tkinter.font as tkfont
from tkinter import ttk, messagebox, scrolledtext

# 定位无扩展名的核心脚本 switch：
# 1) 开发模式：与本文件同目录；2) pacman 安装：/usr/lib/nvidia-switch/switch
_SWITCH_CANDIDATES = (
    Path(__file__).resolve().parent / "switch",
    Path("/usr/lib/nvidia-switch/switch"),
    Path("/usr/local/lib/nvidia-switch/switch"),
)
SWITCH_PATH = next((p for p in _SWITCH_CANDIDATES if p.exists()),
                   _SWITCH_CANDIDATES[0])

# libvirt 虚拟机：域名与连接 URI（显式指定 system 实例，与 sudo virsh 行为一致）
VM_DOMAIN = "win11"
LIBVIRT_URI = "qemu:///system"

# 界面缩放档位与配置文件（XWayland 下 Tk 不会跟随 Wayland 缩放，需自行管理）
SCALE_CHOICES = (1.0, 1.25, 1.5, 1.75, 2.0)
_CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME",
                                  str(Path.home() / ".config"))) / "switch-gui"
_CONFIG_FILE = _CONFIG_DIR / "config.json"

# Tk 全部命名字体：缩放这些即可联动几乎所有 ttk/tk 控件
_NAMED_FONTS = (
    "TkDefaultFont", "TkTextFont", "TkFixedFont", "TkMenuFont",
    "TkHeadingFont", "TkCaptionFont", "TkSmallCaptionFont",
    "TkIconFont", "TkTooltipFont",
)

# ANSI 颜色码 -> 日志区 Text tag
_ANSI_COLORS = {
    "31": "error", "91": "error",       # 红
    "32": "info", "92": "info",        # 绿
    "33": "warning", "93": "warning",  # 黄
    "36": "cyan", "96": "cyan",        # 青
}
_ANSI_RE = re.compile(r"\033\[(\d+)m")

# 会话里没有 Polkit 图形认证代理时（niri 等合成器常见），按此顺序拉起一个
_POLKIT_AGENT_PATHS = (
    "/usr/lib/polkit-kde-authentication-agent-1",
    "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1",
    "/usr/lib/lxpolkit/lxpolkit",
)


# ================= 加载核心脚本 switch（仅取配置常量与颜色） =================
def load_switch_module():
    """
    加载同目录下无 .py 后缀的 switch 脚本。

    仅用于读取 PCI_DEVICES / TARGET_HUGEPAGES / Colors 等常量；所有实际
    root 操作都在 pkexec 子进程中执行，GUI 进程不直接调用其业务函数。
    模块名不为 "__main__"，因此 switch 自带的 root 检查与交互菜单不会触发。
    """
    if not SWITCH_PATH.exists():
        raise FileNotFoundError(f"找不到核心脚本: {SWITCH_PATH}")
    module = types.ModuleType("switch_core")
    module.__file__ = str(SWITCH_PATH)
    module.__package__ = ""
    source = SWITCH_PATH.read_text(encoding="utf-8")
    exec(compile(source, str(SWITCH_PATH), "exec"), module.__dict__)
    sys.modules["switch_core"] = module
    return module


def parse_ansi_line(line):
    """把一行含 ANSI 颜色码的文本拆成 [(tags_tuple, text), ...]。"""
    segments = []
    color = None
    bold = False
    parts = _ANSI_RE.split(line)
    # split 结果：[文本, 色码, 文本, 色码, 文本, ...]
    for index, part in enumerate(parts):
        if index % 2 == 0:  # 普通文本
            if part:
                tags = ()
                if bold:
                    tags += ("bold",)
                if color:
                    tags += (color,)
                segments.append((tags, part))
        else:  # ANSI 颜色码
            if part == "0":       # RESET
                color, bold = None, False
            elif part == "1":     # BOLD
                bold = True
            elif part in _ANSI_COLORS:
                color = _ANSI_COLORS[part]
    return segments


def strip_ansi(text):
    """去除 ANSI 转义序列，用于关键字判断。"""
    return _ANSI_RE.sub("", text)


def is_root():
    return hasattr(os, "geteuid") and os.geteuid() == 0


def python_interpreter():
    """提权子进程使用的 Python 解释器（优先系统解释器，root 所有、路径安全）。"""
    for candidate in ("/usr/bin/python3", sys.executable):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return "python3"


# ================= 界面缩放：配置持久化 + niri 输出缩放探测 =================
def snap_scale(factor):
    """把任意缩放值吸附到最近的可选档位。"""
    return min(SCALE_CHOICES, key=lambda choice: abs(choice - factor))


def load_saved_scale():
    """读取用户上次选择的缩放比例；无配置或非法时返回 None。"""
    try:
        data = json.loads(_CONFIG_FILE.read_text(encoding="utf-8"))
        factor = float(data.get("scale"))
        if 0.5 <= factor <= 4.0:
            return factor
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return None


def save_scale(factor):
    """保存缩放比例到用户配置目录。"""
    try:
        _CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        _CONFIG_FILE.write_text(
            json.dumps({"scale": factor}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8")
    except OSError:
        pass


def detect_session_scale():
    """
    推断会话当前的显示缩放作为首次运行的默认值：
    环境变量 QT_SCALE_FACTOR / GDK_SCALE → niri 输出 scale → 1.0。
    """
    for var in ("QT_SCALE_FACTOR", "GDK_SCALE"):
        try:
            value = float(os.environ.get(var, ""))
            if 0.5 <= value <= 4.0:
                return snap_scale(value)
        except ValueError:
            pass
    try:
        result = subprocess.run(
            ["niri", "msg", "--json", "outputs"],
            capture_output=True, text=True, timeout=1.5, check=False)
        if result.returncode == 0 and result.stdout.strip():
            data = json.loads(result.stdout)
            # niri 返回 {输出名: {…}}；兼容旧版/列表形式
            if isinstance(data, dict) and "outputs" in data:
                outputs = data["outputs"]
            elif isinstance(data, dict):
                outputs = list(data.values())
            else:
                outputs = data if isinstance(data, list) else []
            scales = []
            for out in outputs:
                if not isinstance(out, dict):
                    continue
                scale = out.get("scale")
                if scale is None and isinstance(out.get("logical"), dict):
                    scale = out["logical"].get("scale")  # niri ≥0.1.x 的字段位置
                if scale:
                    scales.append(float(scale))
            if scales:
                return snap_scale(max(scales))
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        pass
    return 1.0


def query_vm_state():
    """
    以当前用户只读查询虚拟机状态（libvirt 组经 polkit 允许只读访问）。
    返回小写状态字符串（running / shut off / paused …），查询失败返回 None。
    """
    if not shutil.which("virsh"):
        return None
    try:
        result = subprocess.run(
            ["virsh", "-c", LIBVIRT_URI, "domstate", VM_DOMAIN],
            capture_output=True, text=True, timeout=8, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip().lower() if result.returncode == 0 else None


# ================= Polkit 认证代理（niri 等合成器下不会自启，需要时再拉起） =================
def spawn_polkit_agent():
    """
    后台拉起一个 Polkit 图形认证代理并等待其注册到会话总线。

    返回启动成功的代理路径，找不到可执行文件时返回 None。
    采用“先尝试 pkexec、确认无代理再拉起”的策略，避免与桌面环境
    已有的代理（含 quickshell 等内嵌代理）重复注册。
    """
    for agent_path in _POLKIT_AGENT_PATHS:
        if os.path.isfile(agent_path) and os.access(agent_path, os.X_OK):
            try:
                # KDE 代理无参数时检测到会话状态会立刻退出，--replace 使其
                # 前台常驻并接管当前会话（本函数仅在 pkexec 确认无代理后调用，
                # 因此不会抢占已在正常工作的代理）
                args = [agent_path]
                if agent_path.endswith("polkit-kde-authentication-agent-1"):
                    args.append("--replace")
                subprocess.Popen(
                    args,
                    start_new_session=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                time.sleep(1.5)  # 给代理一点时间注册到会话总线
                return agent_path
            except OSError:
                continue
    return None


# ================= 主窗口 =================
class SwitchGUI:
    POLL_INTERVAL = 80       # 日志队列轮询间隔 (ms)
    MAX_LOG_LINES = 1200     # 日志区最大保留行数

    def __init__(self, root):
        self.root = root
        self.log_queue = queue.Queue()
        self.worker = None

        # 缩放：优先用户已保存的选择，否则尝试跟随 niri 会话缩放
        saved = load_saved_scale()
        self.scale_factor = saved if saved is not None else detect_session_scale()
        # 记录 1.0 基准下的命名字体字号与所有需要按比例重放的像素参数
        self._base_font_sizes = {
            name: tkfont.nametofont(name).actual("size") for name in _NAMED_FONTS}
        self._pack_specs = []    # (widget, 基准 pack 参数)
        self._padding_specs = [] # (widget, 基准 padding)
        self._border_specs = []  # (widget, 基准 borderwidth)
        self.scale_combo = None

        # 仅读取 switch 的配置常量（PCI 设备列表、大页目标数、颜色码）
        self.switch = load_switch_module()

        self.hp_var = tk.BooleanVar(value=False)
        self.status_var = tk.StringVar(value="就绪")

        self._configure_style()
        self._build_ui()
        self._apply_scale(self.scale_factor, resize_window=True)
        self._print_banner()
        self._apply_action_state()

        self.root.after(self.POLL_INTERVAL, self._poll_queue)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ---------- 缩放辅助 ----------
    def s(self, value):
        """标量像素值按当前缩放取整（字体字号/padding/geometry 等像素量）。"""
        return int(round(value * self.scale_factor))

    def _spad(self, value):
        """padding/padx/pady 可能是 (h, v) 或 (l, t, r, b) 元组，逐元素缩放。"""
        if isinstance(value, (tuple, list)):
            return tuple(self.s(item) for item in value)
        return self.s(value)

    def _pack(self, widget, **kwargs):
        """pack 并登记基准参数，供切换缩放时 pack_configure 重放。"""
        self._pack_specs.append((widget, kwargs))
        scaled = {key: (self._spad(val) if key in ("padx", "pady", "ipadx", "ipady")
                        else val) for key, val in kwargs.items()}
        widget.pack(**scaled)

    def _register_padding(self, widget, padding):
        widget.configure(padding=self._spad(padding))
        self._padding_specs.append((widget, padding))

    # X 屏幕可用尺寸（niri 平铺时窗口会被放进工作区，尺寸必须留足余量）
    SCREEN_MARGIN_X = 48     # 左右/边框余量
    SCREEN_MARGIN_Y = 110    # 顶部 niri bar + 边框/间隙余量

    def _screen_size(self):
        self.root.update_idletasks()
        return self.root.winfo_screenwidth(), self.root.winfo_screenheight()

    def _fit_size(self, base_w, base_h):
        """期望尺寸按当前缩放计算后，再夹取到屏幕工作区内。"""
        screen_w, screen_h = self._screen_size()
        width = min(self.s(base_w), max(360, screen_w - self.SCREEN_MARGIN_X))
        height = min(self.s(base_h), max(320, screen_h - self.SCREEN_MARGIN_Y))
        return width, height

    def _apply_window_constraints(self, set_default=False):
        """统一设置窗口默认尺寸与最小尺寸，保证任何缩放下都不超出屏幕。"""
        screen_w, screen_h = self._screen_size()
        # 最小尺寸要足够小：niri 平铺时 X11 min-size 过大会把窗口顶出屏幕
        min_w = min(self.s(640), max(360, screen_w - self.SCREEN_MARGIN_X))
        min_h = min(self.s(420), max(300, screen_h - self.SCREEN_MARGIN_Y - 40))
        self.root.minsize(min_w, min_h)
        if set_default:
            width, height = self._fit_size(860, 680)
            self.root.geometry(f"{width}x{height}")

    def _apply_scale(self, factor, resize_window=False):
        """按 factor 重放所有像素量：命名字体、自定义样式、padding、边距、窗口。"""
        self.scale_factor = factor

        # 1) 命名字体（正值=磅，负值=像素，保持符号）
        for name, base_size in self._base_font_sizes.items():
            new_size = base_size * factor
            if base_size > 0:
                new_size = max(6, int(round(new_size)))
            else:
                new_size = min(-6, -int(round(abs(new_size))))
            tkfont.nametofont(name).configure(size=new_size)

        # 2) 自定义样式中的字号与 padding
        style = ttk.Style()
        style.configure("Title.TLabel", font=("Sans", self.s(16), "bold"))
        style.configure("Big.TButton", font=("Sans", self.s(11)), padding=self.s(8))
        style.configure("VFIO.TButton", font=("Sans", self.s(11), "bold"),
                        padding=self.s(10))
        style.configure("NV.TButton", font=("Sans", self.s(11), "bold"),
                        padding=self.s(10))
        style.configure("VM.TButton", font=("Sans", self.s(11), "bold"),
                        padding=self.s(10))

        # 3) 控件 padding / borderwidth / pack 边距
        for widget, padding in self._padding_specs:
            widget.configure(padding=self._spad(padding))
        for widget, border in self._border_specs:
            widget.configure(borderwidth=self.s(border))
        for widget, kwargs in self._pack_specs:
            scaled = {key: (self._spad(val) if key in ("padx", "pady", "ipadx", "ipady")
                            else val) for key, val in kwargs.items()}
            widget.pack_configure(**scaled)

        # 4) 日志粗体 tag 的字号跟随 TkFixedFont
        if getattr(self, "log_text", None) is not None:
            fixed = tkfont.nametofont("TkFixedFont")
            self.log_text.tag_configure(
                "bold", font=(fixed.actual("family"), fixed.actual("size"), "bold"))

        # 5) 窗口尺寸：仅启动时设置默认大小，实时切换由 _on_scale_change 处理
        self._apply_window_constraints(set_default=resize_window)

    def _on_scale_change(self, _event=None):
        if self.scale_combo is None:
            return
        try:
            factor = float(self.scale_combo.get().rstrip("%")) / 100.0
        except ValueError:
            return
        old = self.scale_factor
        self._apply_scale(factor, resize_window=False)
        # 实时切换时按比例缩放当前窗口，但不得超出屏幕工作区
        if old and self.root.winfo_width() > 1:
            ratio = factor / old
            screen_w, screen_h = self._screen_size()
            width = min(int(self.root.winfo_width() * ratio),
                        screen_w - self.SCREEN_MARGIN_X)
            height = min(int(self.root.winfo_height() * ratio),
                         screen_h - self.SCREEN_MARGIN_Y)
            self.root.geometry(f"{max(360, width)}x{max(320, height)}")
        save_scale(factor)

    # ---------- 界面构建 ----------
    def _configure_style(self):
        self.root.title("NVIDIA GPU 驱动切换工具")
        # 窗口尺寸与最小尺寸统一在 _apply_scale → _apply_window_constraints 设置
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Hint.TLabel", foreground="#555555")
        style.configure("VFIO.TButton", background="#1565c0", foreground="white")
        style.map("VFIO.TButton",
                  background=[("active", "#1976d2"), ("disabled", "#9e9e9e")])
        style.configure("NV.TButton", background="#2e7d32", foreground="white")
        style.map("NV.TButton",
                  background=[("active", "#388e3c"), ("disabled", "#9e9e9e")])
        style.configure("VM.TButton", background="#6a1b9a", foreground="white")
        style.map("VM.TButton",
                  background=[("active", "#7b1fa2"), ("disabled", "#9e9e9e")])

    def _build_ui(self):
        fixed_font = tkfont.nametofont("TkFixedFont")
        self.bold_font = (fixed_font.actual("family"), fixed_font.actual("size"), "bold")

        # 标题
        header = ttk.Frame(self.root)
        self._register_padding(header, (14, 12, 14, 4))
        self._pack(header, fill="x")
        self._pack(ttk.Label(header, text="NVIDIA GPU 驱动切换工具",
                             style="Title.TLabel"), anchor="w")
        self._pack(ttk.Label(header, text="vfio-pci 直通  ⇄  NVIDIA 原生驱动",
                             style="Hint.TLabel"), anchor="w")

        # 权限状态条：GUI 本身不需要 root，执行时才弹密码
        perm_bar = ttk.Frame(self.root)
        self._register_padding(perm_bar, (14, 4))
        self._pack(perm_bar, fill="x")
        if is_root():
            ttk.Label(
                perm_bar,
                text="● root 模式：操作将直接执行，不再弹出密码验证",
                foreground="#2e7d32",
            ).pack(side="left")
        else:
            ttk.Label(
                perm_bar,
                text="● 普通用户模式：点击操作时由系统 Polkit 弹窗索取密码（本程序不重启、不整体提权）",
                foreground="#1565c0",
            ).pack(side="left")

        self._pack(ttk.Separator(self.root), fill="x", padx=14, pady=6)

        # 选项区
        option_frame = ttk.LabelFrame(self.root, text="选项")
        self._register_padding(option_frame, 10)
        self._pack(option_frame, fill="x", padx=14, pady=4)
        hp_gb = self.switch.TARGET_HUGEPAGES * 2 // 1024
        self._pack(ttk.Checkbutton(
            option_frame,
            text=f"同时管理 2MB 内存大页（绑定→申请 {self.switch.TARGET_HUGEPAGES} 页 / "
                 f"约 {hp_gb}GB；恢复→释放）",
            variable=self.hp_var,
        ), anchor="w")

        # 操作按钮区
        action_frame = ttk.LabelFrame(self.root, text="操作")
        self._register_padding(action_frame, 10)
        self._pack(action_frame, fill="x", padx=14, pady=6)
        self.btn_vfio = ttk.Button(
            action_frame, text="① 绑定到 VFIO（虚拟机直通）",
            style="VFIO.TButton", command=self._on_bind_vfio)
        self._pack(self.btn_vfio, fill="x", pady=3)
        self.btn_nvidia = ttk.Button(
            action_frame, text="② 恢复 NVIDIA 原生驱动",
            style="NV.TButton", command=self._on_bind_nvidia)
        self._pack(self.btn_nvidia, fill="x", pady=3)
        self.btn_status = ttk.Button(
            action_frame, text="查看当前 GPU 驱动状态（只读，无需密码）",
            style="Big.TButton", command=self._on_refresh_status)
        self._pack(self.btn_status, fill="x", pady=3)
        self._pack(ttk.Separator(action_frame), fill="x", pady=6)
        self.btn_vm = ttk.Button(
            action_frame, text=f"③ 启动 Win11 虚拟机（virsh start {VM_DOMAIN}）",
            style="VM.TButton", command=self._on_start_vm)
        self._pack(self.btn_vm, fill="x", pady=3)

        # 底部状态栏：先于日志区 pack 并锚定 side=bottom，
        # 保证窗口高度不足时（niri 平铺）底栏与缩放控件始终可见
        footer = ttk.Frame(self.root)
        self._register_padding(footer, (14, 2, 14, 10))
        self._pack(footer, side="bottom", fill="x")
        self._pack(ttk.Button(footer, text="清空日志", command=self._clear_log),
                   side="left")
        self._pack(ttk.Button(footer, text="退出", command=self._on_close),
                   side="left", padx=6)

        # 缩放选择器（XWayland 下手动接管 HiDPI）
        scale_box = ttk.Frame(footer)
        self._pack(scale_box, side="right", padx=12)
        ttk.Label(scale_box, text="界面缩放", style="Hint.TLabel").pack(side="left")
        self.scale_combo = ttk.Combobox(
            scale_box, width=6, state="readonly",
            values=[f"{int(c * 100)}%" for c in SCALE_CHOICES])
        self.scale_combo.set(f"{int(self.scale_factor * 100)}%")
        self.scale_combo.bind("<<ComboboxSelected>>", self._on_scale_change)
        self.scale_combo.pack(side="left", padx=(6, 0))
        self._pack(ttk.Label(footer, textvariable=self.status_var,
                             style="Hint.TLabel"), side="right")

        # 日志区：最后 pack，占据顶部各栏与底栏之间的全部剩余空间；
        # height 用较小的行数，避免自然请求高度把底栏顶出屏幕
        log_frame = ttk.LabelFrame(self.root, text="执行日志")
        self._register_padding(log_frame, 6)
        self._pack(log_frame, fill="both", expand=True, padx=14, pady=6)
        self.log_text = scrolledtext.ScrolledText(
            log_frame, wrap="word", state="disabled", height=12,
            bg="#1e1e24", fg="#d0d0d0", insertbackground="#d0d0d0",
            font=fixed_font, relief="flat", borderwidth=4,
        )
        self._border_specs.append((self.log_text, 4))
        self._pack(self.log_text, fill="both", expand=True)
        self.log_text.tag_configure("debug", foreground="#7e8a99")
        self.log_text.tag_configure("info", foreground="#66bb6a")
        self.log_text.tag_configure("warning", foreground="#ffa726")
        self.log_text.tag_configure("error", foreground="#ef5350")
        self.log_text.tag_configure("cyan", foreground="#26c6da")
        self.log_text.tag_configure("bold", font=self.bold_font)

    # ---------- 启动横幅 ----------
    def _print_banner(self):
        self._append([(("bold", "cyan"), "NVIDIA GPU 驱动切换工具 — GUI 前端\n")])
        self._append([(("debug",), f"核心脚本: {SWITCH_PATH}\n")])
        self._append([(("debug",),
                       f"PCI 设备: {', '.join(self.switch.PCI_DEVICES)}\n")])
        if is_root():
            self._append([(("info",),
                           "当前以 root 运行，切换操作将直接执行。\n")])
        else:
            self._append([(("debug",),
                           "普通用户模式：切换操作经 pkexec 提权，每次点击都会弹出"
                           "系统密码验证窗口；本窗口始终保持普通用户身份运行。\n")])
            if not shutil.which("pkexec"):
                self._append([(("error", "bold"),
                               "未找到 pkexec，请安装 polkit（Arch: sudo pacman -S polkit"
                               " polkit-kde-agent）。\n")])

    # ---------- 日志渲染 ----------
    def _append(self, parts):
        """parts: [(tags_tuple, text), ...] 追加到日志区。"""
        self.log_text.configure(state="normal")
        for tags, text in parts:
            self.log_text.insert("end", text, tuple(tags))
        self.log_text.see("end")
        line_count = int(self.log_text.index("end-1c").split(".")[0])
        if line_count > self.MAX_LOG_LINES:
            self.log_text.delete("1.0", f"{line_count - self.MAX_LOG_LINES}.0")
        self.log_text.configure(state="disabled")

    def _poll_queue(self):
        try:
            while True:
                kind, *payload = self.log_queue.get_nowait()
                if kind == "stdout":
                    segments, = payload
                    self._append(segments + [((), "\n")])
                elif kind == "done":
                    self._on_task_done(*payload)
        except queue.Empty:
            pass
        self.root.after(self.POLL_INTERVAL, self._poll_queue)

    def _clear_log(self):
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

    # ---------- 任务入口 ----------
    def _on_bind_vfio(self):
        hp = self.hp_var.get()
        hp_line = (f"4. 申请 {self.switch.TARGET_HUGEPAGES} 个 2MB 内存大页"
                   f"（约 {self.switch.TARGET_HUGEPAGES * 2 // 1024}GB）\n") if hp else ""
        confirm = (
            "即将把 GPU 绑定到 VFIO（虚拟机直通模式）：\n\n"
            "1. 强制结束所有占用显卡 / HDMI 声卡的进程（图形界面可能黑屏或退出）\n"
            "2. 卸载 nvidia 内核模块\n"
            "3. 加载 vfio-pci 并绑定 PCI 设备\n"
            f"{hp_line}"
        )
        if not is_root():
            confirm += "\n点击“是”后系统会弹出密码验证窗口（仅本次操作有效）。\n"
        confirm += "\n确定要继续吗？"
        if not messagebox.askyesno("确认：绑定到 VFIO", confirm, icon="warning"):
            return
        # switch 交互菜单：选项 1，大页询问 y/n
        self._launch_switch("绑定到 VFIO", menu_choice="1", hugepages=hp)

    def _on_bind_nvidia(self):
        hp = self.hp_var.get()
        steps = ""
        if hp:
            steps += "0. 先释放全部内存大页归还宿主机\n"
        steps += (
            "1. 清除 driver_override 并从 vfio-pci 解绑设备\n"
            "2. 重新加载 nvidia 内核模块\n"
            "3. 触发 drivers_probe 重新绑定\n"
        )
        confirm = f"即将恢复 NVIDIA 原生驱动：\n\n{steps}\n"
        if not is_root():
            confirm += "点击“是”后系统会弹出密码验证窗口（仅本次操作有效）。\n"
        confirm += "\n确定要继续吗？"
        if not messagebox.askyesno("确认：恢复 NVIDIA 驱动", confirm, icon="warning"):
            return
        # switch 交互菜单：选项 2，大页询问 y/n
        self._launch_switch("恢复 NVIDIA 驱动", menu_choice="2", hugepages=hp)

    def _on_refresh_status(self):
        self._start_worker("查询驱动状态", self._worker_status, notify_on_success=False)

    def _on_start_vm(self):
        confirm = (
            f"即将启动虚拟机 {VM_DOMAIN}：\n\n"
            f"    virsh -c {LIBVIRT_URI} start {VM_DOMAIN}\n\n"
            "如果需要 GPU 直通，请确认已先执行“① 绑定到 VFIO”。\n"
        )
        if not is_root():
            confirm += "\n点击“是”后系统会弹出密码验证窗口（仅本次操作有效）。\n"
        confirm += "\n确定要继续吗？"
        if not messagebox.askyesno(f"确认：启动 {VM_DOMAIN}", confirm, icon="question"):
            return
        self._start_worker(
            f"启动虚拟机 {VM_DOMAIN}", self._worker_start_vm, notify_on_success=True)

    def _worker_start_vm(self):
        """后台线程：只读预检状态 → pkexec virsh start → 复查运行状态。"""
        if not shutil.which("virsh"):
            return ("error",
                    "未找到 virsh，请先安装 libvirt（Arch: sudo pacman -S libvirt）。")

        # 1) 普通用户只读预检，已在运行则无需提权
        self.log_queue.put(("stdout", [
            (("cyan",), f"查询 {VM_DOMAIN} 当前状态（只读）…")]))
        state = query_vm_state()
        if state is None:
            self.log_queue.put(("stdout", [
                (("warning",),
                 f"无法读取 {VM_DOMAIN} 状态（无权限或 libvirtd 未运行），将直接尝试启动。")]))
        else:
            self.log_queue.put(("stdout", [((), f"当前状态: {state}")]))
            if state in ("running",):
                return ("ok", f"{VM_DOMAIN} 已在运行，无需重复启动。")
            if state == "paused":
                return ("error",
                        f"{VM_DOMAIN} 处于暂停状态，请在 virt-manager 或终端中先恢复"
                        "（virsh resume）后再启动。")

        # 2) 提权启动
        cmd = ["virsh", "-c", LIBVIRT_URI, "start", VM_DOMAIN]
        if is_root():
            rc, output = self._stream_process(cmd)
        else:
            if not shutil.which("pkexec"):
                return ("error",
                        "系统未安装 pkexec，无法弹出管理员验证。\n"
                        "Arch 安装：sudo pacman -S polkit polkit-kde-agent")
            if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
                return ("error",
                        "未检测到 DBUS_SESSION_BUS_ADDRESS，无法显示密码验证窗口，"
                        "请在图形桌面会话中运行。")
            self.log_queue.put(("stdout", [
                (("cyan",), "等待管理员授权：系统将弹出密码验证窗口…")]))
            rc, output = self._stream_process(["pkexec"] + cmd)

            if rc == 127 and self._is_agent_missing(output):
                self.log_queue.put(("stdout", [
                    (("warning",),
                     "未检测到 Polkit 认证代理，正在尝试启动 KDE 图形认证代理…")]))
                agent = spawn_polkit_agent()
                if agent:
                    self.log_queue.put(("stdout", [
                        (("info",), f"已启动认证代理: {agent}，请在弹出的窗口中输入密码。")]))
                    rc, output = self._stream_process(["pkexec"] + cmd)

        low = output.lower()
        if rc == 0 or "already active" in low or "already running" in low:
            # 3) 复查实际状态
            time.sleep(1.0)
            new_state = query_vm_state()
            if new_state:
                self.log_queue.put(("stdout", [
                    (("info",), f"复查状态: {VM_DOMAIN} -> {new_state}")]))
            if new_state == "running" or rc == 0:
                return ("ok", f"虚拟机 {VM_DOMAIN} 已启动（{new_state or 'started'}）。")
            return ("error",
                    f"virsh 返回成功但复查状态为 {new_state or '未知'}，"
                    "请查看 libvirt 日志或用 virt-manager 确认。")

        if not is_root() and rc == 127:
            if "not authoriz" in low or "dismiss" in low or "cancel" in low:
                return ("error", "管理员验证被取消或未通过，操作未执行。")
            if self._is_agent_missing(output):
                return ("error",
                        "Polkit 认证代理不可用，无法弹出密码窗口。请确认 polkit-kde-agent"
                        " 已安装且在图形桌面会话中运行。")
            return ("error", "pkexec 拒绝执行（退出码 127），详见日志。")
        return ("error",
                f"启动 {VM_DOMAIN} 失败（退出码 {rc}）："
                f"{output.strip().splitlines()[-1] if output.strip() else '无输出'}")

    # ---------- 后台线程：switch 提权执行 ----------
    def _launch_switch(self, title, menu_choice, hugepages):
        if not is_root() and not shutil.which("pkexec"):
            messagebox.showerror(
                "缺少 pkexec",
                "系统未安装 pkexec，无法弹出管理员验证。\n"
                "Arch 安装：sudo pacman -S polkit polkit-kde-agent")
            return
        if not is_root() and not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            messagebox.showerror(
                "不在图形会话中",
                "未检测到 DBUS_SESSION_BUS_ADDRESS，无法显示密码验证窗口。\n"
                "请从 KDE/桌面会话的终端中运行本程序。")
            return
        self._start_worker(
            title,
            lambda: self._worker_switch(title, menu_choice, hugepages),
            notify_on_success=True,
        )

    def _stream_process(self, cmd, stdin_text=None):
        """
        启动子进程，把合并后的 stdout/stderr 逐行彩色回传到日志队列。

        :return: (返回码, 去除颜色后的完整输出)
        """
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE if stdin_text is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        if stdin_text is not None:
            try:
                proc.stdin.write(stdin_text)
                proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass

        plain_lines = []
        for raw_line in proc.stdout:
            line = raw_line.rstrip("\n")
            plain_lines.append(strip_ansi(line))
            segments = parse_ansi_line(line)
            self.log_queue.put(("stdout", segments or [((), line)]))
        return proc.wait(), "\n".join(plain_lines)

    @staticmethod
    def _is_agent_missing(output):
        """pkexec 报错文案判断：没有可用的认证代理（而非用户主动取消）。"""
        low = output.lower()
        return (
            "authentication agent" in low
            or "textual authentication agent" in low
            or "no agent" in low
        ) and "not authoriz" not in low

    def _worker_switch(self, title, menu_choice, hugepages):
        """在后台线程中通过 pkexec（或直接以 root）运行原 switch 脚本。"""
        stdin_text = f"{menu_choice}\n{'y' if hugepages else 'n'}\n"
        base_cmd = [python_interpreter(), "-u", str(SWITCH_PATH)]

        if is_root():
            rc, output = self._stream_process(base_cmd, stdin_text=stdin_text)
        else:
            self.log_queue.put(("stdout", [
                (("cyan",),
                 "等待管理员授权：系统将弹出密码验证窗口（默认策略 auth_admin_keep，"
                 "短时间内重复操作无需再次输入）…"),
            ]))
            rc, output = self._stream_process(
                ["pkexec"] + base_cmd, stdin_text=stdin_text)

            # 会话中没有图形认证代理（niri 等合成器常见）：拉起 KDE 代理后重试一次
            if rc == 127 and self._is_agent_missing(output):
                self.log_queue.put(("stdout", [
                    (("warning",),
                     "未检测到 Polkit 认证代理，正在尝试启动 KDE 图形认证代理…"),
                ]))
                agent = spawn_polkit_agent()
                if agent:
                    self.log_queue.put(("stdout", [
                        (("info",), f"已启动认证代理: {agent}，请在弹出的窗口中输入密码。"),
                    ]))
                    rc, output = self._stream_process(
                        ["pkexec"] + base_cmd, stdin_text=stdin_text)
                else:
                    return ("error",
                            "系统中没有可用的 Polkit 图形认证代理。请安装 "
                            "polkit-kde-agent（Arch: sudo pacman -S polkit-kde-agent），"
                            "或在终端中直接运行 switch 脚本使用文本密码。")

        if rc == 0:
            return ("ok", f"{title}：执行完成。")
        if not is_root() and rc == 127:
            low = output.lower()
            if "not authoriz" in low or "dismiss" in low or "cancel" in low:
                return ("error", "管理员验证被取消或未通过，操作未执行。")
            if self._is_agent_missing(output):
                return ("error",
                        "Polkit 认证代理不可用，无法弹出密码窗口。请确认 polkit-kde-agent"
                        " 已安装且在图形桌面会话中运行，或在终端直接运行 switch 脚本。")
            return ("error",
                    "pkexec 拒绝执行（退出码 127）。可能是授权被取消、密码错误或"
                    "Polkit 策略限制，详见日志。")
        return ("error", f"{title}：switch 以退出码 {rc} 中止，请查看上方日志定位原因。")

    def _worker_status(self):
        """只读查询：lspci 普通用户即可执行，无需提权。"""
        cmd = ["/bin/sh", "-c", "lspci -k | grep -A 2 -i nvidia"]
        rc, output = self._stream_process(cmd)
        if rc == 0 and output.strip():
            # 复用 switch 里的颜色码，对驱动名做高亮
            colored = (
                output.replace("vfio-pci",
                               f"{self.switch.Colors.GREEN}vfio-pci{self.switch.Colors.RESET}")
                      .replace("nvidia",
                               f"{self.switch.Colors.CYAN}nvidia{self.switch.Colors.RESET}")
            )
            for line in colored.splitlines():
                self.log_queue.put(("stdout", parse_ansi_line(line)))
            return ("ok", "驱动状态已刷新。")
        if not output.strip():
            self.log_queue.put(("stdout", [((), "未获取到 NVIDIA PCI 设备信息")]))
            return ("ok", "驱动状态已刷新（未发现 NVIDIA 设备）。")
        return ("error", f"查询驱动状态失败（退出码 {rc}）。")

    # ---------- 线程/状态编排 ----------
    def _start_worker(self, title, worker_fn, notify_on_success):
        if self.worker is not None and self.worker.is_alive():
            return

        self.status_var.set(f"正在执行：{title} …")
        self._apply_action_state()

        def worker():
            try:
                status, message = worker_fn()
            except FileNotFoundError as exc:
                status, message = "error", f"缺少必要的系统命令：{exc.filename or exc}"
            except Exception as exc:  # noqa: BLE001 - GUI 中兜底显示
                status, message = "error", f"{title}：发生异常：{exc}"
            self.log_queue.put(("done", status, message, notify_on_success))

        self.worker = threading.Thread(target=worker, daemon=True)
        self.worker.start()

    def _on_task_done(self, status, message, notify):
        self.status_var.set("就绪")
        self._apply_action_state()
        if status == "ok":
            self._append([(("info", "bold"), f"✔ {message}\n")])
            if notify:
                messagebox.showinfo("操作完成", message)
        else:
            self._append([(("error", "bold"), f"✘ {message}\n")])
            messagebox.showerror("操作未完成", message)

    def _apply_action_state(self):
        running = self.worker is not None and self.worker.is_alive()
        state = "disabled" if running else "normal"
        for btn in (self.btn_vfio, self.btn_nvidia, self.btn_status, self.btn_vm):
            btn.configure(state=state)

    def _on_close(self):
        if self.worker is not None and self.worker.is_alive():
            messagebox.showwarning(
                "操作进行中", "驱动切换操作尚未完成，请等待执行结束后再退出，\n"
                             "中途退出可能导致设备处于未绑定状态。")
            return
        self.root.destroy()


def main():
    # Wayland（niri/KDE）下 root 无法连接 XWayland，sudo 运行会直接 TclError，
    # 这里给出可操作的终端提示，而不是裸 Traceback。
    try:
        root = tk.Tk()
    except tk.TclError as exc:
        if is_root():
            print(
                "\n[switch_gui] 无法连接图形显示（Wayland 下 root 被禁止访问 XWayland）。\n"
                "本工具不需要 sudo：请直接以普通用户运行，点击操作时会自动弹出\n"
                "系统密码验证窗口（Polkit），验证仅对当次操作生效：\n\n"
                "    ./switch_gui.py\n",
                file=sys.stderr,
            )
        else:
            print(
                f"\n[switch_gui] 无法连接图形显示：{exc}\n"
                "请在图形桌面会话中运行（需要 DISPLAY 或 WAYLAND_DISPLAY）。\n",
                file=sys.stderr,
            )
        sys.exit(1)

    root.withdraw()  # 核心脚本加载失败时不显示空窗口
    try:
        app = SwitchGUI(root)
    except Exception as exc:  # noqa: BLE001
        messagebox.showerror("启动失败", f"无法加载核心脚本 switch：\n\n{exc}")
        root.destroy()
        return
    root.deiconify()
    root.mainloop()


if __name__ == "__main__":
    main()
