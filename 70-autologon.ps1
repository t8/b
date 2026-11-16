#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Auto-logon for the booth account, so a laptop that is powered on with nobody at the keyboard reaches the desktop and
  its logon tasks (kiosk windows, Desktop, wall, fleet manager, studio) start by themselves. The password is stored the
  way Sysinternals Autologon stores it: as the LSA secret `DefaultPassword` (never in the registry in clear text, never
  in a log). Run this AT THE KEYBOARD in an elevated PowerShell; it asks for the password.

    70-autologon.ps1                 # for the account running it (tatef); asks for the password
    70-autologon.ps1 -User tatef     # explicit account
    70-autologon.ps1 -Disable        # turn auto-logon off and delete the stored secret

  Verify: reboot; the desktop must appear without a sign-in, and `booth-kiosk` must fire 20 s later.
  Windows 11 hides the netplwiz checkbox when "only allow Windows Hello sign-in" is on; this script clears that
  switch (DevicePasswordLessBuildVersion = 0) so the registry values take effect.
#>
param([string]$User = $env:USERNAME, [switch]$Disable)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('BoothLsa.Secret' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace BoothLsa {
  public static class Secret {
    [StructLayout(LayoutKind.Sequential)] public struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] public struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public LSA_UNICODE_STRING ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(ref LSA_UNICODE_STRING SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes, uint DesiredAccess, out IntPtr PolicyHandle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, ref LSA_UNICODE_STRING PrivateData);
    [DllImport("advapi32.dll", EntryPoint = "LsaStorePrivateData")] static extern uint LsaDeletePrivateData(IntPtr PolicyHandle, ref LSA_UNICODE_STRING KeyName, IntPtr PrivateData);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr ObjectHandle);
    [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
    static LSA_UNICODE_STRING Str(string s) {
      var u = new LSA_UNICODE_STRING(); u.Buffer = Marshal.StringToHGlobalUni(s);
      u.Length = (ushort)(s.Length * 2); u.MaximumLength = (ushort)((s.Length + 1) * 2); return u;
    }
    static IntPtr Open() {
      var attrs = new LSA_OBJECT_ATTRIBUTES(); attrs.Length = Marshal.SizeOf(attrs);
      var sys = new LSA_UNICODE_STRING(); IntPtr h;
      uint st = LsaOpenPolicy(ref sys, ref attrs, 0x000F0FFF, out h);
      if (st != 0) throw new Exception("LsaOpenPolicy failed, win32 error " + LsaNtStatusToWinError(st));
      return h;
    }
    public static void Store(string key, string value) {
      IntPtr h = Open(); var k = Str(key); var v = Str(value);
      try { uint st = LsaStorePrivateData(h, ref k, ref v); if (st != 0) throw new Exception("LsaStorePrivateData failed, win32 error " + LsaNtStatusToWinError(st)); }
      finally { Marshal.FreeHGlobal(k.Buffer); Marshal.FreeHGlobal(v.Buffer); LsaClose(h); }
    }
    public static void Delete(string key) {
      IntPtr h = Open(); var k = Str(key);
      try { uint st = LsaDeletePrivateData(h, ref k, IntPtr.Zero); if (st != 0 && st != 0xC0000034) throw new Exception("LsaStorePrivateData(delete) failed, win32 error " + LsaNtStatusToWinError(st)); }
      finally { Marshal.FreeHGlobal(k.Buffer); LsaClose(h); }
    }
  }
}
'@
}

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$passwordless = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'

if ($Disable) {
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0'
    Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
    [BoothLsa.Secret]::Delete('DefaultPassword')
    Write-Host "auto-logon disabled for this laptop; the stored secret is gone"
    return
}

$secure = Read-Host -AsSecureString -Prompt "Password for $env:COMPUTERNAME\$User (stored as an LSA secret, shown nowhere)"
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    if (-not $plain) { throw 'empty password; nothing changed' }
    [BoothLsa.Secret]::Store('DefaultPassword', $plain)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plain = $null
}
New-Item -Path $passwordless -Force | Out-Null
Set-ItemProperty -Path $passwordless -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1'
Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value $User
Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue   # never in clear text
Remove-ItemProperty -Path $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue

$w = Get-ItemProperty $winlogon
Write-Host ("auto-logon: AutoAdminLogon={0} DefaultUserName={1} DefaultDomainName={2} (password in the LSA secret)" -f $w.AutoAdminLogon, $w.DefaultUserName, $w.DefaultDomainName)
if ($w.AutoAdminLogon -eq '1' -and $w.DefaultUserName -eq $User) { Write-Host 'PASS: reboot to confirm the desktop comes up without a sign-in' -ForegroundColor Green } else { Write-Host 'FAIL: registry values not as expected' -ForegroundColor Red; exit 1 }
