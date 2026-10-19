using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

class ProcessFixture
{
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo
    {
        public int cb; public string reserved, desktop, title;
        public int x, y, width, height, xChars, yChars, fill, flags;
        public short show, reservedBytes; public IntPtr reservedPointer, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process, thread; public int id, threadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string application, StringBuilder arguments, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo process);
    static void Main(string[] args)
    {
        string mode = args.Length > 0 ? args[0] : File.ReadAllText("mode.txt").Trim();
        if (mode == "sleep") { Thread.Sleep(15000); return; }
        File.WriteAllText("root.pid", Process.GetCurrentProcess().Id.ToString());
        if (mode == "counter")
        {
            string request = Console.In.ReadToEnd();
            string id = Regex.Match(request, "\"requestId\"\\s*:\\s*\"([^\"]+)\"").Groups[1].Value;
            string operation = Regex.Match(request, "\"operation\"\\s*:\\s*\"([^\"]+)\"").Groups[1].Value;
            File.AppendAllText("operations.log", operation + "|" + Process.GetCurrentProcess().Id + "@" + Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks + "\n");
            Console.Out.Write("{\"protocolVersion\":1,\"requestId\":\"" + id + "\",\"status\":\"" + (operation == "preview" ? "Planned" : "Succeeded") + "\",\"output\":{},\"diagnostics\":[]}");
            return;
        }
        if (mode == "noinput") { Thread.Sleep(15000); return; }
        if (mode == "bad")
        {
            Console.In.ReadToEnd();
            // No inherited handles: the response reaches EOF while this child
            // remains alive. The orphan mode separately tests inherited pipes.
            var startup = new StartupInfo(); startup.cb = Marshal.SizeOf(startup);
            ProcessInfo child;
            string exe = Process.GetCurrentProcess().MainModule.FileName;
            if (!CreateProcess(exe, new StringBuilder("\"" + exe + "\" sleep"), IntPtr.Zero,
                IntPtr.Zero, false, 0x08000000, IntPtr.Zero, Environment.CurrentDirectory, ref startup, out child))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            File.WriteAllText("child.pid", child.id.ToString());
            CloseHandle(child.process); CloseHandle(child.thread);
            Console.Out.Write("not-json"); Console.Out.Flush(); return;
        }
        if (mode == "orphan")
        {
            var start = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "sleep");
            start.UseShellExecute = false; start.CreateNoWindow = true;
            var child = Process.Start(start);
            File.WriteAllText("child.pid", child.Id.ToString());
            child.Dispose();
            return;
        }
        if (mode == "duplex")
        {
            Console.OutputEncoding = new UTF8Encoding(false);
            var header = new StringBuilder();
            for (int i = 0; i < 512; i++) { int c = Console.In.Read(); if (c < 0) break; header.Append((char)c); }
            string id = Regex.Match(header.ToString(), "\"requestId\"\\s*:\\s*\"([^\"]+)\"").Groups[1].Value;
            Console.Out.Write("{\"protocolVersion\":1,\"requestId\":\"" + id + "\",\"status\":\"Succeeded\",\"output\":{\"blob\":\"");
            Console.Out.Write(new string('x', 1024 * 1024));
            Console.Out.Write("\"},\"diagnostics\":[]}"); Console.Out.Flush();
            Console.In.ReadToEnd();
        }
    }
}
