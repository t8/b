# cascadia booth - venue fix (2026-11-03). Run from an ELEVATED PowerShell (Win+X, then A) on a booth laptop:
#   irm https://github.com/t8/b/raw/main/v.ps1 | iex
# The laptop letter comes from the hostname (ONE/TWO/THREE or BOOTH-A/B/C); to force it: $L='A'; irm ... | iex
# What it does, idempotent:
#   1. frees the `booth` adapter name from a ghost USB-NIC instance (the adapter moved to another USB-C port),
#      then runs the laptop's own fleet\provision\10-network.ps1: adapter `booth`, static 10.42.0.x, firewall
#      rules, sshd restart (key-only), the wall's link reporter task
#   2. Tailscale tunnel = Private network, sshd running + automatic, the SSH rule present on every profile
#   3. prints a diagnosis (sshd listening, firewall profiles/rules, security products, addresses) and posts
#      C:\venue.log to the orchestrator over the tailnet so nothing has to be pasted
$ErrorActionPreference = 'Continue'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Not elevated. Open PowerShell as Administrator (Win+X, then A) and run again.' -ForegroundColor Red
    return
}
if (-not (Get-Variable L -Scope Global -ErrorAction SilentlyContinue) -or -not $L) {
    $L = switch -Regex ($env:COMPUTERNAME) { '^(ONE|BOOTH-A)$' { 'A' } '^(TWO|BOOTH-B)$' { 'B' } '^(THREE|BOOTH-C)$' { 'C' } default { $null } }
}
while ($L -notin 'A', 'B', 'C') { $L = (Read-Host "Which laptop is this (A, B or C)").Trim().ToUpper() }
$ip = @{ A = '10.42.0.1'; B = '10.42.0.2'; C = '10.42.0.3' }[$L]
function Say($m) { Write-Host "`n>> $m" -ForegroundColor Cyan }
try { Stop-Transcript | Out-Null } catch {}
Start-Transcript -Path 'C:\venue.log' -Force | Out-Null
Write-Host "cascadia venue fix v2: laptop $L ($env:COMPUTERNAME), booth address $ip" -ForegroundColor Cyan

Say 'adapters before'
Get-NetAdapter | Where-Object { $_.Status -ne 'Not Present' } | ForEach-Object { "  {0,-16} {1,-12} {2,-10} {3}" -f $_.Name, $_.Status, $_.LinkSpeed, $_.InterfaceDescription }

Say 'free the booth name from a stale or ghost adapter'
$usbNic = { $_.InterfaceDescription -match 'Realtek USB|RTL8156|2\.5G|AX88179|USB.*(GbE|Ethernet)' -and $_.InterfaceDescription -notmatch 'Wi-Fi|Wireless|Bluetooth|Hyper-V|Tailscale' }
$nic = Get-NetAdapter -Name booth -ErrorAction SilentlyContinue
if ($nic -and $nic.Status -eq 'Up') { "  booth is already the live adapter ($($nic.InterfaceDescription), $($nic.LinkSpeed))" }
else {
    if ($nic) { $stale = "booth-stale-$(Get-Date -Format HHmmss)"; Rename-NetAdapter -Name booth -NewName $stale -ErrorAction SilentlyContinue; "  stale visible adapter renamed $stale" }
    # A ghost instance (the adapter as it was in the other USB-C port) keeps the name in two registry stores even when
    # Get-NetAdapter no longer lists it, and Rename-NetAdapter then fails with "Object Exists" (B, 2026-11-03). Free the
    # name in both stores and remove the ghost device itself; Windows re-creates it fresh if that port is ever used again.
    $visible = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceGuid })
    $stamp = Get-Date -Format HHmmss
    $netKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}'
    foreach ($k in Get-ChildItem $netKey -ErrorAction SilentlyContinue) {
        $conn = Join-Path $k.PSPath 'Connection'
        $cname = (Get-ItemProperty -Path $conn -Name Name -ErrorAction SilentlyContinue).Name
        if ($cname -eq 'booth' -and ($visible -notcontains $k.PSChildName)) { Set-ItemProperty -Path $conn -Name Name -Value "booth-stale-$stamp"; "  ghost $($k.PSChildName): connection name freed" }
    }
    foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkSetup2\Interfaces' -ErrorAction SilentlyContinue) {
        $kern = Join-Path $k.PSPath 'Kernel'
        $alias = (Get-ItemProperty -Path $kern -Name IfAlias -ErrorAction SilentlyContinue).IfAlias
        if ($alias -eq 'booth' -and ($visible -notcontains $k.PSChildName)) { Set-ItemProperty -Path $kern -Name IfAlias -Value "booth-stale-$stamp"; "  ghost $($k.PSChildName): interface alias freed" }
    }
    Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' -and $_.FriendlyName -match 'AX88179|RTL8156|USB.*(GbE|Ethernet)' } | ForEach-Object {
        "  removing ghost device $($_.FriendlyName) [$($_.InstanceId)]"; & pnputil /remove-device $_.InstanceId 2>&1 | ForEach-Object { "    $_" }
    }
    $live = Get-NetAdapter | Where-Object $usbNic | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($live) { "  live USB adapter: $($live.Name) ($($live.InterfaceDescription), $($live.LinkSpeed))" }
    else { Write-Host '  no USB Ethernet adapter is Up: plug the adapter and the cable in, then run this again' -ForegroundColor Yellow }
}

Say '10-network.ps1 (adapter, static address, firewall, sshd, link reporter)'
$prov = 'C:\booth-usb\cascadia-booth\fleet\provision'
if (Test-Path "$prov\10-network.ps1") {
    cmd /c "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$prov\10-network.ps1"" -Laptop $L -Usb C:\booth-usb 2>&1"
    "  10-network exit code $LASTEXITCODE"
} else { Write-Host "  $prov\10-network.ps1 is missing; the payload copy was not restored on this laptop" -ForegroundColor Red }

Say 'tailscale tunnel as a Private network, sshd on'
Set-NetConnectionProfile -InterfaceAlias Tailscale -NetworkCategory Private -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
if ((Get-Service sshd -ErrorAction SilentlyContinue).Status -ne 'Running') { Start-Service sshd -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
if (-not (Get-NetFirewallRule -DisplayName 'booth-ssh-22' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName 'booth-ssh-22' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null; '  booth-ssh-22 rule created'
}
# McAfee's firewall (ships on the OmniBook; its removal is a pending item) may be what drops inbound SSH on a
# network it does not trust. Stopping its service is reversible (Start-Service mc-fw-host) and logged here.
$mc = Get-Service mc-fw-host -ErrorAction SilentlyContinue
if ($mc -and $mc.Status -eq 'Running') {
    try { Stop-Service mc-fw-host -Force -ErrorAction Stop; '  mcafee firewall service mc-fw-host stopped' }
    catch { "  mcafee firewall service could not be stopped ($($_.Exception.Message)); if SSH stays shut, open McAfee > Firewall and turn it off" }
} elseif ($mc) { "  mcafee firewall service: $($mc.Status)" } else { '  no mcafee firewall service' }

Say 'diagnosis'
$svc = Get-Service sshd -ErrorAction SilentlyContinue
"  sshd: " + $(if ($svc) { "$($svc.Status) / $($svc.StartType)" } else { 'NOT INSTALLED' })
"  listening on 22: " + [bool](Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)
Get-NetFirewallProfile | ForEach-Object { "  fw profile {0}: enabled={1} inbound={2}" -f $_.Name, $_.Enabled, $_.DefaultInboundAction }
Get-NetFirewallRule -DisplayName 'booth-ssh-22', 'OpenSSH Server (sshd)', 'OpenSSH SSH Server (sshd)' -ErrorAction SilentlyContinue | ForEach-Object { "  rule {0}: enabled={1} profile={2} action={3}" -f $_.DisplayName, $_.Enabled, $_.Profile, $_.Action }
Get-NetConnectionProfile | ForEach-Object { "  net {0}: '{1}' {2} v4={3}" -f $_.InterfaceAlias, $_.Name, $_.NetworkCategory, $_.IPv4Connectivity }
Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue | ForEach-Object { "  firewall product {0}: state=0x{1:X}" -f $_.displayName, $_.productState }
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { "  ip {0} {1}/{2}" -f $_.InterfaceAlias, $_.IPAddress, $_.PrefixLength }
$ts = 'C:\Program Files\Tailscale\tailscale.exe'
if (Test-Path $ts) { "  tailscale: " + ((& $ts ip -4 2>$null) -join ' ') }
$boothOk = [bool](Get-NetIPAddress -InterfaceAlias booth -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $ip })
$sshOk = [bool](Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)
Write-Host ("`nDONE laptop {0}: booth {1} {2}; sshd listening {3}" -f $L, $ip, $(if ($boothOk) { 'OK' } else { 'MISSING' }), $sshOk) -ForegroundColor $(if ($boothOk -and $sshOk) { 'Green' } else { 'Yellow' })

try { Stop-Transcript | Out-Null } catch {}
$sent = $false
try {
    $body = Get-Content -Raw 'C:\venue.log'
    Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://100.109.27.121:8787/log?host=venue-$L-$($env:COMPUTERNAME)" -Body $body -TimeoutSec 8 | Out-Null
    $sent = $true
} catch {}
if ($sent) { Write-Host 'log sent to the orchestrator over the tailnet' -ForegroundColor Green }
else { Write-Host 'could not send the log over the tailnet; if asked:   type C:\venue.log   and paste it' -ForegroundColor Yellow }
