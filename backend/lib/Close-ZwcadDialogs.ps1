# Dismiss ZWCAD font-substitution and proxy-information dialogs while a drawing opens.
# Text strings and geometry stay in the DWG; these dialogs only block the open call.

if (-not ("ZwcadDialogGuard" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public static class ZwcadDialogGuard {
  public static volatile bool Stop;
  public static int ClosedCount;
  static Thread thread;
  static readonly Dictionary<long, int> Recent = new Dictionary<long, int>();

  delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll")]
  static extern bool EnumChildWindows(IntPtr hWndParent, EnumProc lpEnumFunc, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern int GetClassName(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")]
  static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern IntPtr SendMessageTimeout(IntPtr hWnd, int msg, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")]
  static extern IntPtr SendMessageTimeout(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")]
  static extern bool PostMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")]
  static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")]
  static extern int GetDlgCtrlID(IntPtr hWnd);

  const int BM_CLICK = 0x00F5;
  const int BM_GETCHECK = 0x00F0;
  const int LB_SETCURSEL = 0x0186;
  const int LB_FINDSTRINGEXACT = 0x01A2;
  const int WM_COMMAND = 0x0111;
  const int LBN_SELCHANGE = 1;
  const int IDOK = 1;
  const uint SMTO_ABORTIFHUNG = 0x0002;

  static bool TrySendInt(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, out int value) {
    IntPtr result;
    IntPtr ok = SendMessageTimeout(hwnd, msg, wParam, lParam, SMTO_ABORTIFHUNG, 300, out result);
    value = result.ToInt32();
    return ok != IntPtr.Zero;
  }

  static bool TrySendText(IntPtr hwnd, int msg, IntPtr wParam, string text, out int value) {
    IntPtr result;
    IntPtr ok = SendMessageTimeout(hwnd, msg, wParam, text, SMTO_ABORTIFHUNG, 300, out result);
    value = result.ToInt32();
    return ok != IntPtr.Zero;
  }

  public static void Start() {
    if (thread != null && thread.IsAlive) return;
    Stop = false;
    thread = new Thread(Loop);
    thread.IsBackground = true;
    thread.Start();
  }

  public static void StopGuard() {
    Stop = true;
    if (thread != null) {
      try { thread.Join(1500); } catch {}
    }
  }

  static void Loop() {
    while (!Stop) {
      try { Sweep(); } catch {}
      Thread.Sleep(200);
    }
  }

  static string WindowText(IntPtr hwnd) {
    StringBuilder buf = new StringBuilder(512);
    GetWindowText(hwnd, buf, buf.Capacity);
    return buf.ToString();
  }

  static string ClassName(IntPtr hwnd) {
    StringBuilder buf = new StringBuilder(256);
    GetClassName(hwnd, buf, buf.Capacity);
    return buf.ToString();
  }

  static bool IsButton(IntPtr hwnd) {
    return ClassName(hwnd).IndexOf("BUTTON", StringComparison.OrdinalIgnoreCase) >= 0;
  }

  static bool IsList(IntPtr hwnd) {
    return ClassName(hwnd).IndexOf("LISTBOX", StringComparison.OrdinalIgnoreCase) >= 0;
  }

  static bool TooSoon(IntPtr hwnd) {
    long key = hwnd.ToInt64();
    int now = Environment.TickCount;
    int prev;
    if (Recent.TryGetValue(key, out prev) && unchecked(now - prev) < 700) return true;
    Recent[key] = now;
    return false;
  }

  static void Sweep() {
    EnumWindows(delegate(IntPtr hwnd, IntPtr lParam) {
      if (!IsWindowVisible(hwnd)) return true;
      string title = WindowText(hwnd);
      if (title.IndexOf("\u6307\u5b9a\u5b57\u4f53") >= 0 || title.IndexOf("Specify Font") >= 0) {
        AcceptFont(hwnd);
      } else if (title.IndexOf("\u4ee3\u7406\u4fe1\u606f") >= 0 || title.IndexOf("Proxy Information") >= 0) {
        AcceptProxy(hwnd);
      }
      return true;
    }, IntPtr.Zero);
  }

  static void SelectFont(IntPtr list, params string[] names) {
    foreach (string name in names) {
      int index;
      if (!TrySendText(list, LB_FINDSTRINGEXACT, new IntPtr(-1), name, out index) || index < 0) continue;
      int selected;
      TrySendInt(list, LB_SETCURSEL, new IntPtr(index), IntPtr.Zero, out selected);
      int id = GetDlgCtrlID(list) & 0xFFFF;
      PostMessage(GetParent(list), WM_COMMAND, new IntPtr((LBN_SELCHANGE << 16) | id), list);
      return;
    }
  }

  [DllImport("user32.dll")]
  static extern IntPtr GetParent(IntPtr hWnd);

  static void AcceptProxy(IntPtr dialog) {
    if (TooSoon(dialog)) return;
    IntPtr hideBox = IntPtr.Zero;
    IntPtr showRadio = IntPtr.Zero;
    IntPtr ok = IntPtr.Zero;
    EnumChildWindows(dialog, delegate(IntPtr child, IntPtr lParam) {
      if (!IsButton(child)) return true;
      string text = WindowText(child);
      if (text.IndexOf("\u4e0d\u518d\u663e\u793a") >= 0) hideBox = child;
      else if (text.IndexOf("\u663e\u793a\u4ee3\u7406\u56fe\u5f62") >= 0) showRadio = child;
      else if (text.IndexOf("\u786e\u5b9a") >= 0 || text == "OK") ok = child;
      return true;
    }, IntPtr.Zero);
    try { SetForegroundWindow(dialog); } catch {}
    if (showRadio != IntPtr.Zero) PostMessage(showRadio, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
    int check;
    if (hideBox != IntPtr.Zero && TrySendInt(hideBox, BM_GETCHECK, IntPtr.Zero, IntPtr.Zero, out check) && check == 0) {
      PostMessage(hideBox, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
    }
    ClickOkButton(dialog, ok);
  }

  static void AcceptFont(IntPtr dialog) {
    if (TooSoon(dialog)) return;
    IntPtr ok = IntPtr.Zero;
    EnumChildWindows(dialog, delegate(IntPtr child, IntPtr lParam) {
      if (IsList(child)) {
        SelectFont(child, "HZTXT1.SHX", "GBCBIG.SHX", "gbenor.shx", "txt.shx");
      } else if (IsButton(child)) {
        string text = WindowText(child);
        if (text.IndexOf("\u786e\u5b9a") >= 0 || text == "OK") ok = child;
      }
      return true;
    }, IntPtr.Zero);
    try { SetForegroundWindow(dialog); } catch {}
    ClickOkButton(dialog, ok);
  }

  static void ClickOkButton(IntPtr dialog, IntPtr ok) {
    if (ok != IntPtr.Zero) PostMessage(ok, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
    else PostMessage(dialog, WM_COMMAND, new IntPtr(IDOK), IntPtr.Zero);
    Interlocked.Increment(ref ClosedCount);
  }
}
'@ -Language CSharp
}

function Set-CadVar {
  param($Doc, [string]$Name, $Value)
  if (-not $Doc) { return }
  try { $Doc.SetVariable($Name, $Value); return } catch {}
  try { $Doc.SetSystemVariable($Name, $Value) } catch {}
}

function Get-CadVar {
  param($Doc, [string]$Name)
  if (-not $Doc) { return $null }
  try { return $Doc.GetVariable($Name) } catch {}
  try { return $Doc.GetSystemVariable($Name) } catch {}
  return $null
}

function Set-CadOpenQuiet {
  param($App, [bool]$Enable)
  $doc = $null
  try { $doc = $App.ActiveDocument } catch {}
  if ($Enable) {
    $script:CadSavedVars = @{}
    foreach ($name in @("FILEDIA", "CMDDIA", "EXPERT")) {
      $current = Get-CadVar $doc $name
      if ($null -ne $current) { $script:CadSavedVars[$name] = $current }
    }
    Set-CadVar $doc "FILEDIA" 0
    Set-CadVar $doc "CMDDIA" 0
    Set-CadVar $doc "EXPERT" 5
    Set-CadVar $doc "PROXYNOTICE" 0
    Set-CadVar $doc "PROXYSHOW" 1
    Set-CadVar $doc "FONTALT" "hztxt1.shx"
    return
  }
  if (-not $script:CadSavedVars) { return }
  foreach ($name in @($script:CadSavedVars.Keys)) {
    Set-CadVar $doc $name $script:CadSavedVars[$name]
  }
}

function Open-DwgDocument {
  param($App, [string]$Path)
  $full = [System.IO.Path]::GetFullPath($Path)
  foreach ($d in @($App.Documents)) {
    try {
      if ([string]$d.FullName -ieq $full) {
        return @{ Doc = $d; Opened = $false }
      }
    } catch {}
  }
  try { $App.DisplayAlerts = $false } catch {}
  Set-CadOpenQuiet -App $App -Enable $true
  try {
    $doc = $App.Documents.Open($full, $true)
    Set-CadVar $doc "PROXYNOTICE" 0
    Set-CadVar $doc "PROXYSHOW" 1
    Set-CadVar $doc "FONTALT" "hztxt1.shx"
    return @{ Doc = $doc; Opened = $true }
  } finally {
    Set-CadOpenQuiet -App $App -Enable $false
  }
}
