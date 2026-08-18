using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.Win32;

internal sealed class ReleaseManifest
{
    public string version { get; set; }
    public string entry { get; set; }
    public int port { get; set; }
    public List<WorkspaceLink> workspaceLinks { get; set; }
    public List<CgJunction> cgJunctions { get; set; }
    public List<CgAssetFork> cgAssetForks { get; set; }

    public static ReleaseManifest Load(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("Release manifest is missing.", path);
        var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        ReleaseManifest manifest = serializer.Deserialize<ReleaseManifest>(File.ReadAllText(path, Encoding.UTF8));
        if (manifest == null) throw new InvalidDataException("Release manifest is invalid.");
        if (manifest.workspaceLinks == null) manifest.workspaceLinks = new List<WorkspaceLink>();
        if (manifest.cgJunctions == null) manifest.cgJunctions = new List<CgJunction>();
        if (manifest.cgAssetForks == null) manifest.cgAssetForks = new List<CgAssetFork>();
        if (manifest.port == 0) manifest.port = 3080;
        if (string.IsNullOrWhiteSpace(manifest.entry)) manifest.entry = "apps/cli/lib/bin.js";
        return manifest;
    }
}

internal sealed class WorkspaceLink
{
    public string path { get; set; }
    public string target { get; set; }
}

internal sealed class CgJunction
{
    public string path { get; set; }
    public string fromCg { get; set; }
}

internal sealed class CgAssetFork
{
    public string path { get; set; }
    public string fromPackage { get; set; }
    public string type { get; set; }
}

internal sealed class CodexPackage
{
    public string FullName { get; private set; }
    public string FamilyName { get; private set; }
    public string InstallLocation { get; private set; }
    public Version Version { get; private set; }
    public string AppDirectory { get { return Path.Combine(InstallLocation, "app"); } }
    public string NodePath { get { return Path.Combine(AppDirectory, "resources", "cua_node", "bin", "node.exe"); } }
    public string NodeModules { get { return Path.Combine(AppDirectory, "resources", "cua_node", "bin", "node_modules"); } }

    public CodexPackage(string fullName, string installLocation)
    {
        FullName = fullName;
        InstallLocation = installLocation;
        string[] parts = fullName.Split('_');
        Version parsed;
        Version = parts.Length > 1 && System.Version.TryParse(parts[1], out parsed) ? parsed : new Version(0, 0);
        FamilyName = parts.Length >= 5 ? parts[0] + "_" + parts[parts.Length - 1] : fullName;
    }
}

internal sealed class CodexRequirements
{
    public CodexPackage Package { get; private set; }
    public ReleaseManifest Manifest { get; private set; }

    public CodexRequirements(CodexPackage package, ReleaseManifest manifest)
    {
        Package = package;
        Manifest = manifest;
    }
}

internal static class CodexDiscovery
{
    private const string PackagesKey = @"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages";

    public static CodexRequirements Validate(string manifestPath)
    {
        ReleaseManifest manifest = ReleaseManifest.Load(manifestPath);
        AppxBridge.AssertAvailable();
        CodexPackage package = FindCurrentPackage();
        var errors = new List<string>();
        if (package == null)
        {
            errors.Add("Microsoft Store ChatGPT/Codex (OpenAI.Codex) is not installed for this user.");
        }
        else
        {
            RequirePath(package.NodePath, false, errors);
            RequirePath(package.NodeModules, true, errors);
            RequirePath(Path.Combine(package.AppDirectory, "ChatGPT.exe"), false, errors);
            RequirePath(Path.Combine(package.AppDirectory, "chrome.dll"), false, errors);
            foreach (CgJunction junction in manifest.cgJunctions)
            {
                if (junction == null || string.IsNullOrWhiteSpace(junction.fromCg)) continue;
                string target = CombineRelative(package.NodeModules, junction.fromCg);
                if (!Directory.Exists(target)) errors.Add("Missing ChatGPT node module: " + junction.fromCg);
            }
            foreach (CgAssetFork fork in manifest.cgAssetForks)
            {
                if (fork == null || string.IsNullOrWhiteSpace(fork.fromPackage)) continue;
                string target = CombineRelative(package.InstallLocation, fork.fromPackage);
                bool exists = string.Equals(fork.type, "junction", StringComparison.OrdinalIgnoreCase)
                    ? Directory.Exists(target)
                    : File.Exists(target) || Directory.Exists(target);
                if (!exists) errors.Add("Missing ChatGPT asset fork target: " + fork.fromPackage);
            }
        }
        if (errors.Count != 0) throw new InvalidOperationException(string.Join(Environment.NewLine, errors.ConvertAll(delegate(string value) { return "- " + value; }).ToArray()));
        return new CodexRequirements(package, manifest);
    }

    public static CodexPackage FindCurrentPackage()
    {
        var packages = new List<CodexPackage>();
        using (RegistryKey root = Registry.CurrentUser.OpenSubKey(PackagesKey))
        {
            if (root == null) return null;
            foreach (string name in root.GetSubKeyNames())
            {
                if (!name.StartsWith("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase)) continue;
                using (RegistryKey packageKey = root.OpenSubKey(name))
                {
                    string location = packageKey == null ? null : packageKey.GetValue("PackageRootFolder") as string;
                    if (!string.IsNullOrWhiteSpace(location) && Directory.Exists(Path.Combine(location, "app")))
                        packages.Add(new CodexPackage(name, location));
                }
            }
        }
        packages.Sort(delegate(CodexPackage left, CodexPackage right) { return right.Version.CompareTo(left.Version); });
        return packages.Count == 0 ? null : packages[0];
    }

    public static string CombineRelative(string root, string relative)
    {
        return Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
    }

    private static void RequirePath(string path, bool directory, List<string> errors)
    {
        bool exists = directory ? Directory.Exists(path) : File.Exists(path);
        if (!exists) errors.Add("Missing ChatGPT runtime path: " + path);
    }
}
