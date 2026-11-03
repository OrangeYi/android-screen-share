using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace AndroidScreenShare {
    public sealed class CapturedProcess : IDisposable {
        public Process Process { get; private set; }
        private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
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
            if (args.Data != null && lines.Count < 2000) lines.Enqueue(args.Data);
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
        private delegate bool EnumProc(IntPtr handle, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr handle, out uint process);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool IsZoomed(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr handle, out Rect rectangle);
        [DllImport("user32.dll")] private static extern bool GetClientRect(IntPtr handle, out Rect rectangle);
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
    }

    public sealed class ShareHotkeys : NativeWindow, IDisposable {
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
}
