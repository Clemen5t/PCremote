#requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$InstallDir = "C:\PCRemote"
$AgentPath = Join-Path $InstallDir "Agent.ps1"
$ConfigPath = Join-Path $InstallDir "config.json"
$Port = 8765
$TaskName = "PC Remote Agent"
$FirewallName = "PC Remote iPhone"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$bytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$rng.Dispose()
$Secret = -join ($bytes | ForEach-Object { $_.ToString("x2") })

@{
    Port   = $Port
    Secret = $Secret
} | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8

$Agent = @'
$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Config = Get-Content (Join-Path $BaseDir "config.json") -Raw | ConvertFrom-Json
$Port = [int]$Config.Port
$Secret = [string]$Config.Secret

function Get-HmacHex {
    param([string]$Timestamp, [string]$Method, [string]$Path)

    $payload = "$Timestamp`n$Method`n$Path"
    $key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $data = [System.Text.Encoding]::UTF8.GetBytes($payload)

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $key
        $hash = $hmac.ComputeHash($data)
        return (-join ($hash | ForEach-Object { $_.ToString("x2") }))
    }
    finally {
        $hmac.Dispose()
    }
}

function Test-FixedTimeEqual {
    param([string]$A, [string]$B)

    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    if ($A.Length -ne $B.Length) { return $false }

    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $diff = $diff -bor (([int][char]$A[$i]) -bxor ([int][char]$B[$i]))
    }
    return ($diff -eq 0)
}

function Write-Response {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [string]$Json
    )

    $body = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $headers = "HTTP/1.1 $StatusCode $StatusText`r`n" +
               "Content-Type: application/json; charset=utf-8`r`n" +
               "Content-Length: $($body.Length)`r`n" +
               "Connection: close`r`n" +
               "Cache-Control: no-store`r`n`r`n"

    $head = [System.Text.Encoding]::ASCII.GetBytes($headers)
    $Stream.Write($head, 0, $head.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Test-Authorization {
    param([hashtable]$Headers, [string]$Method, [string]$Path)

    if (-not $Headers.ContainsKey("x-pc-time")) { return $false }
    if (-not $Headers.ContainsKey("x-pc-signature")) { return $false }

    $timestamp = [string]$Headers["x-pc-time"]
    $signature = ([string]$Headers["x-pc-signature"]).ToLowerInvariant()

    [long]$unix = 0
    if (-not [long]::TryParse($timestamp, [ref]$unix)) { return $false }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ([Math]::Abs($now - $unix) -gt 30) { return $false }

    $expected = Get-HmacHex -Timestamp $timestamp -Method $Method -Path $Path
    return (Test-FixedTimeEqual -A $expected -B $signature)
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
$listener.Start()

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 5000

        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader(
            $stream,
            [System.Text.Encoding]::ASCII,
            $false,
            4096,
            $true
        )

        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) {
            $client.Close()
            continue
        }

        $parts = $requestLine.Split(" ")
        if ($parts.Count -lt 2) {
            Write-Response -Stream $stream -StatusCode 400 -StatusText "Bad Request" -Json '{"ok":false,"error":"bad_request"}'
            $client.Close()
            continue
        }

        $method = $parts[0].ToUpperInvariant()
        $path = $parts[1].Split("?")[0]

        $headers = @{}
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line -or $line -eq "") { break }

            $idx = $line.IndexOf(":")
            if ($idx -gt 0) {
                $name = $line.Substring(0, $idx).Trim().ToLowerInvariant()
                $value = $line.Substring($idx + 1).Trim()
                $headers[$name] = $value
            }
        }

        if (-not (Test-Authorization -Headers $headers -Method $method -Path $path)) {
            Write-Response -Stream $stream -StatusCode 401 -StatusText "Unauthorized" -Json '{"ok":false,"error":"unauthorized"}'
            $client.Close()
            continue
        }

        if ($method -eq "GET" -and $path -eq "/status") {
            $obj = @{
                ok = $true
                computer = $env:COMPUTERNAME
                time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            }
            Write-Response -Stream $stream -StatusCode 200 -StatusText "OK" -Json ($obj | ConvertTo-Json -Compress)
            $client.Close()
            continue
        }

        if ($method -eq "POST" -and $path -eq "/action/shutdown") {
            Write-Response -Stream $stream -StatusCode 200 -StatusText "OK" -Json '{"ok":true,"action":"shutdown"}'
            $client.Close()
            Start-Sleep -Milliseconds 400
            Start-Process "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/s /t 0" -WindowStyle Hidden
            continue
        }

        if ($method -eq "POST" -and $path -eq "/action/restart") {
            Write-Response -Stream $stream -StatusCode 200 -StatusText "OK" -Json '{"ok":true,"action":"restart"}'
            $client.Close()
            Start-Sleep -Milliseconds 400
            Start-Process "$env:SystemRoot\System32\shutdown.exe" -ArgumentList "/r /t 0" -WindowStyle Hidden
            continue
        }

        Write-Response -Stream $stream -StatusCode 404 -StatusText "Not Found" -Json '{"ok":false,"error":"not_found"}'
        $client.Close()
    }
    catch {
        try {
            if ($client) { $client.Close() }
        } catch {}
        Start-Sleep -Milliseconds 100
    }
}
'@

Set-Content -Path $AgentPath -Value $Agent -Encoding UTF8

Get-NetFirewallRule -DisplayName $FirewallName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

New-NetFirewallRule `
    -DisplayName $FirewallName `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $Port `
    -RemoteAddress LocalSubnet `
    -Profile Any | Out-Null

$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$AgentPath`""

$Trigger = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger `
    -Principal $Principal `
    -Settings $Settings `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName

$net = Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq "Up" } |
    Select-Object -First 1

$IP = if ($net) { $net.IPv4Address.IPAddress } else { "A_VERIFIER" }
$MAC = if ($net) { $net.NetAdapter.MacAddress } else { "A_VERIFIER" }
$AdapterName = if ($net) { $net.InterfaceAlias } else { "" }

if ($AdapterName) {
    try {
        Set-NetAdapterPowerManagement -Name $AdapterName -WakeOnMagicPacket Enabled -ErrorAction Stop | Out-Null
    } catch {}
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " PC REMOTE EST INSTALLE" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "IP        : $IP"
Write-Host "PORT      : $Port"
Write-Host "MAC       : $MAC"
Write-Host "CLE       : $Secret"
Write-Host "ADAPTATEUR: $AdapterName"
Write-Host ""
Write-Host "Garde ces 4 valeurs. Ne publie jamais la CLE." -ForegroundColor Yellow
Write-Host "Pour l'allumage, active aussi Wake-on-LAN / Power On By PCI-E dans le BIOS/UEFI." -ForegroundColor Yellow
