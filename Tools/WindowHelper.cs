using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class WindowHelper {
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    private static extern IntPtr GetWindowLong32(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
    private static extern IntPtr SetWindowLong32(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentProcessId();

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public const uint WM_CLOSE = 0x10;

    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_LAYERED = 0x00080000;
    public const uint LWA_ALPHA = 0x00000002;

    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_FRAMECHANGED = 0x0020;

    public const int VK_SHIFT = 0x10;
    public const int VK_ESCAPE = 0x1B;
    public const int VK_H = 0x48;

    public static IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex) {
        if (IntPtr.Size == 8)
            return GetWindowLongPtr64(hWnd, nIndex);
        else
            return GetWindowLong32(hWnd, nIndex);
    }

    public static IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong) {
        if (IntPtr.Size == 8)
            return SetWindowLongPtr64(hWnd, nIndex, dwNewLong);
        else
            return SetWindowLong32(hWnd, nIndex, dwNewLong);
    }

    public static void Main(string[] args) {
        if (args.Length < 2) {
            Console.WriteLine("Usage: WindowHelper <hwnd> <pid> [cmdFile] [msgFile] [initialPassthrough]");
            return;
        }

        long hwndVal = 0;
        long.TryParse(args[0], out hwndVal);
        IntPtr hWnd = new IntPtr(hwndVal);

        uint pid = 0;
        uint.TryParse(args[1], out pid);

        string cmdFile = args.Length >= 3 ? args[2] : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", ".window_cmd.txt");
        string msgFile = args.Length >= 4 ? args[3] : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", ".window_msg.txt");
        bool currentPassthrough = (args.Length >= 5 && args[4] == "1");
        string rectsFile = args.Length >= 6 ? args[5] : null;
        int rectsMs = 500;
        if (args.Length >= 7) { int.TryParse(args[6], out rectsMs); }
        if (rectsMs < 200) rectsMs = 200;

        Process proc = null;
        if (pid > 0) {
            try {
                proc = Process.GetProcessById((int)pid);
            } catch { }
        }

        // Apply initial passthrough
        SetPassthroughAll(pid, hWnd, currentPassthrough);

        bool hWasDown = false;
        bool escWasDown = false;
        uint selfPid = GetCurrentProcessId();
        string lastRectsJson = "";
        int lastDumpTick = 0;

        while (true) {
            if (proc != null) {
                try {
                    if (proc.HasExited) break;
                } catch { break; }
            }

            // 1. Check for command file from Godot
            if (File.Exists(cmdFile)) {
                try {
                    string content = File.ReadAllText(cmdFile).Trim().ToLower();
                    File.Delete(cmdFile);
                    if (content == "1" || content == "true" || content == "passthrough") {
                        currentPassthrough = true;
                        SetPassthroughAll(pid, hWnd, true);
                    } else if (content == "0" || content == "false" || content == "interactive") {
                        currentPassthrough = false;
                        SetPassthroughAll(pid, hWnd, false);
                    } else if (content.StartsWith("close:")) {
                        // Просьба стикмена вежливо закрыть окно (WM_CLOSE — приложение может спросить про сохранение)
                        long closeHwnd = 0;
                        if (long.TryParse(content.Substring(6).Trim(), out closeHwnd) && closeHwnd != 0) {
                            try { PostMessage(new IntPtr(closeHwnd), WM_CLOSE, IntPtr.Zero, IntPtr.Zero); } catch { }
                        }
                    } else if (content == "exit") {
                        break;
                    }
                } catch { }
            }

            // 2. Global Hotkey 'H': toggle HUD and bring window to front
            bool hIsDown = (GetAsyncKeyState(VK_H) & 0x8000) != 0;
            if (hIsDown && !hWasDown) {
                try {
                    string dir = Path.GetDirectoryName(msgFile);
                    if (dir != null && dir != "") Directory.CreateDirectory(dir);
                    File.WriteAllText(msgFile, "toggle_hud");
                } catch { }

                if (currentPassthrough) {
                    currentPassthrough = false;
                    SetPassthroughAll(pid, hWnd, false);
                }
            }
            hWasDown = hIsDown;

            // 3. Emergency Exit Hotkey: Shift + Esc
            bool shiftDown = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
            bool escDown = (GetAsyncKeyState(VK_ESCAPE) & 0x8000) != 0;
            if (shiftDown && escDown && !escWasDown) {
                try {
                    File.WriteAllText(msgFile, "exit");
                } catch { }
                Thread.Sleep(150);
                if (proc != null && !proc.HasExited) {
                    try { proc.Kill(); } catch { }
                }
                break;
            }
            escWasDown = escDown;

            // 4. Периодический дамп прямоугольников окон для платформ стикменов
            if (rectsFile != null) {
                int now = Environment.TickCount;
                if (now - lastDumpTick >= rectsMs) {
                    lastDumpTick = now;
                    try {
                        string json = BuildWindowRectsJson(pid, selfPid);
                        if (json != lastRectsJson) {
                            lastRectsJson = json;
                            string dir = Path.GetDirectoryName(rectsFile);
                            if (dir != null && dir != "") Directory.CreateDirectory(dir);
                            File.WriteAllText(rectsFile, json);
                        }
                    } catch { }
                }
            }

            Thread.Sleep(40);
        }
    }

    // --- Дамп окон для платформ: EnumWindows идёт сверху вниз по Z-порядку ---
    private static List<string> s_rectItems;
    private static uint s_skipPidA;
    private static uint s_skipPidB;
    private static List<RECT> s_maxRects; // развёрнутые окна: всё под ними скрыто

    public static string BuildWindowRectsJson(uint godotPid, uint selfPid) {
        s_rectItems = new List<string>();
        s_maxRects = new List<RECT>();
        s_skipPidA = godotPid;
        s_skipPidB = selfPid;
        try { EnumWindows(EnumRectCallback, IntPtr.Zero); } catch { }
        StringBuilder sb = new StringBuilder();
        sb.Append('[');
        for (int i = 0; i < s_rectItems.Count && i < 64; i++) {
            if (i > 0) sb.Append(',');
            sb.Append(s_rectItems[i]);
        }
        sb.Append(']');
        return sb.ToString();
    }

    private static bool EnumRectCallback(IntPtr h, IntPtr l) {
        try {
            uint wpid = 0;
            GetWindowThreadProcessId(h, out wpid);
            if (wpid == s_skipPidA || wpid == s_skipPidB) return true; // свои окна: игра и сам helper
            if (!IsWindowVisible(h) || IsIconic(h)) return true;
            bool zoomed = false;
            try { zoomed = IsZoomed(h); } catch { }
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            if (zoomed) {
                // Развёрнутое окно — само не платформа, и всё под ним скрыто:
                // запоминаем, нижележащее выкидываем
                s_maxRects.Add(r);
                return true;
            }
            foreach (RECT mr in s_maxRects) {
                if (r.Left >= mr.Left && r.Top >= mr.Top && r.Right <= mr.Right && r.Bottom <= mr.Bottom)
                    return true; // полностью закрыто развёрнутым
            }
            int w = r.Right - r.Left;
            int hh = r.Bottom - r.Top;
            if (w < 60 || hh < 40) return true; // тултипы, меню, тени
            if (r.Left < -10000 || r.Top < -10000) return true; // свёрнутые за экран
            StringBuilder cls = new StringBuilder(256);
            GetClassName(h, cls, cls.Capacity);
            string c = cls.ToString();
            if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd"
                || c == "Shell_SecondaryTrayWnd" || c == "#32768"
                || c == "tooltips_class32" || c == "TopLevelWindowForOverflowXaml") return true;
            long hwndVal = h.ToInt64();
            s_rectItems.Add("{\"hwnd\":" + hwndVal + ",\"x\":" + r.Left + ",\"y\":" + r.Top + ",\"w\":" + w + ",\"h\":" + hh + "}");
        } catch { }
        return true;
    }

    public static void SetPassthroughAll(uint pid, IntPtr primaryHwnd, bool enable) {        if (primaryHwnd != IntPtr.Zero && IsWindow(primaryHwnd)) {
            ApplyToWindowTree(primaryHwnd, enable);
        }
        if (pid > 0) {
            try {
                EnumWindows((h, l) => {
                    uint p;
                    GetWindowThreadProcessId(h, out p);
                    if (p == pid) {
                        ApplyToWindowTree(h, enable);
                    }
                    return true;
                }, IntPtr.Zero);
            } catch { }
        }
    }

    public static void ApplyToWindowTree(IntPtr hWnd, bool enable) {
        if (!IsWindow(hWnd)) return;
        ApplySingleWindow(hWnd, enable);
        try {
            EnumChildWindows(hWnd, (childHwnd, l) => {
                ApplySingleWindow(childHwnd, enable);
                return true;
            }, IntPtr.Zero);
        } catch { }
    }

    public static void ApplySingleWindow(IntPtr hWnd, bool enable) {
        try {
            long style = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
            if (enable) {
                long newStyle = style | WS_EX_LAYERED | WS_EX_TRANSPARENT;
                SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(newStyle));
                SetLayeredWindowAttributes(hWnd, 0, 255, LWA_ALPHA);
            } else {
                long newStyle = (style | WS_EX_LAYERED) & ~WS_EX_TRANSPARENT;
                SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(newStyle));
                SetForegroundWindow(hWnd);
            }
            // CRITICAL: Force Windows DWM to recalculate the frame and apply transparent hit-testing!
            SetWindowPos(hWnd, IntPtr.Zero, 0, 0, 0, 0, 
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        } catch { }
    }
}
