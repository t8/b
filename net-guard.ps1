# Booth network guard: keeps this laptop's booth address alive with no one at the keyboard and no internet.
# SYSTEM task `booth-net-guard`, every minute from boot (fleet/provision/_common.ps1 Register-MinuteTask). What it does
# each run, in order, and only as far as needed:
#   1. the booth address (10.42.0.x for this letter) sits on an adapter that is Up -> nothing to do.
#   2. no live USB Ethernet adapter -> wait (cable or adapter not in yet).
#   3. the live adapter is a NEW instance (the adapter moved to another USB-C port, or a different adapter was plugged
#      in: Windows then makes a new "Ethernet N" with no address while the old one lingers as a ghost that still owns
#      the name `booth` in two registry stores) -> free the name, remove the ghost device, rename the live one `booth`.
#   4. put the static address on `booth` (DHCP off, metric 100, profile Private), exactly as 10-network.ps1 does.
#   5. the services that bound the old address get a restart: the node (A, B) or honyaku-single (C), the CA on A,
#      and, when someone is logged on, the kiosk windows (and the Desktop on B) so they reconnect.
# Log: C:\ProgramData\Cascadia\booth\net-guard.log (one line per state change, so an idle fleet logs nothing).
#   net-guard.ps1 -Register [-Laptop X]   registers the task (elevated; beside _common.ps1); 10-network.ps1 does this too.
#   net-guard.ps1 -Status                 prints the last log lines and the current state
param([switch]$Register, [switch]$Status, [string]$Laptop)
$ErrorActionPreference = 'SilentlyContinue'; $ProgressPreference = 'SilentlyContinue'
$Booth = 'C:\ProgramData\Cascadia\booth'
$log = Join-Path $Booth 'net-guard.log'
$stateFile = Join-Path $Booth 'net-guard.state'
$Ips = @{ A = '10.42.0.1'; B = '10.42.0.2'; C = '10.42.0.3' }
$UsbNic = { $_.InterfaceDescription -match 'Realtek USB|RTL8156|2\.5G|AX88179|USB.*(GbE|Ethernet)' -and $_.InterfaceDescription -notmatch 'Wi-Fi|Wireless|Bluetooth|Hyper-V|Tailscale' }
function Log([string]$m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format s), $m) }
function Set-State([string]$s, [string]$detail) {
    $prev = Get-Content $stateFile -ErrorAction SilentlyContinue
    if ($prev -ne $s) { Set-Content -Path $stateFile -Value $s; Log ("state {0}{1}" -f $s, $(if ($detail) { ': ' + $detail } else { '' })) }
}
function Letter {
    if ($Laptop) { return $Laptop.ToUpper() }
    $l = (Get-Content (Join-Path $Booth 'letter.txt') -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($l) { return $l.Trim().ToUpper() }
    switch -Regex ($env:COMPUTERNAME) { '^(ONE|BOOTH-A)$' { return 'A' } '^(TWO|BOOTH-B)$' { return 'B' } '^(THREE|BOOTH-C)$' { return 'C' } }
    return $null
}

if ($Register) {
    $ErrorActionPreference = 'Stop'
    . "$PSScriptRoot\_common.ps1"
    $L = Letter
    if (-not $L) { throw 'cannot tell the laptop letter: pass -Laptop A|B|C' }
    Ensure-BoothDir
    [IO.File]::WriteAllText((Join-Path $Booth 'letter.txt'), $L)
    Register-MinuteTask -Name 'booth-net-guard' -ScriptPath $PSCommandPath
    Start-ScheduledTask -TaskName 'booth-net-guard'
    Write-Host "registered booth-net-guard for laptop $L (every minute, from boot) -> $PSCommandPath"
    return
}
if ($Status) {
    "state: " + (Get-Content $stateFile -ErrorAction SilentlyContinue)
    "task:  " + (Get-ScheduledTask -TaskName 'booth-net-guard' -ErrorAction SilentlyContinue).State
    Get-Content $log -Tail 12 -ErrorAction SilentlyContinue
    return
}

$L = Letter
if (-not $L) { Set-State 'no-letter' 'write C:\ProgramData\Cascadia\booth\letter.txt (A, B or C)'; exit 0 }
$ip = $Ips[$L]

# 1. healthy: the address is on an adapter that is Up.
$addr = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq $ip } | Select-Object -First 1
if ($addr) {
    $nic = Get-NetAdapter -InterfaceIndex $addr.InterfaceIndex
    if ($nic -and $nic.Status -eq 'Up') { Set-State 'ok' ("{0} on {1}" -f $ip, $nic.Name); exit 0 }
}

# 2. a live USB Ethernet adapter?
$live = Get-NetAdapter | Where-Object $UsbNic | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
if (-not $live) {
    $any = Get-NetAdapter | Where-Object $UsbNic | Select-Object -First 1
    Set-State 'waiting-for-adapter' $(if ($any) { "{0} is {1}" -f $any.Name, $any.Status } else { 'no USB Ethernet adapter present' })
    exit 0
}
Log ("booth address {0} missing; live adapter '{1}' ({2}, {3})" -f $ip, $live.Name, $live.InterfaceDescription, $live.LinkSpeed)

# 3. the name `booth` on the live adapter.
if ($live.Name -ne 'booth') {
    $stamp = Get-Date -Format HHmmss
    $stale = Get-NetAdapter -Name booth
    if ($stale) { Rename-NetAdapter -Name booth -NewName "booth-stale-$stamp"; Log ("visible stale adapter renamed booth-stale-{0}" -f $stamp) }
    $visible = @(Get-NetAdapter -IncludeHidden | ForEach-Object { $_.InterfaceGuid })
    $netKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}'
    foreach ($k in Get-ChildItem $netKey) {
        $conn = Join-Path $k.PSPath 'Connection'
        $cname = (Get-ItemProperty -Path $conn -Name Name).Name
        if ($cname -eq 'booth' -and ($visible -notcontains $k.PSChildName)) { Set-ItemProperty -Path $conn -Name Name -Value "booth-stale-$stamp"; Log ("ghost {0}: connection name freed" -f $k.PSChildName) }
    }
    foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\NetworkSetup2\Interfaces') {
        $kern = Join-Path $k.PSPath 'Kernel'
        $alias = (Get-ItemProperty -Path $kern -Name IfAlias).IfAlias
        if ($alias -eq 'booth' -and ($visible -notcontains $k.PSChildName)) { Set-ItemProperty -Path $kern -Name IfAlias -Value "booth-stale-$stamp"; Log ("ghost {0}: interface alias freed" -f $k.PSChildName) }
    }
    Get-PnpDevice -Class Net | Where-Object { $_.Status -ne 'OK' -and $_.FriendlyName -match 'AX88179|RTL8156|USB.*(GbE|Ethernet)' } | ForEach-Object {
        $r = (& pnputil /remove-device $_.InstanceId 2>&1 | Out-String) -replace '\s+', ' '
        Log ("ghost device {0} [{1}] removed: {2}" -f $_.FriendlyName, $_.InstanceId, $r.Trim())
    }
    # Right after a ghost removal the rename can fail once while PnP settles (C, 2026-11-16): retry a few times.
    $tries = 0
    while (-not (Get-NetAdapter -Name booth) -and $tries -lt 4) { $tries++; Rename-NetAdapter -Name $live.Name -NewName booth; if (-not (Get-NetAdapter -Name booth)) { Start-Sleep -Seconds 3 } }
    if (-not (Get-NetAdapter -Name booth)) { Set-State 'rename-failed' ("could not name {0} booth (will retry next minute)" -f $live.Name); exit 1 }
    Log ("{0} renamed booth (attempt {1})" -f $live.Name, $tries)
}

# 4. the static address (10-network.ps1, section 2).
$elsewhere = @(Get-NetIPAddress -IPAddress $ip -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -ne 'booth' })
if ($elsewhere) { $elsewhere | Remove-NetIPAddress -Confirm:$false; Start-Sleep -Seconds 2 }
Set-NetIPInterface -InterfaceAlias booth -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceAlias booth -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne $ip } | Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceAlias booth -DestinationPrefix '0.0.0.0/0' | Remove-NetRoute -Confirm:$false
if (-not (Get-NetIPAddress -InterfaceAlias booth -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq $ip })) {
    New-NetIPAddress -InterfaceAlias booth -IPAddress $ip -PrefixLength 24 -DefaultGateway 10.42.0.254 | Out-Null
}
Set-NetIPInterface -InterfaceAlias booth -AddressFamily IPv4 -InterfaceMetric 100
Set-DnsClientServerAddress -InterfaceAlias booth -ResetServerAddresses
Set-NetConnectionProfile -InterfaceAlias booth -NetworkCategory Private
$ok = [bool](Get-NetIPAddress -InterfaceAlias booth -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq $ip })
if (-not $ok) { Set-State 'address-failed' "New-NetIPAddress $ip on booth did not stick"; exit 1 }
Log ("{0} set on booth" -f $ip)

# 5. services that bound the old address.
switch ($L) {
    'A' { Restart-Service cascadia-node -Force; Log 'cascadia-node restarted'; Stop-ScheduledTask -TaskName booth-ca; Start-Sleep -Seconds 2; Start-ScheduledTask -TaskName booth-ca; Log 'booth-ca restarted' }
    'B' { Restart-Service cascadia-node -Force; Log 'cascadia-node restarted' }
    'C' { $t = Get-ScheduledTask -TaskName honyaku-single; if ($t -and $t.State -ne 'Disabled') { Stop-ScheduledTask -TaskName honyaku-single; Start-Sleep -Seconds 5; Start-ScheduledTask -TaskName honyaku-single; Log 'honyaku-single restarted' } }
}
$cu = (Get-CimInstance Win32_ComputerSystem).UserName
if ($cu -and $cu -notmatch '\\SYSTEM$') {
    if ($L -eq 'B') { Get-Process cascadia-desktop | Stop-Process -Force; Start-Sleep -Seconds 2; Start-ScheduledTask -TaskName booth-desktop; Log 'Desktop restarted' }
    Start-ScheduledTask -TaskName booth-kiosk; Log 'kiosk relaunched'
}
Set-State 'repaired' ("{0} on booth, services restarted" -f $ip)
