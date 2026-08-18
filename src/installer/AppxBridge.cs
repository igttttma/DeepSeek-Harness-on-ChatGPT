using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Text;

internal static class AppxBridge
{
    public static void AssertAvailable()
    {
        using (PowerShell shell = PowerShell.Create())
        {
            shell.AddCommand("Get-Command")
                .AddParameter("Name", "Invoke-CommandInDesktopPackage")
                .AddParameter("ErrorAction", "Stop");
            shell.Invoke();
            if (shell.HadErrors) throw new InvalidOperationException("Windows Appx command bridge is unavailable.");
        }
    }

    public static void Invoke(string packageFamilyName, string command, string arguments)
    {
        using (PowerShell shell = PowerShell.Create())
        {
            shell.AddCommand("Invoke-CommandInDesktopPackage")
                .AddParameter("PackageFamilyName", packageFamilyName)
                .AddParameter("AppId", "App")
                .AddParameter("Command", command)
                .AddParameter("Args", arguments ?? string.Empty)
                .AddParameter("PreventBreakaway");
            shell.Invoke();
            if (!shell.HadErrors) return;
            var messages = new List<string>();
            foreach (ErrorRecord error in shell.Streams.Error) messages.Add(error.ToString());
            throw new InvalidOperationException(messages.Count == 0
                ? "The Windows Appx command bridge failed."
                : string.Join(Environment.NewLine, messages.ToArray()));
        }
    }
}
