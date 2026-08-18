using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

internal static class DeepSeekHarnessLauncher
{
    private const string ProductName = "DeepSeek Harness (on ChatGPT)";
    private const string InstanceMutexName = @"Local\DeepSeekHarnessOnChatGPT.Instance";

    [STAThread]
    private static int Main(string[] args)
    {
        string command = args.Length == 0 ? "start" : args[0].ToLowerInvariant();
        string installRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(System.IO.Path.DirectorySeparatorChar);
        var controller = new RuntimeController(installRoot, Application.ExecutablePath);
        try
        {
            switch (command)
            {
                case "start":
                    return RunStart(controller);
                case "stop":
                    return controller.Stop();
                case "stop-backend":
                    return controller.StopBackend();
                case "prepare":
                    return RunElevated("prepare-elevated");
                case "cleanup":
                    return RunElevated("cleanup-elevated");
                case "uninstall":
                    return RunElevated("uninstall-elevated");
                case "prepare-elevated":
                    return RunPrivileged(controller.ApplyForks);
                case "cleanup-elevated":
                    return RunPrivileged(controller.Cleanup);
                case "uninstall-elevated":
                    return RunPrivileged(controller.Uninstall);
                case "package-node":
                    if (args.Length != 6) return 64;
                    return RuntimeController.LaunchPackagedNode(args[1], args[2], args[3], args[4], int.Parse(args[5]));
                case "watch":
                    if (args.Length != 3) return 64;
                    return DirectoryDialogWatcher.Run(int.Parse(args[1]), args[2]);
                case "preflight":
                    if (args.Length < 2 || args.Length > 3) return 64;
                    return RuntimeController.Preflight(args[1], args.Length == 3 ? args[2] : string.Empty);
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

    private static int RunStart(RuntimeController controller)
    {
        using (var mutex = new Mutex(false, InstanceMutexName))
        {
            bool acquired;
            try { acquired = mutex.WaitOne(0, false); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired)
            {
                ShowError("DeepSeek Harness (on ChatGPT) is already running.\r\n\r\nClose the installed or portable instance before starting another one.");
                return 16;
            }
            try
            {
                int prepareResult = RunElevated("prepare-elevated");
                if (prepareResult != 0) return prepareResult;
                int startResult = controller.Start();
                if (startResult == 0) controller.WaitForShellExit();
                return startResult;
            }
            finally
            {
                mutex.ReleaseMutex();
            }
        }
    }

    private static int RunElevated(string elevatedCommand)
    {
        if (IsAdministrator())
        {
            return Main(new[] { elevatedCommand });
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

    private static int RunPrivileged(Func<int> action)
    {
        if (!IsAdministrator())
        {
            ShowError("Administrator permission is required.");
            return 5;
        }
        return action();
    }

    private static bool IsAdministrator()
    {
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent())
        {
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    private static void ShowError(string message)
    {
        MessageBox.Show(message, ProductName, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
