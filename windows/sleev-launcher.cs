// Sleev launcher: route Claude Desktop's native Windows sessions through the
// local Sleev gateway.
//
// The app injects ANTHROPIC_BASE_URL=https://api.anthropic.com into every
// session's environment, and that beats the settings.json env block (tested
// 2026-10-17). So sleev-watch.ps1 renames each claude.exe the app installs to
// claude.sleev-real.exe and puts this program in its place. It sets the
// gateway env, tags the model, and runs the real binary with the same stdio.
//
// Built by install.ps1 with the csc.exe that ships with .NET Framework 4, so
// it sticks to C# 5.

using System;
using System.ComponentModel;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;

// sleev-watch.ps1 tells the launcher apart from the app's binaries by this.
[assembly: AssemblyProduct("sleev-launcher")]

static class SleevLauncher
{
    const string GatewayUrl = "http://127.0.0.1:17321";
    const string Headers = "sleev-provider: anthropic\nsleev-harness: claude code";

    static int Main()
    {
        string dir = Path.GetDirectoryName(Assembly.GetEntryAssembly().Location);
        string real = Path.Combine(dir, "claude.sleev-real.exe");
        string state = Path.Combine(Environment.GetFolderPath(
            Environment.SpecialFolder.LocalApplicationData), "sleev-shim");

        // The probe decides once for the whole life of the session; a lost probe
        // means a silently uncaptured session. Hence a real timeout, retries,
        // and a fallback that announces itself (same as the WSL shim).
        bool routed = GatewayUp();
        if (routed)
        {
            Environment.SetEnvironmentVariable("ANTHROPIC_BASE_URL", GatewayUrl);
            Environment.SetEnvironmentVariable("ANTHROPIC_CUSTOM_HEADERS", Headers);
        }
        else
        {
            Log(state, "gateway unreachable after 3 tries; session running DIRECT (uncaptured) pid="
                + System.Diagnostics.Process.GetCurrentProcess().Id);
            Console.Error.WriteLine("[sleev-launcher] gateway unreachable after 3 tries, running DIRECT (uncaptured)");
        }

        string cmd = "\"" + real + "\"" + TagModel(ArgsAfterProgramName(Environment.CommandLine));
        try
        {
            int pid;
            IntPtr process = Start(real, cmd, out pid);
            // Lets sleev-watch.ps1 spot a gateway-down session, since it can't
            // read another process's environment.
            string marker = routed ? null : MarkDirect(state, pid);
            try
            {
                WaitForSingleObject(process, 0xFFFFFFFF);
                uint code;
                GetExitCodeProcess(process, out code);
                return (int)code;
            }
            finally
            {
                // Pids get reused; a leftover marker would mislabel a later session.
                if (marker != null) try { File.Delete(marker); } catch (Exception) { }
            }
        }
        catch (Exception e)
        {
            Log(state, "could not start " + real + ": " + e.Message);
            Console.Error.WriteLine("[sleev-launcher] could not start " + real + ": " + e.Message);
            return 1;
        }
    }

    static bool GatewayUp()
    {
        for (int i = 0; i < 3; i++)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(GatewayUrl + "/");
                req.Proxy = null;
                req.Timeout = 3000;
                // A pooled keep-alive socket would be inherited by the session.
                req.KeepAlive = false;
                using (req.GetResponse()) { }
                return true;
            }
            catch (WebException e)
            {
                // Any HTTP answer, even an error status, means it is listening.
                if (e.Response != null) { e.Response.Close(); return true; }
            }
            catch (Exception) { }
            Thread.Sleep(400);
        }
        return false;
    }

    // Everything after argv[0], kept verbatim so the real binary parses the
    // same arguments the app sent. argv[0] ends at the closing quote if it is
    // quoted, else at the first space or tab.
    static string ArgsAfterProgramName(string cmd)
    {
        int i = 0;
        if (cmd.StartsWith("\""))
        {
            i = cmd.IndexOf('"', 1);
            i = i < 0 ? cmd.Length : i + 1;
        }
        else
        {
            while (i < cmd.Length && cmd[i] != ' ' && cmd[i] != '\t') i++;
        }
        return cmd.Substring(i);
    }

    // The app passes the model as --model=<id> and offers no way to ask for the
    // extended 1M context window, so sessions auto-compact at ~168k tokens.
    // Append [1m] to whatever model it chose, except haiku (200K only).
    // To disable: return args unchanged.
    static string TagModel(string args)
    {
        var re = new Regex("(?<=(^|\\s)\"?--model(=|\\s+)\"?)[^\\s\"]+");
        return re.Replace(args, delegate(Match m)
        {
            string v = m.Value;
            if (v.EndsWith("[1m]") || v.IndexOf("haiku", StringComparison.OrdinalIgnoreCase) >= 0) return v;
            return v + "[1m]";
        }, 1);
    }

    // Start the real binary suspended, put it in a kill-on-close job so it dies
    // with this launcher (the app stops a session by killing the process it
    // spawned, which is us), then let it run. It gets our stdio handles.
    // Breakaway is allowed so only the session itself is in the job: its
    // shells, MCP servers and background commands outlive it just as they do
    // when the app starts the CLI directly.
    static IntPtr Start(string exe, string cmd, out int pid)
    {
        var si = new STARTUPINFO();
        si.cb = Marshal.SizeOf(si);
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = Inheritable(GetStdHandle(STD_INPUT_HANDLE));
        si.hStdOutput = Inheritable(GetStdHandle(STD_OUTPUT_HANDLE));
        si.hStdError = Inheritable(GetStdHandle(STD_ERROR_HANDLE));

        // Share our console; only if we have none would the child pop a window.
        uint flags = CREATE_SUSPENDED;
        if (GetConsoleWindow() == IntPtr.Zero) flags |= CREATE_NO_WINDOW;

        PROCESS_INFORMATION pi;
        if (!CreateProcess(exe, cmd, IntPtr.Zero, IntPtr.Zero, true, flags,
                IntPtr.Zero, null, ref si, out pi))
            throw new Win32Exception();

        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            | JOB_OBJECT_LIMIT_BREAKAWAY_OK | JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
        if (job == IntPtr.Zero
            || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf(info))
            || !AssignProcessToJobObject(job, pi.hProcess))
        {
            // Better a session that may outlive us than no session at all.
            Console.Error.WriteLine("[sleev-launcher] job object setup failed: " + new Win32Exception().Message);
        }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        pid = pi.dwProcessId;
        return pi.hProcess;
    }

    static IntPtr Inheritable(IntPtr h)
    {
        if (h != IntPtr.Zero && h != new IntPtr(-1))
            SetHandleInformation(h, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
        return h;
    }

    static string MarkDirect(string state, int pid)
    {
        try
        {
            string d = Path.Combine(state, "direct");
            Directory.CreateDirectory(d);
            string m = Path.Combine(d, pid.ToString());
            File.WriteAllText(m, "");
            return m;
        }
        catch (Exception) { return null; }
    }

    static void Log(string state, string msg)
    {
        try
        {
            Directory.CreateDirectory(state);
            File.AppendAllText(Path.Combine(state, "shim-fallback.log"),
                DateTime.Now.ToString("s") + " " + msg + Environment.NewLine);
        }
        catch (Exception) { }
    }

    const int STD_INPUT_HANDLE = -10, STD_OUTPUT_HANDLE = -11, STD_ERROR_HANDLE = -12;
    const int STARTF_USESTDHANDLES = 0x100;
    const uint CREATE_SUSPENDED = 0x4, CREATE_NO_WINDOW = 0x08000000;
    const uint HANDLE_FLAG_INHERIT = 0x1;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000, JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x800,
        JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x1000;
    const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount,
            ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
        uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int cls,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int len);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
    [DllImport("kernel32.dll")] static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
}
