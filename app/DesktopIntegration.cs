using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace AndroidScreenShare {
    public sealed class CapturedProcess : IDisposable {
        public Process Process { get; private set; }
        private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
        private int completedStreams;
        public bool OutputComplete { get { return Volatile.Read(ref completedStreams) == 2; } }
        public CapturedProcess(string file, string[] arguments, string directory) {
            var command = new List<string>();
            foreach (string argument in arguments) command.Add(Quote(argument));
            Process = new Process { StartInfo = new ProcessStartInfo {
                FileName = file, Arguments = string.Join(" ", command.ToArray()),
                WorkingDirectory = directory, UseShellExecute = false,
                CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            }};
            Process.OutputDataReceived += OnLine;
            Process.ErrorDataReceived += OnLine;
            try { Process.Start(); Process.BeginOutputReadLine(); Process.BeginErrorReadLine(); }
            catch { Dispose(); throw; }
        }
        private void OnLine(object sender, DataReceivedEventArgs args) {
            if (args.Data == null) Interlocked.Increment(ref completedStreams);
            else if (lines.Count < 2000) lines.Enqueue(args.Data);
        }
        public bool TryReadLine(out string line) { return lines.TryDequeue(out line); }
        public static string Quote(string value) {
            var output = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in value ?? "") {
                if (character == '\\') { slashes++; continue; }
                if (character == '"') { output.Append('\\', slashes * 2 + 1); output.Append('"'); }
                else { output.Append('\\', slashes); output.Append(character); }
                slashes = 0;
            }
            output.Append('\\', slashes * 2); output.Append('"');
            return output.ToString();
        }
        public void Dispose() {
            if (Process == null) return;
            try { if (!Process.HasExited) Process.Kill(); } catch {}
            Process.Dispose();
        }
    }

    public sealed class WindowSnapshot {
        public int X, Y, Width, Height;
        public bool Minimized, Maximized, Fullscreen;
    }
    public static class DesktopWindows {
        [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
        private delegate bool EnumProc(IntPtr handle, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint process);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out Rect rectangle);
        [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr handle, out Rect rectangle);
        [DllImport("user32.dll")] private static extern bool ClientToScreen(IntPtr handle, ref Point point);
        [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(Point point);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr handle, int index);
        [DllImport("user32.dll")] private static extern bool AdjustWindowRectEx(ref Rect rectangle, uint style, bool menu, uint extendedStyle);
        [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr handle, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
        public static IntPtr Find(int process) {
            IntPtr result = IntPtr.Zero;
            EnumWindows(delegate(IntPtr handle, IntPtr data) {
                uint owner; GetWindowThreadProcessId(handle, out owner);
                if (owner == process && IsWindowVisible(handle)) { result = handle; return false; }
                return true;
            }, IntPtr.Zero);
            return result;
        }
        public static WindowSnapshot Snapshot(IntPtr handle) {
            Rect outer, client;
            if (handle == IntPtr.Zero || !GetWindowRect(handle, out outer) || !GetClientRect(handle, out client)) return null;
            var screen = Screen.FromHandle(handle).Bounds;
            return new WindowSnapshot { X = outer.Left, Y = outer.Top,
                Width = client.Right - client.Left, Height = client.Bottom - client.Top,
                Minimized = IsIconic(handle), Maximized = IsZoomed(handle),
                Fullscreen = outer.Left <= screen.Left && outer.Top <= screen.Top && outer.Right >= screen.Right && outer.Bottom >= screen.Bottom
            };
        }
        public static bool Place(IntPtr handle, int x, int y, int width, int height, bool topmost) {
            var rectangle = new Rect { Right = width, Bottom = height };
            AdjustWindowRectEx(ref rectangle, (uint)GetWindowLong(handle, -16), false, (uint)GetWindowLong(handle, -20));
            return SetWindowPos(handle, new IntPtr(topmost ? -1 : -2), x, y,
                rectangle.Right - rectangle.Left, rectangle.Bottom - rectangle.Top, 0x0010);
        }
        public static void SetTopmost(IntPtr handle, bool topmost) {
            SetWindowPos(handle, new IntPtr(topmost ? -1 : -2), 0, 0, 0, 0, 0x0010 | 0x0001 | 0x0002);
        }
        public static bool WheelDown(int process) {
            var window = GetForegroundWindow();
            uint owner;
            Rect client;
            if (GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)process ||
                !GetClientRect(window, out client) || client.Right < 100 || client.Bottom < 100) return false;
            var center = new Point { X = client.Right / 2, Y = client.Bottom / 2 };
            var screenPoint = center;
            if (!ClientToScreen(window, ref screenPoint)) return false;
            return PostMessage(window, 0x0200, IntPtr.Zero, PackPoint(center)) &&
                   PostMessage(window, 0x020A, new IntPtr(-120 << 16), PackPoint(screenPoint));
        }
        private static IntPtr PackPoint(Point point) {
            return new IntPtr(unchecked((point.Y << 16) | (point.X & 0xffff)));
        }
        public static System.Drawing.Bitmap CapturePlayerTop(int process, int videoWidth, int videoHeight) {
            var window = GetForegroundWindow();
            uint owner;
            Rect client;
            var origin = new Point();
            if (GetWindowThreadProcessId(window, out owner) == 0 || owner != (uint)process ||
                !GetClientRect(window, out client) || client.Right < 160 || client.Bottom < 160 ||
                videoWidth <= 0 || videoHeight <= 0 ||
                !ClientToScreen(window, ref origin)) return null;
            double scale = Math.Min((double)client.Right / videoWidth, (double)client.Bottom / videoHeight);
            int width = (int)(videoWidth * scale);
            int height = (int)(videoHeight * scale);
            var bounds = new System.Drawing.Rectangle(origin.X + (client.Right - width) / 2,
                origin.Y + (client.Bottom - height) / 2, width, height / 3);
            if (bounds.Width < 100 || bounds.Height < 60) return null;
            if (!SystemInformation.VirtualScreen.Contains(bounds)) return null;
            for (int y = 1; y <= 9; y += 4) {
                for (int x = 1; x <= 9; x += 4) {
                    if (WindowFromPoint(new Point { X = bounds.X + bounds.Width * x / 10,
                        Y = bounds.Y + bounds.Height * y / 10 }) != window) return null;
                }
            }
            var bitmap = new System.Drawing.Bitmap(bounds.Width, bounds.Height, System.Drawing.Imaging.PixelFormat.Format24bppRgb);
            try {
                using (var graphics = System.Drawing.Graphics.FromImage(bitmap)) {
                    graphics.CopyFromScreen(bounds.Location, System.Drawing.Point.Empty, bounds.Size);
                }
                if (GetForegroundWindow() == window) return bitmap;
                bitmap.Dispose();
                return null;
            } catch {
                bitmap.Dispose();
                throw;
            }
        }
    }

    public sealed class ShareHotkeys : NativeWindow, IDisposable {
        internal const int PlayerKeyMessage = 0x8035;
        public event EventHandler PlayerKeyPressed;
        [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr handle, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr handle, int id);
        private readonly ConcurrentQueue<string> commands = new ConcurrentQueue<string>();
        private readonly List<int> registered = new List<int>();
        private readonly string[] actions = { "previous", "next", "left", "right" };
        public ShareHotkeys() { CreateHandle(new CreateParams { Caption = "AndroidScreenShareHotkeys", Parent = new IntPtr(-3) }); }
        public string[] Configure(string profile) {
            Clear();
            var failed = new List<string>();
            if (profile == "Off") return failed.ToArray();
            uint modifiers = profile == "CtrlShift" ? 0x0006u : 0x0003u;
            uint[] keys = { 0x26, 0x28, 0x25, 0x27 };
            for (int i = 0; i < actions.Length; i++) {
                if (RegisterHotKey(Handle, 7600 + i, modifiers | 0x4000, keys[i])) registered.Add(7600 + i);
                else failed.Add(actions[i]);
            }
            return failed.ToArray();
        }
        public bool TryRead(out string command) { return commands.TryDequeue(out command); }
        protected override void WndProc(ref Message message) {
            if (message.Msg == PlayerKeyMessage) {
                var handler = PlayerKeyPressed;
                if (handler != null) handler(this, EventArgs.Empty);
                return;
            }
            int index = message.WParam.ToInt32() - 7600;
            if (message.Msg == 0x0312 && index >= 0 && index < actions.Length) commands.Enqueue(actions[index]);
            base.WndProc(ref message);
        }
        private void Clear() {
            foreach (int id in registered) UnregisterHotKey(Handle, id);
            registered.Clear();
            string ignored; while (commands.TryDequeue(out ignored)) {}
        }
        public void Dispose() { Clear(); DestroyHandle(); }
    }

    // Keep the keyboard hook off the GUI thread: an ADB call must never delay typing.
    // Unmodified playback keys belong only to the selected player window.
    public sealed class FocusedPlayerHotkeys : IDisposable {
        [StructLayout(LayoutKind.Sequential)] private struct NativeMessage {
            public IntPtr Window;
            public uint Message;
            public IntPtr WParam, LParam;
            public uint Time;
            public int X, Y;
            public uint Private;
        }
        private delegate IntPtr HookCallback(int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int kind, HookCallback callback, IntPtr module, uint thread);
        [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr handle);
        [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr handle, int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] private static extern bool PeekMessage(out NativeMessage message, IntPtr window, uint first, uint last, uint remove);
        [DllImport("user32.dll")] private static extern int GetMessage(out NativeMessage message, IntPtr window, uint first, uint last);
        [DllImport("user32.dll")] private static extern bool PostThreadMessage(uint thread, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);

        private readonly HookCallback callback;
        private readonly Thread thread;
        private readonly ManualResetEventSlim ready = new ManualResetEventSlim(false);
        private readonly int targetPid;
        private readonly IntPtr dispatchWindow;
        private volatile bool closed;
        private uint threadId;
        private IntPtr hook;
        private int pending;
        private readonly bool enableSpace;
        private readonly bool enableArrows;
        private readonly HashSet<int> held = new HashSet<int>();
        public int TargetProcessId { get { return targetPid; } }
        public bool SpaceEnabled { get { return enableSpace; } }
        public bool ArrowsEnabled { get { return enableArrows; } }

        public FocusedPlayerHotkeys(int processId, IntPtr window, bool space, bool arrows) {
            if (processId <= 0) throw new ArgumentOutOfRangeException("processId");
            targetPid = processId;
            dispatchWindow = window;
            enableSpace = space;
            enableArrows = arrows;
            callback = OnKey;
            thread = new Thread(Run) { IsBackground = true };
            thread.Start();
            if (!ready.Wait(1500) || hook == IntPtr.Zero) {
                Dispose();
                throw new InvalidOperationException("Could not register the focused playback shortcuts");
            }
        }
        public static bool HasFocus(int processId) {
            uint owner;
            return GetWindowThreadProcessId(GetForegroundWindow(), out owner) != 0 && owner == (uint)processId;
        }
        public string TakePress() {
            int key = Interlocked.Exchange(ref pending, 0);
            if (key == 0 || !HasFocus(targetPid)) return "";
            if (key == 0x26) return "previous";
            if (key == 0x28) return "next";
            return "toggle";
        }
        private void Run() {
            NativeMessage message;
            threadId = GetCurrentThreadId();
            PeekMessage(out message, IntPtr.Zero, 0, 0, 0);
            hook = SetWindowsHookEx(13, callback, GetModuleHandle(null), 0);
            ready.Set();
            try { if (hook != IntPtr.Zero && !closed) while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {} }
            finally { if (hook != IntPtr.Zero) UnhookWindowsHookEx(hook); }
        }
        private IntPtr OnKey(int code, IntPtr message, IntPtr data) {
            if (!closed && code >= 0) {
                int key = Marshal.ReadInt32(data);
                int type = message.ToInt32();
                if (type == 0x101 || type == 0x105) {
                    if (held.Remove(key) && HasFocus(targetPid)) return new IntPtr(1);
                } else if (type == 0x100 &&
                    ((key == 0x20 && enableSpace) || ((key == 0x26 || key == 0x28) && enableArrows)) &&
                    HasFocus(targetPid) &&
                    !IsPressed(0x10) && !IsPressed(0x11) && !IsPressed(0x12) &&
                    !IsPressed(0x5B) && !IsPressed(0x5C)) {
                    if (held.Add(key)) {
                        Interlocked.Exchange(ref pending, key);
                        PostMessage(dispatchWindow, ShareHotkeys.PlayerKeyMessage, IntPtr.Zero, IntPtr.Zero);
                    }
                    return new IntPtr(1);
                }
            }
            return CallNextHookEx(hook, code, message, data);
        }
        private static bool IsPressed(int key) { return GetAsyncKeyState(key) < 0; }
        public void Dispose() {
            closed = true;
            if (threadId != 0) PostThreadMessage(threadId, 0x12, IntPtr.Zero, IntPtr.Zero);
            if (thread.Join(500)) ready.Dispose();
        }
    }
}
