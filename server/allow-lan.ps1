# Run as administrator only if Windows Firewall blocks the phone connection.
$ErrorActionPreference = 'Stop'
$ruleName = 'LanCinema-ReadOnly-8123'
$existing = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if (-not $existing) {
    New-NetFirewallRule -Name $ruleName -DisplayName 'LanCinema read-only LAN videos' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8123 -RemoteAddress LocalSubnet -Program (Get-Command python -ErrorAction Stop).Source -Profile Any | Out-Null
}
Write-Host 'LAN access enabled for Python port 8123 from the local subnet only.'
