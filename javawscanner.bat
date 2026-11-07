@echo off
title Javaw Mod Scanner
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText('%~f0'); $i=$s.IndexOf('#PS#'+'START'); iex $s.Substring($i)"
echo.
pause
exit /b
#PS#START
$ErrorActionPreference = 'SilentlyContinue'
$global:rep = New-Object System.Collections.Generic.List[string]
function W($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c; $global:rep.Add($t) }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
public static class JScan {
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int a, bool b, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
  [DllImport("kernel32.dll")] static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr addr, out MBI mbi, IntPtr len);
  [StructLayout(LayoutKind.Sequential)]
  struct MBI {
    public IntPtr BaseAddress; public IntPtr AllocationBase; public uint AllocationProtect;
    public ushort PartitionId; public IntPtr RegionSize; public uint State; public uint Protect; public uint Type;
  }
  static Regex R = new Regex(@"[A-Za-z]:\\[\x20-\x7E]{3,260}?\.(?:jar|dll)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
  static void Add(HashSet<string> res, string s) {
    foreach (Match mt in R.Matches(s)) {
      string v = mt.Value; int st = 0;
      for (int i = v.Length - 3; i >= 0; i--) {
        if (v[i + 1] == ':' && v[i + 2] == '\\' && Char.IsLetter(v[i])) { st = i; break; }
      }
      res.Add(v.Substring(st).Trim());
    }
  }
  public static HashSet<string> Scan(int pid) {
    var res = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) return res;
    long addr = 0; MBI m; IntPtr sz = (IntPtr)Marshal.SizeOf(typeof(MBI));
    byte[] buf = new byte[8 * 1024 * 1024];
    Encoding latin = Encoding.GetEncoding(28591);
    while (VirtualQueryEx(h, (IntPtr)addr, out m, sz) != IntPtr.Zero) {
      long b = (long)m.BaseAddress, len = (long)m.RegionSize;
      if (len <= 0) break;
      // committed, readable, private memory only (heap / native strings)
      if (m.State == 0x1000 && m.Type == 0x20000 && m.Protect != 0 && (m.Protect & 0x101) == 0) {
        long off = 0;
        while (off < len) {
          int want = (int)Math.Min((long)buf.Length, len - off);
          IntPtr rd;
          if (!ReadProcessMemory(h, (IntPtr)(b + off), buf, (IntPtr)want, out rd) || (long)rd <= 0) break;
          int n = (int)rd;
          Add(res, latin.GetString(buf, 0, n));
          Add(res, Encoding.Unicode.GetString(buf, 0, n & ~1));
          if (off + n >= len) break;
          off += ((n - 1024) & ~1);
        }
      }
      addr = b + len;
    }
    CloseHandle(h);
    return res;
  }
}
'@

function Get-Source($f) {
  $z = Get-Content -LiteralPath $f -Stream Zone.Identifier -ErrorAction SilentlyContinue
  if (-not $z) { return 'no download info (not marked by a browser / copied / extracted)' }
  $h = ($z | ? { $_ -like 'HostUrl=*' }) -replace '^HostUrl=', ''
  $r = ($z | ? { $_ -like 'ReferrerUrl=*' }) -replace '^ReferrerUrl=', ''
  $s = ''
  if ($h) { $s += "downloaded from: $h" }
  if ($r) { $s += "  (page: $r)" }
  if (-not $s) { $s = 'marked as downloaded, but no URL stored' }
  return $s
}
function Fmt-Size($b) { if ($b -ge 1MB) { '{0:N2} MB' -f ($b / 1MB) } else { '{0:N1} KB' -f ($b / 1KB) } }

$procs = Get-CimInstance Win32_Process | ? { $_.Name -in 'javaw.exe', 'java.exe' }
if (-not $procs) {
  W 'No javaw.exe / java.exe process found. Start Minecraft first, then run this again.' Red
  return
}

foreach ($pr in $procs) {
  $p = [Diagnostics.Process]::GetProcessById($pr.ProcessId)
  W ''
  W ('=' * 78) Cyan
  W ("PROCESS: $($pr.Name)   PID: $($pr.ProcessId)   RAM: $([math]::Round($p.WorkingSet64/1MB)) MB   Started: $($p.StartTime)") Cyan
  W ('=' * 78) Cyan
  $cmd = $pr.CommandLine
  $agents = [regex]::Matches($cmd, '-javaagent:[^\s"]+') | % { $_.Value }
  $gd = [regex]::Match($cmd, '--gameDir\s+"?([^"]+?)"?(\s--|$)').Groups[1].Value
  $ver = [regex]::Match($cmd, '--version\s+(\S+)').Groups[1].Value
  if ($ver) { W "Game version : $ver" }
  if ($gd)  { W "Game dir     : $gd" }
  if ($agents) { foreach ($a in $agents) { W "JAVA AGENT    : $a   <-- check this" Yellow } }
  else { W 'Java agents   : none' }

  $javaHome = ''
  if ($pr.ExecutablePath) { $javaHome = Split-Path (Split-Path $pr.ExecutablePath) }

  W ''
  W 'Scanning javaw memory for loaded jar paths... (can take 30-90 seconds)' DarkGray
  $found = [JScan]::Scan($pr.ProcessId)
  $jars = $found | ? { $_ -match '\.jar$' } | sort
  $mods = $jars | ? { $_ -match '\\mods\\' }
  $libs = $jars | ? { $_ -match '\\(libraries|versions|assets|runtime)\\' -or ($javaHome -and $_.StartsWith($javaHome, 'OrdinalIgnoreCase')) -or $_ -match 'Program Files' }
  $other = $jars | ? { ($_ -notin $mods) -and ($_ -notin $libs) }

  W ''
  W "MODS found in javaw memory: $(@($mods).Count)" Green
  W ('-' * 78)
  $i = 0
  foreach ($f in $mods) {
    $i++
    $fi = Get-Item -LiteralPath $f -Force
    if ($fi) {
      W ("[{0}] {1}" -f $i, $fi.Name) White
      W ("     Size   : {0}" -f (Fmt-Size $fi.Length))
      W ("     Path   : $f")
      W ("     Source : $(Get-Source $f)")
    } else {
      W ("[{0}] {1}" -f $i, (Split-Path $f -Leaf)) Yellow
      W ("     FILE NO LONGER EXISTS on disk (was loaded, then deleted/moved)") Yellow
      W ("     Path   : $f")
    }
  }

  W ''
  W "OTHER jars loaded from outside mods/libraries (suspicious if in Downloads/Desktop/Temp): $(@($other).Count)" Yellow
  W ('-' * 78)
  foreach ($f in $other) {
    $fi = Get-Item -LiteralPath $f -Force
    if ($fi) {
      W ("  $($fi.Name)  [$(Fmt-Size $fi.Length)]") White
      W ("     Path   : $f")
      W ("     Source : $(Get-Source $f)")
    } else {
      W ("  $(Split-Path $f -Leaf)  -> FILE NO LONGER EXISTS") Yellow
      W ("     Path   : $f")
    }
  }

  W ''
  W 'NATIVE DLLs loaded in javaw (outside Windows / Java folders):' Yellow
  W ('-' * 78)
  $mods2 = $p.Modules | % { $_.FileName } | sort -Unique | ? {
    $_ -notmatch '^C:\\Windows\\' -and -not ($javaHome -and $_.StartsWith($javaHome, 'OrdinalIgnoreCase'))
  }
  foreach ($d in $mods2) {
    $fi = Get-Item -LiteralPath $d -Force
    $sig = (Get-AuthenticodeSignature -LiteralPath $d).Status
    $col = 'Gray'; if ($sig -ne 'Valid') { $col = 'Yellow' }
    W ("  $($fi.Name)  [$(Fmt-Size $fi.Length)]  signature: $sig") $col
    W ("     Path   : $d")
    if ($sig -ne 'Valid') { W ("     Source : $(Get-Source $d)") }
  }
}

$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'javaw_scan_report.txt'
$global:rep | Out-File -FilePath $out -Encoding UTF8
W ''
W "Report saved to: $out" Green
