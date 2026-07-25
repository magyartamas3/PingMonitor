using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class PingMonitorGuiLauncher
{
    [STAThread]
    private static int Main()
    {
        string applicationFolder = AppDomain.CurrentDomain.BaseDirectory;
        string scriptPath = Path.Combine(applicationFolder, "PingMonitorGUI.ps1");

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show(
                "A PingMonitorGUI.ps1 nem található az EXE mappájában.\n\n" +
                "Az EXE-t és a scriptet ugyanabban a mappában kell tartani.",
                "PingMonitor indítási hiba",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }

        string powershellPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell\\v1.0\\powershell.exe");

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = powershellPath,
                Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
                WorkingDirectory = applicationFolder,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            return 0;
        }
        catch (Exception exception)
        {
            MessageBox.Show(
                "A PingMonitor nem indítható el.\n\n" + exception.Message,
                "PingMonitor indítási hiba",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }
}
