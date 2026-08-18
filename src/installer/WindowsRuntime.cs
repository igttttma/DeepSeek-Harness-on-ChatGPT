using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

internal static class LinkUtility
{
    private const uint IoReparseTagMountPoint = 0xA0000003;
    private const uint FsctlSetReparsePoint = 0x000900A4;
    private const uint GenericWrite = 0x40000000;
    private const uint FileShareAll = 0x00000007;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint SymbolicLinkFlagDirectory = 1;
    private const uint InvalidFileAttributes = 0xFFFFFFFF;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string fileName, uint desiredAccess, uint shareMode,
        IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(SafeFileHandle device, uint controlCode, byte[] input,
        int inputSize, IntPtr output, int outputSize, out int bytesReturned, IntPtr overlapped);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateSymbolicLink(string symlinkFileName, string targetFileName, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint pathLength, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFileAttributes(string fileName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool RemoveDirectory(string pathName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool DeleteFile(string fileName);

    public static bool PathExists(string path)
    {
        return GetFileAttributes(path) != InvalidFileAttributes;
    }

    public static bool IsReparsePoint(string path)
    {
        uint attributes = GetFileAttributes(path);
        return attributes != InvalidFileAttributes && (attributes & (uint)FileAttributes.ReparsePoint) != 0;
    }

    public static string GetTarget(string path)
    {
        uint attributes = GetFileAttributes(path);
        if (attributes == InvalidFileAttributes) return null;
        bool directory = (attributes & (uint)FileAttributes.Directory) != 0;
        using (SafeFileHandle handle = CreateFile(path, 0, FileShareAll, IntPtr.Zero, OpenExisting,
            directory ? FileFlagBackupSemantics : 0, IntPtr.Zero))
        {
            if (handle.IsInvalid) return null;
            var buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity) return null;
            string value = buffer.ToString();
            if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + value.Substring(8);
            if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) return value.Substring(4);
            return value;
        }
    }

    public static bool Targets(string path, string target)
    {
        string current = GetTarget(path);
        if (current == null) return false;
        return string.Equals(Path.GetFullPath(current).TrimEnd('\\'), Path.GetFullPath(target).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
    }

    public static void EnsureLink(string path, string target, bool directory)
    {
        if (!(directory ? Directory.Exists(target) : File.Exists(target))) throw new FileNotFoundException("Link target is missing.", target);
        if (PathExists(path) && IsReparsePoint(path) && Targets(path, target)) return;
        RemovePath(path, false);
        string parent = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
        if (directory) CreateJunction(path, target);
        else if (!CreateSymbolicLink(path, target, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to create symbolic link: " + path);
    }

    public static void CreateJunction(string path, string target)
    {
        Directory.CreateDirectory(path);
        string substitute = @"\??\" + Path.GetFullPath(target).TrimEnd('\\');
        string print = Path.GetFullPath(target).TrimEnd('\\');
        byte[] substituteBytes = Encoding.Unicode.GetBytes(substitute);
        byte[] printBytes = Encoding.Unicode.GetBytes(print);
        int dataLength = 8 + substituteBytes.Length + 2 + printBytes.Length + 2;
        byte[] buffer = new byte[dataLength + 8];
        WriteUInt32(buffer, 0, IoReparseTagMountPoint);
        WriteUInt16(buffer, 4, (ushort)dataLength);
        WriteUInt16(buffer, 8, 0);
        WriteUInt16(buffer, 10, (ushort)substituteBytes.Length);
        WriteUInt16(buffer, 12, (ushort)(substituteBytes.Length + 2));
        WriteUInt16(buffer, 14, (ushort)printBytes.Length);
        Buffer.BlockCopy(substituteBytes, 0, buffer, 16, substituteBytes.Length);
        Buffer.BlockCopy(printBytes, 0, buffer, 18 + substituteBytes.Length, printBytes.Length);
        using (SafeFileHandle handle = CreateFile(path, GenericWrite, FileShareAll, IntPtr.Zero, OpenExisting,
            FileFlagOpenReparsePoint | FileFlagBackupSemantics, IntPtr.Zero))
        {
            int returned;
            if (handle.IsInvalid || !DeviceIoControl(handle, FsctlSetReparsePoint, buffer, buffer.Length,
                IntPtr.Zero, 0, out returned, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                try { Directory.Delete(path); } catch { }
                throw new Win32Exception(error, "Unable to create junction: " + path);
            }
        }
    }

    public static void RemovePath(string path, bool recursive)
    {
        uint attributes = GetFileAttributes(path);
        if (attributes == InvalidFileAttributes) return;
        bool directory = (attributes & (uint)FileAttributes.Directory) != 0;
        if (IsReparsePoint(path))
        {
            bool removed = directory ? RemoveDirectory(path) : DeleteFile(path);
            if (!removed) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to remove reparse point: " + path);
            return;
        }
        if (directory) Directory.Delete(path, recursive);
        else File.Delete(path);
    }

    public static void RemoveAllReparsePoints(string root)
    {
        if (!Directory.Exists(root)) return;
        var stack = new Stack<string>();
        var links = new List<string>();
        stack.Push(root);
        while (stack.Count != 0)
        {
            string directory = stack.Pop();
            string[] entries;
            try { entries = Directory.GetFileSystemEntries(directory); }
            catch { continue; }
            foreach (string entry in entries)
            {
                if (IsReparsePoint(entry)) links.Add(entry);
                else if (Directory.Exists(entry)) stack.Push(entry);
            }
        }
        links.Sort(delegate(string left, string right) { return right.Length.CompareTo(left.Length); });
        foreach (string link in links) try { RemovePath(link, false); } catch { }
    }

    public static void DeleteTreeWithoutFollowingLinks(string root)
    {
        if (!Directory.Exists(root)) return;
        RemoveAllReparsePoints(root);
        Directory.Delete(root, true);
    }

    private static void WriteUInt16(byte[] buffer, int offset, ushort value)
    {
        byte[] bytes = BitConverter.GetBytes(value);
        Buffer.BlockCopy(bytes, 0, buffer, offset, bytes.Length);
    }

    private static void WriteUInt32(byte[] buffer, int offset, uint value)
    {
        byte[] bytes = BitConverter.GetBytes(value);
        Buffer.BlockCopy(bytes, 0, buffer, offset, bytes.Length);
    }
}

internal sealed class ProcessRecord
{
    public int Id;
    public int ParentId;
    public int SessionId;
    public string Name;
    public string ExecutablePath;
    public string CommandLine;
}

internal static class ProcessUtility
{
    public static List<ProcessRecord> Query(string whereClause)
    {
        var records = new List<ProcessRecord>();
        string query = "SELECT ProcessId,ParentProcessId,SessionId,Name,ExecutablePath,CommandLine FROM Win32_Process";
        if (!string.IsNullOrWhiteSpace(whereClause)) query += " WHERE " + whereClause;
        using (var searcher = new ManagementObjectSearcher(query))
        using (ManagementObjectCollection results = searcher.Get())
        {
            foreach (ManagementObject result in results)
            {
                records.Add(new ProcessRecord
                {
                    Id = Convert.ToInt32(result["ProcessId"]),
                    ParentId = Convert.ToInt32(result["ParentProcessId"]),
                    SessionId = Convert.ToInt32(result["SessionId"]),
                    Name = Convert.ToString(result["Name"]),
                    ExecutablePath = Convert.ToString(result["ExecutablePath"]),
                    CommandLine = Convert.ToString(result["CommandLine"])
                });
            }
        }
        return records;
    }

    public static void Kill(ProcessRecord record)
    {
        try { Process.GetProcessById(record.Id).Kill(); } catch { }
    }

    public static void KillByName(params string[] names)
    {
        foreach (string name in names)
            foreach (Process process in Process.GetProcessesByName(name))
                try { process.Kill(); } catch { }
    }

    public static Process StartHidden(string fileName, string arguments, string workingDirectory, IDictionary<string, string> environment)
    {
        var info = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
        if (environment != null)
            foreach (KeyValuePair<string, string> pair in environment) info.EnvironmentVariables[pair.Key] = pair.Value;
        return Process.Start(info);
    }

    public static string Quote(string value)
    {
        if (string.IsNullOrEmpty(value)) return "\"\"";
        var result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
            }
            else
            {
                result.Append('\\', backslashes);
                result.Append(character);
            }
            backslashes = 0;
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
