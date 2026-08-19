using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class DeepSeekHarnessLauncher
{
    private const string ProductName = "DeepSeek Harness (on ChatGPT)";
    private const string InstanceMutexName = @"Local\DeepSeekHarnessOnChatGPT.Instance";
    private const string ActivationEventPrefix = @"Local\DeepSeekHarnessOnChatGPT.Activate.";

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
                case "terminal":
                    return controller.OpenTerminal();
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
                case "package-terminal":
                    if (args.Length != 5) return 64;
                    return RuntimeController.LaunchPackagedTerminal(args[1], args[2], args[3], args[4]);
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
                if (SignalExistingInstance(controller)) return 0;
                ShowError("DeepSeek Harness (on ChatGPT) is already running.\r\n\r\nClose the installed or portable instance before starting another one.");
                return 16;
            }
            using (var activationEvent = new EventWaitHandle(false, EventResetMode.AutoReset, GetActivationEventName()))
            using (var listenerStop = new ManualResetEvent(false))
            {
                var listener = new Thread(delegate()
                {
                    WaitHandle[] handles = { activationEvent, listenerStop };
                    while (WaitHandle.WaitAny(handles) == 0)
                    {
                        try { controller.ActivateShellWindow(); } catch { }
                    }
                });
                listener.IsBackground = true;
                listener.Name = "DSH activation listener";
                listener.Start();
                try
                {
                    int prepareResult = RunElevated("prepare-elevated");
                    if (prepareResult != 0) return prepareResult;
                    int startResult = controller.Start();
                    if (startResult == 0)
                    {
                        controller.WaitForShellExit();
                        controller.StopAfterShellExit();
                    }
                    return startResult;
                }
                finally
                {
                    listenerStop.Set();
                    listener.Join(1000);
                    mutex.ReleaseMutex();
                }
            }
        }
    }

    private static bool SignalExistingInstance(RuntimeController controller)
    {
        string eventName = GetActivationEventName();
        for (int attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                using (EventWaitHandle activationEvent = EventWaitHandle.OpenExisting(eventName))
                {
                    controller.AuthorizeShellForeground();
                    return activationEvent.Set();
                }
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                Thread.Sleep(100);
            }
            catch (UnauthorizedAccessException)
            {
                return false;
            }
        }
        return false;
    }

    private static string GetActivationEventName()
    {
        string executable = Path.GetFullPath(Application.ExecutablePath).ToUpperInvariant();
        using (SHA256 hash = SHA256.Create())
        {
            string identity = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(executable))).Replace("-", string.Empty);
            return ActivationEventPrefix + identity;
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
