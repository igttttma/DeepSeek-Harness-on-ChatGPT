using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

internal static class DeepSeekHarnessLauncher
{
    private const string ProductName = "DeepSeek Harness (on ChatGPT)";

    [STAThread]
    private static int Main(string[] args)
    {
        string command = args.Length == 0 ? "start" : args[0].ToLowerInvariant();
        try
        {
            switch (command)
            {
                case "start":
                    int prepareResult = RunElevatedController("apply-forks", "prepare-elevated");
                    return prepareResult == 0 ? RunController("start", true) : prepareResult;
                case "stop":
                    return RunController("stop", false);
                case "prepare":
                    return RunElevatedController("apply-forks", "prepare-elevated");
                case "cleanup":
                    return RunElevatedController("cleanup", "cleanup-elevated");
                case "uninstall":
                    return RunElevatedController("uninstall", "uninstall-elevated");
                case "prepare-elevated":
                    return RunPrivilegedController("apply-forks");
                case "cleanup-elevated":
                    return RunPrivilegedController("cleanup");
                case "uninstall-elevated":
                    return RunPrivilegedController("uninstall");
                default:
                    ShowError("Unknown command: " + command);
                    return 64;
            }
        }
        catch (Win32Exception exception)
        {
            if (exception.NativeErrorCode == 1223)
            {
                ShowError("Administrator permission was cancelled.");
                return 1223;
            }
            ShowError(exception.Message);
            return exception.NativeErrorCode == 0 ? 1 : exception.NativeErrorCode;
        }
        catch (Exception exception)
        {
            ShowError(exception.ToString());
            return 1;
        }
    }

    private static int RunElevatedController(string action, string elevatedCommand)
    {
        if (IsAdministrator())
        {
            return RunController(action, true);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = Application.ExecutablePath,
            Arguments = elevatedCommand,
            WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory,
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        using (Process process = Process.Start(startInfo))
        {
            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static int RunPrivilegedController(string action)
    {
        if (!IsAdministrator())
        {
            ShowError("Administrator permission is required.");
            return 5;
        }
        return RunController(action, true);
    }

    private static bool IsAdministrator()
    {
        WindowsIdentity identity = WindowsIdentity.GetCurrent();
        WindowsPrincipal principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static int RunController(string action, bool showFailure)
    {
        string installRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        string controller = Path.Combine(installRoot, "parasite-runtime", "dsh.ps1");
        if (!File.Exists(controller))
        {
            ShowError("Runtime controller is missing:\r\n" + controller);
            return 2;
        }

        string powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");
        var startInfo = new ProcessStartInfo
        {
            FileName = powershell,
            Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(controller) + " " + action,
            WorkingDirectory = installRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        var output = new StringBuilder();
        using (Process process = new Process { StartInfo = startInfo })
        {
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
            {
                if (eventArgs.Data != null) output.AppendLine(eventArgs.Data);
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
            {
                if (eventArgs.Data != null) output.AppendLine(eventArgs.Data);
            };
            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            process.WaitForExit();
            process.WaitForExit();
            if (process.ExitCode != 0 && showFailure)
            {
                string details = output.ToString().Trim();
                ShowError(details.Length == 0
                    ? "DSH failed with exit code " + process.ExitCode + "."
                    : details);
            }
            return process.ExitCode;
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void ShowError(string message)
    {
        MessageBox.Show(message, ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
