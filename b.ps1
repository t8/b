# cascadia fleet - Windows bootstrap
# Run from an elevated PowerShell:
#   irm https://github.com/t8/b/raw/main/b.ps1 | iex                            # joins as cascadia-<computername>
#   $n='cascadia-booth-a'; irm https://github.com/t8/b/raw/main/b.ps1 | iex    # joins as cascadia-booth-a
# Installs OpenSSH Server (PowerShell default shell), installs the orchestrator
# public key for admin logins, keeps the box awake, installs Tailscale and joins
# the tailnet as $n with tag:fleet. Idempotent; safe to re-run. Re-running with a
# different $n renames an already-joined node.

$ErrorActionPreference = 'Continue'
if (-not $n) { $n = $env:FLEET_NAME }
if (-not $n) { $n = 'cascadia-' + $env:COMPUTERNAME.ToLower() }
$n   = (($n -replace '[^A-Za-z0-9-]', '-').Trim('-')).ToLower()
$key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAJIkJVfHYFjQsKYJl9vx4gn/tXa/tzMLVHkE/ORrfA3 cascadia-orchestrator'
$ts  = 'C:\Program Files\Tailscale\tailscale.exe'

function Say($m) { Write-Host "`n>> $m" -ForegroundColor Cyan }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Not elevated. Open PowerShell as Administrator (Win+X, then A) and run again.' -ForegroundColor Red
    return
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---- 0. Clock ---------------------------------------------------------------
# A wrong RTC (fresh OEM laptops) makes Tailscale register an already-expired node key and breaks every
# certificate later. Windows Time refuses large corrections by default, so set the clock from a plain-HTTP
# Date header first, then let w32time keep it.
Say 'Clock'
function Get-NetTime {
    try {
        $r = Invoke-WebRequest -UseBasicParsing 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 10
        $d = [DateTime]::ParseExact($r.Headers['Date'], 'r', [Globalization.CultureInfo]::InvariantCulture)
        return [DateTime]::SpecifyKind($d, 'Utc')
    } catch { return $null }
}
$net = Get-NetTime
if ($net) {
    $off = ((Get-Date).ToUniversalTime() - $net).TotalMinutes
    if ([math]::Abs($off) -gt 2) {
        Say ("Clock is off by {0:N0} minutes; setting it from the network" -f $off)
        Set-Date -Date $net.ToLocalTime() | Out-Null
        $w = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
        Set-ItemProperty $w -Name MaxPosPhaseCorrection -Value 0xFFFFFFFF -Type DWord
        Set-ItemProperty $w -Name MaxNegPhaseCorrection -Value 0xFFFFFFFF -Type DWord
        w32tm /config /manualpeerlist:"time.windows.com,0x8" /syncfromflags:manual /update | Out-Null
        Set-Service w32time -StartupType Automatic; Restart-Service w32time -ErrorAction SilentlyContinue
        w32tm /resync /force 2>$null | Out-Null
    }
    "clock: $(Get-Date -Format s) local (network $($net.ToLocalTime().ToString('s')))"
} else { Write-Host 'clock: could not reach the network time reference; check the date by hand' -ForegroundColor Yellow }

# ---- 1. OpenSSH Server ------------------------------------------------------
Say 'OpenSSH Server'
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if (-not $cap) { $cap = [pscustomobject]@{ Name = 'OpenSSH.Server~~~~0.0.1.0'; State = 'NotPresent' } }
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    Say 'Capability install failed; trying winget OpenSSH'
    winget install --id Microsoft.OpenSSH.Preview -e --accept-source-agreements --accept-package-agreements | Out-Null
}
Set-Service sshd -StartupType Automatic
Start-Service sshd
$deadline = (Get-Date).AddSeconds(60)
while (-not (Test-Path 'C:\ProgramData\ssh') -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
        -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

# ---- 2. PowerShell as default SSH shell (matches alpha/delta) ---------------
New-Item 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

# ---- 3. Orchestrator key for Administrators logins --------------------------
Say 'Authorized key'
$akf = 'C:\ProgramData\ssh\administrators_authorized_keys'
$have = (Test-Path $akf) -and ((Get-Content $akf) -contains $key)
if (-not $have) { Add-Content -Path $akf -Value $key -Encoding ascii }
icacls.exe $akf /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
Restart-Service sshd

# ---- 4. Fleet box: never sleep on AC ----------------------------------------
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null

# ---- 5. Tailscale -----------------------------------------------------------
if (-not (Test-Path $ts)) {
    Say 'Installing Tailscale'
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
    Invoke-WebRequest -UseBasicParsing "https://pkgs.tailscale.com/stable/tailscale-setup-latest-$arch.msi" -OutFile $msi
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
}
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    $svc = Get-Service Tailscale -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running' -and (Test-Path $ts)) { break }
    Start-Sleep 2
}

function TsState { try { (& $ts status --json 2>$null) | ConvertFrom-Json } catch { $null } }

function TsUp($tagged, $reauth) {
    $flags = @("up", "--hostname=$n", "--accept-routes", "--timeout=10m")
    if ($tagged) { $flags += "--advertise-tags=tag:fleet" } else { $flags += "--reset" }
    if ($reauth) { $flags += "--force-reauth" }
    # The tray GUI (tailscale-ipn) owns the daemon connection; kill it so 'up' from here is authorized.
    Get-Process tailscale-ipn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Say ("tailscale " + ($flags -join ' '))
    $job = Start-Job -ScriptBlock { param($exe, $a) & $exe @a 2>&1 } -ArgumentList $ts, $flags
    $opened = $false
    while ($job.State -eq 'Running') {
        $st = TsState
        if ($st -and $st.BackendState -eq 'Running') { break }
        if ($st -and $st.AuthURL -and -not $opened) {
            Say "Sign in to Tailscale in the browser window that just opened."
            Write-Host "   (if nothing opened, visit: $($st.AuthURL))"
            Start-Process $st.AuthURL
            $opened = $true
        }
        Start-Sleep 2
    }
    Wait-Job $job -Timeout 30 | Out-Null
    $out = (Receive-Job $job 2>&1 | Out-String).Trim()
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    if ($out) { Write-Host $out }
    return $out
}

$st = TsState
if (-not ($st -and $st.BackendState -eq 'Running')) {
    $out = TsUp $true
    $st = TsState
    if (-not ($st -and $st.BackendState -eq 'Running')) {
        Say 'Tagged join did not complete; joining untagged (tag:fleet must then be added in the admin console)'
        $out = TsUp $false
        $st = TsState
    }
} elseif ($st.Self.Expired -or ($st.Self.KeyExpiry -and ([DateTime]::Parse($st.Self.KeyExpiry).ToUniversalTime() -lt (Get-Date).ToUniversalTime()))) {
    Say "This node's key is expired (it joined with a wrong clock); re-authenticating"
    $out = TsUp $true $true
    $st = TsState
} elseif ($st.Self.HostName -ne $n) {
    Say "Renaming tailnet node $($st.Self.HostName) -> $n"
    & $ts set --hostname=$n 2>&1 | Write-Host
    Start-Sleep 3
    $st = TsState
}

# ---- 6. Report --------------------------------------------------------------
Say 'DONE - send these lines back if asked'
"HOST  : $env:COMPUTERNAME"
"NODE  : $(if ($st) { $st.Self.HostName })"
"USER  : $env:USERNAME"
"TS IP : $(& $ts ip -4 2>$null)"
"TAGS  : $(if ($st) { $st.Self.Tags -join ',' })"
"STATE : $(if ($st) { $st.BackendState })"
"KEYEXP: $(if ($st) { $st.Self.KeyExpiry })  (must be in the future)"
"CLOCK : $(Get-Date -Format s)"
"SSHD  : $((Get-Service sshd).Status)"
