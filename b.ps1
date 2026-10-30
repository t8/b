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
Write-Host 'cascadia bootstrap v7 (clock, sshd, one Tailscale attempt only; log posted to the orchestrator over the LAN or the tailnet)' -ForegroundColor Cyan
try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path 'C:\b.log' -Force | Out-Null
function Send-Log($tag) {
    # Everything so far is in C:\b.log; hand it to the orchestrator (tailnet address, else the office LAN address)
    # so nobody has to paste it. Transcript is paused for the read and resumed.
    try { Stop-Transcript | Out-Null } catch {}
    $sent = $false
    $body = Get-Content -Raw 'C:\b.log'
    foreach ($u in "http://100.109.27.121:8787/log?host=$n-$tag", "http://192.168.0.195:8787/log?host=$n-$tag") {
        if ($sent) { break }
        try { Invoke-WebRequest -UseBasicParsing -Method Post -Uri $u -Body $body -TimeoutSec 6 | Out-Null; $sent = $true } catch { }
    }
    Start-Transcript -Path 'C:\b.log' -Append | Out-Null
    if ($sent) { Write-Host "log ($tag) sent to the orchestrator" -ForegroundColor Green }
    else { Write-Host "could not send the log ($tag); if asked, run:   type C:\b.log   and paste it" -ForegroundColor Yellow }
}
function Finish { Send-Log 'done'; try { Stop-Transcript | Out-Null } catch {} }

# ---- 0. Clock ---------------------------------------------------------------
# A wrong RTC (fresh OEM laptops) makes Tailscale register an already-expired node key and breaks every
# certificate later. Windows Time refuses large corrections by default, so set the clock from a plain-HTTP
# Date header first, then let w32time keep it.
Say 'Clock'
function Get-NetTime {
    foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt', 'http://detectportal.firefox.com/success.txt', 'http://captive.apple.com/', 'http://neverssl.com/') {
        try {
            $r = Invoke-WebRequest -UseBasicParsing $u -TimeoutSec 8
            $d = [DateTime]::ParseExact($r.Headers['Date'], 'r', [Globalization.CultureInfo]::InvariantCulture)
            Write-Host "time reference: $u"
            return [DateTime]::SpecifyKind($d, 'Utc')
        } catch { Write-Host "time reference $u failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    return $null
}
"clock before: $(Get-Date -Format s) local"
$net = Get-NetTime
$clockOk = $false
if ($net) {
    $off = ((Get-Date).ToUniversalTime() - $net).TotalMinutes
    if ([math]::Abs($off) -gt 2) {
        Say ("Clock is off by {0:N0} minutes ({1:N1} days); fixing it" -f $off, ($off / 1440))
        $w = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
        Stop-Service w32time -Force -ErrorAction SilentlyContinue
        # Secure Time Seeding sets clocks from TLS handshakes and is the usual cause of a clock months off; turn it off.
        Set-ItemProperty $w -Name UtilizeSslTimeData -Value 0 -Type DWord
        Set-ItemProperty $w -Name MaxPosPhaseCorrection -Value 0xFFFFFFFF -Type DWord
        Set-ItemProperty $w -Name MaxNegPhaseCorrection -Value 0xFFFFFFFF -Type DWord
        Set-Date -Date $net.ToLocalTime() | Out-Null
        "clock after Set-Date: $(Get-Date -Format s) local"
        w32tm /config /manualpeerlist:"time.windows.com,0x9 pool.ntp.org,0x9" /syncfromflags:manual /reliable:no /update 2>&1 | Out-Null
        Set-Service w32time -StartupType Automatic; Start-Service w32time -ErrorAction SilentlyContinue
        Start-Sleep 2
        $rs = (w32tm /resync /force 2>&1 | Out-String).Trim(); "w32tm resync: $rs"
        "clock after resync: $(Get-Date -Format s) local"
        if (Get-Service Tailscale -ErrorAction SilentlyContinue) { Restart-Service Tailscale -ErrorAction SilentlyContinue; Write-Host 'tailscale service restarted after the clock change' }
    }
    $off2 = ((Get-Date).ToUniversalTime() - $net).TotalMinutes
    $clockOk = [math]::Abs($off2) -lt 10
    "clock: $(Get-Date -Format s) local; network $($net.ToLocalTime().ToString('s')); offset now {0:N1} min; ok=$clockOk" -f $off2
} else { Write-Host 'clock: could not reach any network time reference; the date must be set by hand before Tailscale can work' -ForegroundColor Yellow }
"ipv4: " + ((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)" }) -join ' ')

# ---- 1. OpenSSH Server ------------------------------------------------------
Say 'OpenSSH Server'
function Have-Sshd { [bool](Get-Service sshd -ErrorAction SilentlyContinue) }
if (-not (Have-Sshd)) {
    # Add-WindowsCapability talks to Windows Update and can hang for a long time on OEM images: cap it at 2 minutes.
    $capJob = Start-Job -ScriptBlock {
        $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop | Select-Object -First 1
        if (-not $cap) { return 'not offered on this image' }
        if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null }
        return (Get-WindowsCapability -Online -Name $cap.Name).State
    }
    if (Wait-Job $capJob -Timeout 120) {
        try { Write-Host "capability: $(Receive-Job $capJob -ErrorAction Stop)" } catch { Write-Host "capability: failed ($($_.Exception.Message))" -ForegroundColor Yellow }
    } else { Stop-Job $capJob -ErrorAction SilentlyContinue; Write-Host 'capability: gave up after 2 minutes (Windows Update not answering)' -ForegroundColor Yellow }
    Remove-Job $capJob -Force -ErrorAction SilentlyContinue
}
if (-not (Have-Sshd)) {
    # Win32-OpenSSH MSI (what winget installs): registers and starts sshd + ssh-agent itself.
    Say 'Installing Win32-OpenSSH (MSI from GitHub)'
    try {
        $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest' -Headers @{ 'User-Agent' = 'cascadia-bootstrap' }
        $asset = $rel.assets | Where-Object { $_.name -like 'OpenSSH-Win64-v*.msi' } | Select-Object -First 1
        if (-not $asset) { throw 'no OpenSSH-Win64-v*.msi in the latest release' }
        $msi = Join-Path $env:TEMP $asset.name
        Invoke-WebRequest -UseBasicParsing $asset.browser_download_url -OutFile $msi
        Write-Host ("downloaded {0} ({1:N1} MB)" -f $asset.name, ((Get-Item $msi).Length / 1MB))
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait -PassThru
        Write-Host "msiexec exit code $($p.ExitCode) (0 = ok, 3010 = ok, reboot later)"
    } catch { Write-Host "msi: failed ($($_.Exception.Message))" -ForegroundColor Yellow }
}
if (-not (Have-Sshd)) {
    Say 'Installing Win32-OpenSSH (zip from GitHub)'
    try {
        $zip = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
        Invoke-WebRequest -UseBasicParsing 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip' -OutFile $zip
        Write-Host ("downloaded OpenSSH-Win64.zip ({0:N1} MB)" -f ((Get-Item $zip).Length / 1MB))
        $tmp = Join-Path $env:TEMP 'openssh-extract'
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
        $root = 'C:\Program Files\OpenSSH-Win64'
        New-Item -ItemType Directory -Force $root | Out-Null
        Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $root -Recurse -Force
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install-sshd.ps1')
        $env:Path = "$env:Path;$root"
    } catch { Write-Host "zip: failed ($($_.Exception.Message))" -ForegroundColor Yellow }
}
if (-not (Have-Sshd)) {
    Write-Host 'sshd service still missing after capability, MSI and zip attempts.' -ForegroundColor Red
    Finish
    return
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

Send-Log 'sshd'

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
    $flags = @("up", "--hostname=$n", "--accept-routes", "--timeout=2m")
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

if (-not $clockOk) {
    Write-Host 'Clock is not right yet; skipping the Tailscale join (a key issued under a wrong clock is born expired). Fix the date, then run this again.' -ForegroundColor Red
    Finish
    return
}
$st = TsState
if (-not ($st -and $st.BackendState -eq 'Running')) {
    # One tagged attempt, two minutes. The orchestrator reaches these laptops over the LAN as well, so a
    # Tailscale join that needs admin-console attention must not hold the bootstrap hostage.
    $out = TsUp $true
    $st = TsState
    if (-not ($st -and $st.BackendState -eq 'Running')) { Write-Host 'Tailscale join did not complete; carrying on (the orchestrator will sort the tailnet side out).' -ForegroundColor Yellow }
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
"SSHD  : $((Get-Service sshd).Status)  $((Get-CimInstance Win32_Service -Filter "Name='sshd'").PathName)"
Finish
