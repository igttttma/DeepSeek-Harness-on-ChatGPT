using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal sealed class RuntimeController
{
    private readonly string root;
    private readonly string runtime;
    private readonly string dsh;
    private readonly string dshHome;
    private readonly string manifestPath;
    private readonly string owlHost;
    private readonly string owlUserData;
    private readonly string owlMarker;
    private readonly string launcherPath;
    private readonly string taskbarIcon;
    private readonly string activationSignal;
    private int activeShellPid;

    public RuntimeController(string installRoot, string executablePath)
    {
        root = installRoot.TrimEnd(Path.DirectorySeparatorChar);
        runtime = Path.Combine(root, "parasite-runtime");
        dsh = Path.Combine(root, "dsh-runtime");
        dshHome = Path.Combine(dsh, ".dshhome");
        manifestPath = Path.Combine(dsh, "meta", "release-manifest.json");
        owlHost = Path.Combine(runtime, "owl-host");
        owlUserData = Path.Combine(runtime, "owl-ud-dsh");
        owlMarker = Path.Combine(owlHost, ".codex-package-full-name");
        launcherPath = executablePath;
        taskbarIcon = Path.Combine(runtime, "dsh-taskbar-icon.exe");
        activationSignal = Path.Combine(runtime, "dsh-activate.signal");
    }

    public int Start()
    {
        WriteInfo("root=" + root);
        if (!AssertOwlUserDataAvailable()) return 14;
        Directory.CreateDirectory(owlUserData);
        Directory.CreateDirectory(owlHost);
        CodexRequirements requirements = CodexDiscovery.Validate(manifestPath);
        ReleaseManifest manifest = requirements.Manifest;
        string bin = CodexDiscovery.CombineRelative(dsh, manifest.entry);
        if (!File.Exists(bin)) throw new FileNotFoundException("DSH entry is missing.", bin);
        if (!Directory.Exists(dshHome)) throw new DirectoryNotFoundException("DSH home is missing: " + dshHome);
        string staleReason = GetOwlHostStaleReason(requirements.Package);
        if (staleReason != null) throw new InvalidOperationException("Runtime preparation is required: " + staleReason);
        AssertOwlHostReady(requirements.Package);

        string configPath = Path.Combine(owlHost, "resources", "app", "dsh-desktop.json");
        Directory.CreateDirectory(Path.GetDirectoryName(configPath));
        var desktopConfig = new Dictionary<string, string>
        {
            { "url", "http://127.0.0.1:" + manifest.port },
            { "node", requirements.Package.NodePath }
        };
        File.WriteAllText(configPath, new JavaScriptSerializer().Serialize(desktopConfig), new UTF8Encoding(false));

        if (!IsPortListening(manifest.port))
        {
            WriteInfo("starting DSH node");
            string packageArguments = "package-node " + ProcessUtility.Quote(requirements.Package.NodePath) + " "
                + ProcessUtility.Quote(bin) + " " + ProcessUtility.Quote(dshHome) + " "
                + ProcessUtility.Quote(dsh) + " " + manifest.port;
            AppxBridge.Invoke(requirements.Package.FamilyName, launcherPath, packageArguments);
            DateTime deadline = DateTime.UtcNow.AddSeconds(50);
            while (!IsPortListening(manifest.port))
            {
                if (DateTime.UtcNow > deadline) throw new TimeoutException("DSH port did not open: " + manifest.port);
                Thread.Sleep(400);
            }
        }

        StopOwlStub();
        RestoreTaskbarIcon();
        string stub = Path.Combine(owlHost, "owl-stub.exe");
        string owlArguments = "--no-sandbox --disable-gpu --user-data-dir=" + ProcessUtility.Quote(owlUserData);
        AppxBridge.Invoke(requirements.Package.FamilyName, stub, owlArguments);
        Thread.Sleep(5000);
        ProcessRecord shell = FindOwlParent();
        if (shell == null) throw new InvalidOperationException("owl-stub did not stay up.");
        activeShellPid = shell.Id;
        StopWatchers();
        ProcessUtility.StartHidden(launcherPath,
            "watch " + shell.Id + " " + ProcessUtility.Quote(dsh), root, null);
        WriteInfo("OK http://127.0.0.1:" + manifest.port);
        return 0;
    }

    public void WaitForShellExit()
    {
        if (activeShellPid == 0) return;
        try { Process.GetProcessById(activeShellPid).WaitForExit(); } catch { }
    }

    public bool ActivateShellWindow()
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline)
        {
            int shellPid = activeShellPid;
            if (shellPid == 0)
            {
                ProcessRecord shell = FindOwlParent();
                if (shell != null) shellPid = shell.Id;
            }
            if (WriteActivationSignal()) return true;
            if (shellPid != 0 && ProcessUtility.ActivateTopLevelWindow(shellPid)) return true;
            Thread.Sleep(100);
        }
        return false;
    }

    private bool WriteActivationSignal()
    {
        try
        {
            Directory.CreateDirectory(runtime);
            File.WriteAllText(activationSignal, DateTime.UtcNow.Ticks + ":" + Guid.NewGuid().ToString("N"), new UTF8Encoding(false));
            return true;
        }
        catch { return false; }
    }

    public void AuthorizeShellForeground()
    {
        ProcessRecord shell = FindOwlParent();
        if (shell != null) ProcessUtility.AuthorizeForeground(shell.Id);
    }

    public int Stop()
    {
        StopWatchers();
        StopDshNode();
        StopOwlStub();
        WaitForDshExit(8000);
        RestoreTaskbarIcon();
        return 0;
    }

    public void StopAfterShellExit()
    {
        StopWatchers();
        StopDshNode();
        // The Electron browser process can exit before Crashpad/GPU/utility
        // descendants. Kill the owl-host tree before waiting for file handles
        // to drain so parasite-runtime is immediately removable after Quit.
        StopOwlStub();
        WaitForDshExit(8000);
        RestoreTaskbarIcon();
    }

    public int StopBackend()
    {
        StopDshNode();
        return 0;
    }

    public int OpenTerminal()
    {
        CodexRequirements requirements = CodexDiscovery.Validate(manifestPath);
        string bin = CodexDiscovery.CombineRelative(dsh, requirements.Manifest.entry);
        string toolsBin = Path.Combine(dsh, "tools", "bin");
        string corepack = Path.Combine(dsh, "tools", "corepack", "dist", "corepack.js");
        if (!File.Exists(bin)) throw new FileNotFoundException("DSH CLI entry is missing.", bin);
        if (!File.Exists(Path.Combine(toolsBin, "dsh.cmd"))) throw new FileNotFoundException("DSH command wrapper is missing.");
        if (!File.Exists(Path.Combine(toolsBin, "pnpm.cmd"))) throw new FileNotFoundException("pnpm command wrapper is missing.");
        if (!File.Exists(corepack)) throw new FileNotFoundException("Corepack downloader is missing.", corepack);
        Directory.CreateDirectory(dshHome);
        string packageArguments = "package-terminal " + ProcessUtility.Quote(requirements.Package.NodePath) + " "
            + ProcessUtility.Quote(bin) + " " + ProcessUtility.Quote(dshHome) + " " + ProcessUtility.Quote(dsh);
        AppxBridge.Invoke(requirements.Package.FamilyName, launcherPath, packageArguments);
        return 0;
    }

    public int ApplyForks()
    {
        RequireAdministrator();
        CodexRequirements requirements = CodexDiscovery.Validate(manifestPath);
        EnsureWorkspaceLinks(requirements.Manifest);
        EnsureCgLinks(requirements);
        EnsureAssetForks(requirements);
        string staleReason = GetOwlHostStaleReason(requirements.Package);
        if (staleReason != null)
        {
            StopOwlStub();
            SyncOwlHost(requirements.Package);
        }
        else RepairOwlHostLinks(requirements.Package);
        AssertOwlHostReady(requirements.Package);
        return 0;
    }

    public int Cleanup()
    {
        RequireAdministrator();
        foreach (string task in new[] { "ParasiteNode", "ParasiteOwlHost", "ParasiteElectron" })
            RunUtility("schtasks.exe", "/Delete /TN " + ProcessUtility.Quote(task) + " /F");
        StopWatchers();
        ProcessUtility.KillByName("dsh-taskbar-host", "dsh-taskbar-icon");
        foreach (string file in new[]
        {
            Path.Combine(root, "package-lock.json"),
            Path.Combine(runtime, "dsh-desktop-launch.log"),
            Path.Combine(runtime, "dsh-desktop.log"),
            Path.Combine(runtime, "dsh-node.log"),
            Path.Combine(runtime, "dsh-taskbar-icon.log"),
            activationSignal,
            Path.Combine(runtime, "dsh-hwnd.txt"),
            Path.Combine(owlHost, "debug.log"),
            Path.Combine(owlHost, "owl-host-log.txt")
        }) TryDeleteFile(file);
        if (Directory.Exists(runtime))
        {
            foreach (string directory in Directory.GetDirectories(runtime, "owl-ud*"))
                if (!string.Equals(Path.GetFileName(directory), "owl-ud-dsh", StringComparison.OrdinalIgnoreCase))
                    TryDeleteTree(directory);
        }
        TryDeleteTree(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ParasiteRuntime"));
        return 0;
    }

    public int Uninstall()
    {
        RequireAdministrator();
        Stop();
        ReleaseManifest manifest = null;
        try { manifest = ReleaseManifest.Load(manifestPath); } catch { }
        if (manifest != null) RemoveManifestLinks(manifest);
        LinkUtility.RemoveAllReparsePoints(dsh);
        foreach (string generated in new[] { owlHost, owlUserData })
        {
            if (!Directory.Exists(generated)) continue;
            LinkUtility.DeleteTreeWithoutFollowingLinks(generated);
        }
        return 0;
    }

    public static int LaunchPackagedNode(string node, string bin, string home, string workingDirectory, int port)
    {
        var environment = CreateDshEnvironment(node, bin, home, workingDirectory);
        ProcessUtility.StartHidden(node, ProcessUtility.Quote(bin) + " --profile web --port " + port + " --no-open", workingDirectory, environment);
        return 0;
    }

    private static Dictionary<string, string> CreateDshEnvironment(string node, string bin, string home, string workingDirectory)
    {
        string toolsBin = Path.Combine(workingDirectory, "tools", "bin");
        string nodeBin = Path.GetDirectoryName(node);
        string corepackHome = Path.Combine(home, "corepack");
        Directory.CreateDirectory(corepackHome);
        return new Dictionary<string, string>
        {
            { "DSH_HOME", home },
            { "DSH_ENTRY", bin },
            { "DSH_NODE", node },
            { "DSH_RUNTIME", workingDirectory },
            { "COREPACK_HOME", corepackHome },
            { "COREPACK_ENABLE_DOWNLOAD_PROMPT", "0" },
            { "PATH", toolsBin + ";" + nodeBin + ";" + Environment.GetEnvironmentVariable("PATH") }
        };
    }

    public static int LaunchPackagedTerminal(string node, string bin, string home, string workingDirectory)
    {
        var environment = CreateDshEnvironment(node, bin, home, workingDirectory);
        string userDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrWhiteSpace(userDirectory) || !Directory.Exists(userDirectory)) userDirectory = workingDirectory;
        ProcessUtility.StartConsoleShell(userDirectory, environment);
        return 0;
    }

    public static int Preflight(string manifest, string resultPath)
    {
        try
        {
            CodexRequirements requirements = CodexDiscovery.Validate(manifest);
            WriteResult(resultPath, "OK: " + requirements.Package.FullName);
            return 0;
        }
        catch (Exception exception)
        {
            string message = "DeepSeek Harness (on ChatGPT) cannot be installed because the local ChatGPT runtime is incomplete."
                + Environment.NewLine + Environment.NewLine + exception.Message;
            WriteResult(resultPath, message);
            return 20;
        }
    }

    private void EnsureWorkspaceLinks(ReleaseManifest manifest)
    {
        foreach (WorkspaceLink link in manifest.workspaceLinks)
        {
            if (link == null || string.IsNullOrWhiteSpace(link.path) || string.IsNullOrWhiteSpace(link.target)) continue;
            string linkPath = CodexDiscovery.CombineRelative(dsh, link.path);
            string targetPath = CodexDiscovery.CombineRelative(dsh, link.target);
            if (!Directory.Exists(targetPath)) throw new DirectoryNotFoundException("Workspace junction target is missing: " + link.target);
            if ((File.Exists(linkPath) || Directory.Exists(linkPath)) && !LinkUtility.IsReparsePoint(linkPath))
                throw new IOException("Workspace junction path is occupied by a real file or directory: " + link.path);
            LinkUtility.EnsureLink(linkPath, targetPath, true);
        }
    }

    private void EnsureCgLinks(CodexRequirements requirements)
    {
        foreach (CgJunction link in requirements.Manifest.cgJunctions)
        {
            if (link == null || string.IsNullOrWhiteSpace(link.path) || string.IsNullOrWhiteSpace(link.fromCg)) continue;
            string linkPath = CodexDiscovery.CombineRelative(dsh, link.path);
            string targetPath = CodexDiscovery.CombineRelative(requirements.Package.NodeModules, link.fromCg);
            if (!Directory.Exists(targetPath)) throw new DirectoryNotFoundException("ChatGPT node module is missing: " + link.fromCg);
            if ((File.Exists(linkPath) || Directory.Exists(linkPath)) && !LinkUtility.IsReparsePoint(linkPath)) continue;
            LinkUtility.EnsureLink(linkPath, targetPath, true);
        }
    }

    private void EnsureAssetForks(CodexRequirements requirements)
    {
        foreach (CgAssetFork fork in requirements.Manifest.cgAssetForks)
        {
            if (fork == null || string.IsNullOrWhiteSpace(fork.path) || string.IsNullOrWhiteSpace(fork.fromPackage)) continue;
            string linkPath = CodexDiscovery.CombineRelative(dsh, fork.path);
            string targetPath = CodexDiscovery.CombineRelative(requirements.Package.InstallLocation, fork.fromPackage);
            bool directory = string.Equals(fork.type, "junction", StringComparison.OrdinalIgnoreCase) || Directory.Exists(targetPath);
            LinkUtility.EnsureLink(linkPath, targetPath, directory);
        }
        string nodePty = Path.Combine(dsh, "node_modules", "node-pty");
        foreach (string name in new[] { "third_party", "src", "deps" })
        {
            string path = Path.Combine(nodePty, name);
            if (Directory.Exists(path) && !LinkUtility.IsReparsePoint(path)) TryDeleteTree(path);
        }
    }

    private string GetOwlHostStaleReason(CodexPackage package)
    {
        string marked = File.Exists(owlMarker) ? File.ReadAllText(owlMarker, Encoding.UTF8).Trim().Trim('\uFEFF') : string.Empty;
        if (!string.Equals(marked, package.FullName, StringComparison.Ordinal)) return "package-marker:" + marked;
        string stub = Path.Combine(owlHost, "owl-stub.exe");
        string sourceStub = Path.Combine(package.AppDirectory, "ChatGPT.exe");
        if (!File.Exists(stub)) return "missing-owl-stub";
        if (new FileInfo(stub).Length != new FileInfo(sourceStub).Length) return "owl-stub-size-mismatch";
        string elf = Path.Combine(owlHost, "chrome_elf.dll");
        string sourceElf = Path.Combine(package.AppDirectory, "chrome_elf.dll");
        if (File.Exists(sourceElf) && (!File.Exists(elf) || new FileInfo(elf).Length != new FileInfo(sourceElf).Length)) return "chrome_elf-size-mismatch";
        string chrome = Path.Combine(owlHost, "chrome.dll");
        if (!File.Exists(chrome)) return "missing-chrome.dll";
        if (!LinkUtility.Targets(chrome, Path.Combine(package.AppDirectory, "chrome.dll"))) return "chrome.dll-stale-link";
        var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "resources", "owl-stub.exe", "chrome_elf.dll", ".codex-package-full-name", "debug.log", "owl-host.exe", "owl-host.c"
        };
        if (Directory.Exists(owlHost))
            foreach (string entry in Directory.GetFileSystemEntries(owlHost))
            {
                string name = Path.GetFileName(entry);
                if (keep.Contains(name) || name.EndsWith(".manifest", StringComparison.OrdinalIgnoreCase) || LinkUtility.IsReparsePoint(entry)) continue;
                if (!File.Exists(Path.Combine(package.AppDirectory, name)) && !Directory.Exists(Path.Combine(package.AppDirectory, name))) return "orphan-local:" + name;
            }
        return null;
    }

    private void SyncOwlHost(CodexPackage package)
    {
        Directory.CreateDirectory(owlHost);
        string hostResources = Path.Combine(owlHost, "resources");
        string packageResources = Path.Combine(package.AppDirectory, "resources");
        Directory.CreateDirectory(hostResources);
        string iniSource = Path.Combine(packageResources, "owl-app.ini");
        if (File.Exists(iniSource))
        {
            string ini = File.ReadAllText(iniSource, Encoding.UTF8);
            ini = System.Text.RegularExpressions.Regex.Replace(ini, "(?m)^UserDataDirectoryName=.*$", "UserDataDirectoryName=DshOwl");
            File.WriteAllText(Path.Combine(hostResources, "owl-app.ini"), ini, new UTF8Encoding(false));
        }
        CopyIfPresent(Path.Combine(packageResources, "owl-electron-app.json"), Path.Combine(hostResources, "owl-electron-app.json"));
        File.Copy(Path.Combine(package.AppDirectory, "ChatGPT.exe"), Path.Combine(owlHost, "owl-stub.exe"), true);
        CopyIfPresent(Path.Combine(package.AppDirectory, "chrome_elf.dll"), Path.Combine(owlHost, "chrome_elf.dll"));
        foreach (string manifest in Directory.GetFiles(owlHost, "*.manifest"))
            if (!File.Exists(Path.Combine(package.AppDirectory, Path.GetFileName(manifest)))) TryDeleteFile(manifest);
        foreach (string manifest in Directory.GetFiles(package.AppDirectory, "*.manifest"))
            File.Copy(manifest, Path.Combine(owlHost, Path.GetFileName(manifest)), true);
        RepairOwlHostLinks(package);
        RemoveOrphanOwlEntries(package);
        File.WriteAllText(owlMarker, package.FullName, new UTF8Encoding(false));
    }

    private void RepairOwlHostLinks(CodexPackage package)
    {
        var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "resources", "ChatGPT.exe", "chrome_elf.dll", "owl-stub.exe", "owl-host.exe", "owl-host.c", "debug.log", ".codex-package-full-name"
        };
        foreach (string entry in Directory.GetFileSystemEntries(package.AppDirectory))
        {
            string name = Path.GetFileName(entry);
            if (skip.Contains(name) || name.EndsWith(".manifest", StringComparison.OrdinalIgnoreCase)) continue;
            LinkUtility.EnsureLink(Path.Combine(owlHost, name), entry, Directory.Exists(entry));
        }
    }

    private void RemoveOrphanOwlEntries(CodexPackage package)
    {
        var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "resources", "ChatGPT.exe", "chrome_elf.dll", "owl-stub.exe", "owl-host.exe", "owl-host.c", "debug.log",
            ".codex-package-full-name", "dsh-desktop.json"
        };
        foreach (string entry in Directory.GetFileSystemEntries(owlHost))
        {
            string name = Path.GetFileName(entry);
            if (keep.Contains(name)) continue;
            string packagePath = Path.Combine(package.AppDirectory, name);
            if (!File.Exists(packagePath) && !Directory.Exists(packagePath)) LinkUtility.RemovePath(entry, !LinkUtility.IsReparsePoint(entry));
        }
    }

    private void AssertOwlHostReady(CodexPackage package)
    {
        string stub = Path.Combine(owlHost, "owl-stub.exe");
        string chrome = Path.Combine(owlHost, "chrome.dll");
        if (!File.Exists(stub)) throw new FileNotFoundException("owl-stub.exe is missing.", stub);
        if (!File.Exists(chrome) || !LinkUtility.Targets(chrome, Path.Combine(package.AppDirectory, "chrome.dll")))
            throw new InvalidOperationException("chrome.dll link is missing or stale.");
    }

    private bool AssertOwlUserDataAvailable()
    {
        foreach (ProcessRecord process in ProcessUtility.Query(null))
        {
            if (string.Equals(process.Name, "owl-stub.exe", StringComparison.OrdinalIgnoreCase)) continue;
            if ((process.CommandLine ?? string.Empty).IndexOf(owlUserData, StringComparison.OrdinalIgnoreCase) < 0) continue;
            MessageBox.Show("DSH profile is already occupied by another process.\r\n\r\n" + owlUserData
                + "\r\n\r\nClose that process and try again. Existing ChatGPT.exe processes will not be touched.",
                "DeepSeek Harness (on ChatGPT) cannot start", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
        return true;
    }

    private ProcessRecord FindOwlParent()
    {
        string stub = Path.Combine(owlHost, "owl-stub.exe");
        foreach (ProcessRecord process in ProcessUtility.Query("Name='owl-stub.exe'"))
            if (string.Equals(process.ExecutablePath, stub, StringComparison.OrdinalIgnoreCase)
                && (process.CommandLine ?? string.Empty).IndexOf("--type=", StringComparison.OrdinalIgnoreCase) < 0) return process;
        return null;
    }

    private void StopOwlStub()
    {
        string prefix = owlHost.TrimEnd('\\') + "\\";
        foreach (ProcessRecord process in ProcessUtility.Query("Name='owl-stub.exe'"))
            if ((process.ExecutablePath ?? string.Empty).StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) ProcessUtility.KillTree(process.Id);
        Thread.Sleep(700);
    }

    private void StopDshNode()
    {
        foreach (ProcessRecord process in ProcessUtility.Query("Name='node.exe'"))
        {
            string commandLine = process.CommandLine ?? string.Empty;
            if (commandLine.IndexOf(dsh, StringComparison.OrdinalIgnoreCase) >= 0
                && commandLine.IndexOf("--profile web", StringComparison.OrdinalIgnoreCase) >= 0) ProcessUtility.KillTree(process.Id);
        }
    }

    private void StopWatchers()
    {
        foreach (ProcessRecord process in ProcessUtility.Query(null))
        {
            if (!string.Equals(process.ExecutablePath, launcherPath, StringComparison.OrdinalIgnoreCase)) continue;
            string commandLine = process.CommandLine ?? string.Empty;
            if (commandLine.IndexOf(" watch ", StringComparison.OrdinalIgnoreCase) >= 0
                && commandLine.IndexOf(dsh, StringComparison.OrdinalIgnoreCase) >= 0) ProcessUtility.KillTree(process.Id);
        }
    }

    private void WaitForDshExit(int timeoutMilliseconds)
    {
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMilliseconds);
        string prefix = owlHost.TrimEnd('\\') + "\\";
        while (DateTime.UtcNow < deadline)
        {
            bool running = false;
            foreach (ProcessRecord process in ProcessUtility.Query(null))
            {
                string executable = process.ExecutablePath ?? string.Empty;
                string commandLine = process.CommandLine ?? string.Empty;
                if ((string.Equals(process.Name, "owl-stub.exe", StringComparison.OrdinalIgnoreCase)
                        && executable.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    || (string.Equals(process.Name, "node.exe", StringComparison.OrdinalIgnoreCase)
                        && commandLine.IndexOf(dsh, StringComparison.OrdinalIgnoreCase) >= 0)
                    || (string.Equals(executable, launcherPath, StringComparison.OrdinalIgnoreCase)
                        && commandLine.IndexOf(" watch ", StringComparison.OrdinalIgnoreCase) >= 0))
                {
                    running = true;
                    break;
                }
            }
            if (!running) return;
            Thread.Sleep(150);
        }
    }

    private void RestoreTaskbarIcon()
    {
        if (File.Exists(taskbarIcon))
        {
            try { ProcessUtility.StartHidden(taskbarIcon, "restore", runtime, null).WaitForExit(); } catch { }
        }
        ProcessUtility.KillByName("dsh-taskbar-icon", "dsh-taskbar-host");
    }

    private void RemoveManifestLinks(ReleaseManifest manifest)
    {
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (WorkspaceLink link in manifest.workspaceLinks) if (link != null && !string.IsNullOrWhiteSpace(link.path)) paths.Add(link.path);
        foreach (CgJunction link in manifest.cgJunctions) if (link != null && !string.IsNullOrWhiteSpace(link.path)) paths.Add(link.path);
        foreach (CgAssetFork link in manifest.cgAssetForks) if (link != null && !string.IsNullOrWhiteSpace(link.path)) paths.Add(link.path);
        var ordered = new List<string>(paths);
        ordered.Sort(delegate(string left, string right) { return right.Length.CompareTo(left.Length); });
        foreach (string relative in ordered)
        {
            string path = CodexDiscovery.CombineRelative(dsh, relative);
            if (LinkUtility.IsReparsePoint(path)) LinkUtility.RemovePath(path, false);
        }
    }

    private static bool IsPortListening(int port)
    {
        try
        {
            using (var client = new TcpClient())
            {
                IAsyncResult result = client.BeginConnect("127.0.0.1", port, null, null);
                return result.AsyncWaitHandle.WaitOne(300) && client.Connected;
            }
        }
        catch { return false; }
    }

    private static void RequireAdministrator()
    {
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
        {
            var principal = new WindowsPrincipal(identity);
            if (!principal.IsInRole(WindowsBuiltInRole.Administrator)) throw new UnauthorizedAccessException("Administrator permission is required.");
        }
    }

    private static void CopyIfPresent(string source, string destination)
    {
        if (File.Exists(source)) File.Copy(source, destination, true);
    }

    private static void TryDeleteFile(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private static void TryDeleteTree(string path)
    {
        try { if (Directory.Exists(path)) LinkUtility.DeleteTreeWithoutFollowingLinks(path); } catch { }
    }

    private static void RunUtility(string fileName, string arguments)
    {
        try { ProcessUtility.StartHidden(fileName, arguments, Environment.CurrentDirectory, null).WaitForExit(); } catch { }
    }

    private static void WriteResult(string path, string message)
    {
        if (!string.IsNullOrWhiteSpace(path)) File.WriteAllText(path, message, new UTF8Encoding(false));
        Console.WriteLine(message);
    }

    private static void WriteInfo(string message)
    {
        Console.WriteLine("[DSH] " + message);
    }
}
