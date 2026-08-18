using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

internal static class DirectoryDialogWatcher
{
    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);
    private static readonly IntPtr TopMost = new IntPtr(-1);
    private static readonly IntPtr NotTopMost = new IntPtr(-2);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr window);

    public static int Run(int shellPid, string runtimeRoot)
    {
        var seen = new HashSet<IntPtr>();
        while (IsProcessRunning(shellPid))
        {
            IntPtr owner = GetMainWindow(shellPid);
            if (owner == IntPtr.Zero)
            {
                Thread.Sleep(100);
                continue;
            }
            var dialogs = new List<KeyValuePair<IntPtr, int>>();
            EnumWindows(delegate(IntPtr window, IntPtr parameter)
            {
                if (!IsWindowVisible(window)) return true;
                var title = new StringBuilder(128);
                var className = new StringBuilder(64);
                GetWindowText(window, title, title.Capacity);
                GetClassName(window, className, className.Capacity);
                if (title.ToString() != "Select Workspace Directory" || className.ToString() != "#32770") return true;
                uint processId;
                GetWindowThreadProcessId(window, out processId);
                dialogs.Add(new KeyValuePair<IntPtr, int>(window, (int)processId));
                return true;
            }, IntPtr.Zero);

            foreach (KeyValuePair<IntPtr, int> dialog in dialogs)
            {
                if (seen.Contains(dialog.Key) || !IsOwnedDirectoryPicker(dialog.Value, runtimeRoot)) continue;
                seen.Add(dialog.Key);
                Thread.Sleep(250);
                SetWindowLongPtr(dialog.Key, -8, owner);
                SetWindowPos(dialog.Key, TopMost, 0, 0, 0, 0, 0x0013);
                SetWindowPos(dialog.Key, NotTopMost, 0, 0, 0, 0, 0x0013);
                SetForegroundWindow(dialog.Key);
            }
            seen.RemoveWhere(delegate(IntPtr window) { return !IsWindow(window); });
            Thread.Sleep(100);
        }
        return 0;
    }

    private static bool IsOwnedDirectoryPicker(int processId, string runtimeRoot)
    {
        foreach (ProcessRecord process in ProcessUtility.Query("ProcessId=" + processId))
        {
            string commandLine = process.CommandLine ?? string.Empty;
            return commandLine.IndexOf(runtimeRoot, StringComparison.OrdinalIgnoreCase) >= 0
                && commandLine.IndexOf("directory-picker-native", StringComparison.OrdinalIgnoreCase) >= 0
                && commandLine.IndexOf("worker.cjs", StringComparison.OrdinalIgnoreCase) >= 0;
        }
        return false;
    }

    private static bool IsProcessRunning(int processId)
    {
        try { Process.GetProcessById(processId); return true; }
        catch { return false; }
    }

    private static IntPtr GetMainWindow(int processId)
    {
        try { return Process.GetProcessById(processId).MainWindowHandle; }
        catch { return IntPtr.Zero; }
    }

}
