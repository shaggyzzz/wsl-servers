<#
.SYNOPSIS
    WSL Laravel & Caddy Servers Manager
.DESCRIPTION
    Управление серверами php artisan serve, очередями, расписанием и Caddy в WSL из Windows.
#>

[CmdletBinding()]
param (
    [Parameter(Position = 0)]
    [ValidateSet("menu", "start", "stop", "status", "restart", "browser", "hosts", "logs", "clear-logs")]
    [string]$Action = "menu",

    [Parameter(Position = 1)]
    [string]$ConfigFile = ""
)

# Установка кодировки консоли
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Определение пути к конфигу
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $scriptDir) { $scriptDir = $PSScriptRoot }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

if (-not $ConfigFile) {
    $ConfigFile = Join-Path $scriptDir "projects.json"
}

# Снимает // и /* */ комментарии, не трогая строки в кавычках
function Remove-JsonComments {
    param([string]$Text)

    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $escape = $false
    $inLineComment = $false
    $inBlockComment = $false
    $chars = $Text.ToCharArray()

    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = $chars[$i]
        $next = if ($i + 1 -lt $chars.Length) { $chars[$i + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($c -eq "`n") {
                $inLineComment = $false
                [void]$sb.Append($c)
            }
            continue
        }

        if ($inBlockComment) {
            if ($c -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }

        if ($inString) {
            [void]$sb.Append($c)
            if ($escape) {
                $escape = $false
            } elseif ($c -eq '\') {
                $escape = $true
            } elseif ($c -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($c -eq '"') {
            $inString = $true
            [void]$sb.Append($c)
            continue
        }

        if ($c -eq '/' -and $next -eq '/') {
            $inLineComment = $true
            $i++
            continue
        }

        if ($c -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }

        [void]$sb.Append($c)
    }

    return $sb.ToString()
}

# Чтение JSON конфигурации (допускает // и /* */ комментарии)
function Get-Config {
    if (-not (Test-Path $ConfigFile)) {
        $exampleFile = Join-Path $scriptDir "projects.example.json"
        if (Test-Path $exampleFile) {
            Copy-Item $exampleFile $ConfigFile
            Write-Host "[NOTICE] Created $ConfigFile from projects.example.json" -ForegroundColor Yellow
            Write-Host "Please edit $ConfigFile with your project paths and run again.`n" -ForegroundColor Yellow
            exit 1
        }
        Write-Host "[ERROR] Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }
    try {
        $raw = Get-Content -Path $ConfigFile -Raw -Encoding UTF8
        return ((Remove-JsonComments $raw) | ConvertFrom-Json)
    } catch {
        Write-Host "[ERROR] Failed to parse config $ConfigFile : $_" -ForegroundColor Red
        exit 1
    }
}

# Выполнение команды в WSL через base64
function Invoke-WSL {
    param(
        [string]$Command,
        [switch]$ReturnOutput
    )
    $cfg = Get-Config
    $distro = $cfg.wsl_distro
    $user = $cfg.wsl_user

    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Command))
    $wslWrapper = "echo '$b64' | base64 -d | bash"

    if ($ReturnOutput) {
        $res = & wsl.exe -d $distro -u $user -- bash -c $wslWrapper 2>&1
        return ($res -join "`n")
    } else {
        & wsl.exe -d $distro -u $user -- bash -c $wslWrapper
    }
}

# Автоматическая обрезка логов (если лог > 5 МБ, оставляем последние 2000 строк)
function Trim-Logs {
    $trimScript = 'for f in ~/.wsl-servers/logs/*.log; do ' +
                  '[ -f "$f" ] && [ $(stat -c%s "$f" 2>/dev/null || echo 0) -gt 5242880 ] && ' +
                  '{ tail -n 2000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }; done'
    Invoke-WSL -Command $trimScript | Out-Null
}

# Очистка всех логов
function Clear-AllLogs {
    Write-Host "`nClearing all log files in WSL (~/.wsl-servers/logs/)..." -ForegroundColor Yellow
    Invoke-WSL -Command "rm -f ~/.wsl-servers/logs/*.log" | Out-Null
    Write-Host "[OK] All logs cleared successfully.`n" -ForegroundColor Green
}

# Проверка базы данных проекта
function Test-ProjectDatabase {
    param(
        $proj,
        [bool]$AutoStart = $false
    )

    if (-not $proj.database) {
        return @{ Status = "NONE"; Message = "-" }
    }

    $db = $proj.database
    $type = if ($db.type) { "$($db.type)".ToLower() } else { "port" }

    if ($type -eq "docker") {
        $container = $db.container
        if (-not $container) {
            return @{ Status = "ERROR"; Message = "Container name not set" }
        }

        $checkCmd = "docker inspect -f '{{.State.Running}}' $container 2>/dev/null"
        $isRunning = (Invoke-WSL -Command $checkCmd -ReturnOutput).Trim()

        if ($isRunning -eq "true") {
            return @{ Status = "UP"; Message = "Docker: $container (OK)" }
        } else {
            if ($AutoStart -and ($db.auto_start -eq $true)) {
                Write-Host "  -> Starting Docker container [$container]..." -ForegroundColor Cyan
                $startOut = Invoke-WSL -Command "docker start $container 2>&1" -ReturnOutput
                Start-Sleep -Seconds 1
                $recheck = (Invoke-WSL -Command $checkCmd -ReturnOutput).Trim()
                if ($recheck -eq "true") {
                    return @{ Status = "UP"; Message = "Docker: $container (Started)" }
                } else {
                    return @{ Status = "DOWN"; Message = "Docker: $container (Start failed)" }
                }
            } else {
                return @{ Status = "DOWN"; Message = "Docker: $container (Stopped)" }
            }
        }
    }
    elseif ($type -eq "port") {
        $p = $db.port
        $portCmd = "ss -tln | grep -qE ':($p)\b' && echo 'OPEN' || echo 'CLOSED'"
        $res = Invoke-WSL -Command $portCmd -ReturnOutput
        if ($res -match "OPEN") {
            return @{ Status = "UP"; Message = "Port $p (OK)" }
        } else {
            return @{ Status = "DOWN"; Message = "Port $p (Closed)" }
        }
    }

    return @{ Status = "UNKNOWN"; Message = "Unknown DB type" }
}

# Проверка статуса очереди
function Get-QueueStatus {
    param($proj)
    if (-not $proj.queue) { return "-" }
    $pn = $proj.name
    $cmd = "P=`$HOME/.wsl-servers/pids/$pn`_queue.pid; (([ -f `"`$P`" ] && kill -0 `$(cat `"`$P`") 2>/dev/null) || (pgrep -f 'artisan queue:.*$($proj.path)' >/dev/null 2>&1)) && echo 'RUNNING' || echo 'STOPPED'"
    return (Invoke-WSL -Command $cmd -ReturnOutput).Trim()
}

# Проверка статуса расписания
function Get-ScheduleStatus {
    param($proj)
    if (-not $proj.schedule) { return "-" }
    $pn = $proj.name
    $cmd = "P=`$HOME/.wsl-servers/pids/$pn`_schedule.pid; (([ -f `"`$P`" ] && kill -0 `$(cat `"`$P`") 2>/dev/null) || (pgrep -f 'artisan schedule:work.*$($proj.path)' >/dev/null 2>&1)) && echo 'RUNNING' || echo 'STOPPED'"
    return (Invoke-WSL -Command $cmd -ReturnOutput).Trim()
}

# Запуск всех серверов, очередей и расписаний
function Start-AllServers {
    $cfg = Get-Config
    Write-Host ""
    Write-Host "=== Starting WSL Laravel & Caddy Servers ===" -ForegroundColor Cyan

    # 1. Папки для логов и PID + ротация логов
    Invoke-WSL -Command "mkdir -p ~/.wsl-servers/logs ~/.wsl-servers/pids" | Out-Null
    Trim-Logs

    # 2. Проверка Caddy
    $caddyPath = (Invoke-WSL -Command "which caddy" -ReturnOutput).Trim()
    $hasCaddy = [bool]($caddyPath -match "/caddy")

    if (-not $hasCaddy) {
        Write-Host "[WARNING] Caddy not found in WSL ($($cfg.wsl_distro))!" -ForegroundColor Yellow
        Write-Host "  To enable domains without ports, install Caddy in WSL:" -ForegroundColor Yellow
        Write-Host "  sudo apt install -y caddy" -ForegroundColor White
        Write-Host "  Laravel servers will still start and be accessible via ports (e.g. :8001)" -ForegroundColor Yellow
        Write-Host ""
    } else {
        # Проверка прав для привязки к 80 порту
        $hasCap = (Invoke-WSL -Command "getcap '$caddyPath' 2>/dev/null | grep -q 'cap_net_bind_service' && echo 'YES' || echo 'NO'" -ReturnOutput).Trim()
        if ($hasCap -ne "YES") {
            & wsl.exe -d $cfg.wsl_distro -u root -- setcap 'cap_net_bind_service=+ep' $caddyPath 2>$null
        }

        # Если Caddy уже запущен - не трогаем его
        $caddyRunning = (Invoke-WSL -Command "pgrep -x caddy >/dev/null 2>&1 && echo 'RUNNING' || echo 'STOPPED'" -ReturnOutput).Trim()
        if ($caddyRunning -eq "RUNNING") {
            Write-Host "  -> Caddy is already running on ports 80 & 443 (untouched)" -ForegroundColor Green
        } else {
            $lines = @("{", "    admin off", "    skip_install_trust", "}")
            foreach ($p in $cfg.projects) {
                $lines += "$($p.domain) {"
                $lines += "    tls internal"
                $lines += "    reverse_proxy 127.0.0.1:$($p.port)"
                $lines += "}"
            }
            $content = $lines -join "`n"
            $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
            Invoke-WSL -Command "echo '$b64' | base64 -d > ~/.wsl-servers/Caddyfile" | Out-Null

            Write-Host "  -> Starting Caddy reverse proxy on port 80 & 443 (HTTPS)..." -ForegroundColor Gray
            Invoke-WSL -Command "caddy start --config ~/.wsl-servers/Caddyfile > ~/.wsl-servers/logs/caddy.log 2>&1" | Out-Null
        }
    }

    # 3. Автоматическая проверка доменов в Windows hosts и доверия SSL-сертификату
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $currentHosts = Get-Content -Path $hostsPath -Raw -ErrorAction SilentlyContinue
    $hasMissing = $false
    foreach ($p in $cfg.projects) {
        if ($currentHosts -notmatch "(?m)^\s*127\.0\.0\.1\s+.*\b$($p.domain)\b") {
            $hasMissing = $true
            break
        }
    }
    if ($hasMissing -or (-not (Test-CaddyCertTrusted))) {
        Update-WindowsHosts -Auto $true
    }

    # 4. Проверка и запуск проектов (только тех, которые еще НЕ запущены)
    foreach ($p in $cfg.projects) {
        $pn = $p.name
        Write-Host ""
        Write-Host "Project: $($p.name) (http://$($p.domain) -> :$($p.port))" -ForegroundColor White

        # Проверка наличия artisan
        $hasArtisan = (Invoke-WSL -Command "test -f '$($p.path)/artisan' && echo 'YES' || echo 'NO'" -ReturnOutput).Trim()
        if ($hasArtisan -ne "YES") {
            Write-Host "  [ERROR] artisan not found at: $($p.path)" -ForegroundColor Red
            continue
        }

        # --- 4.1 Веб-сервер php artisan serve ---
        $checkRunningCmd = "P=`$HOME/.wsl-servers/pids/$pn.pid; ((ss -tln | grep -qE ':($($p.port))\b') || ([ -f `"`$P`" ] && kill -0 `$(cat `"`$P`") 2>/dev/null) || (pgrep -f 'artisan serve.*$($p.port)' >/dev/null 2>&1)) && echo 'RUNNING' || echo 'STOPPED'"
        $serverState = (Invoke-WSL -Command $checkRunningCmd -ReturnOutput).Trim()

        if ($serverState -eq "RUNNING") {
            Write-Host "  [SERVER] Already running on port $($p.port) (untouched)" -ForegroundColor Green
        } else {
            # Проверка БД перед запуском веб-сервера
            if ($p.database) {
                $dbRes = Test-ProjectDatabase -proj $p -AutoStart $true
                if ($dbRes.Status -eq "UP") {
                    Write-Host "  [DB] $($dbRes.Message)" -ForegroundColor Green
                } else {
                    Write-Host "  [DB] $($dbRes.Message)" -ForegroundColor Yellow
                }
            }

            # Запуск php artisan serve в фоне через start-stop-daemon
            $startCmd = "start-stop-daemon --start --background --make-pidfile --pidfile ~/.wsl-servers/pids/$pn.pid --chdir '$($p.path)' --startas /bin/bash -- -c 'exec php artisan serve --host=127.0.0.1 --port=$($p.port) > ~/.wsl-servers/logs/$($pn).log 2>&1'"
            Invoke-WSL -Command $startCmd | Out-Null

            # Верификация запуска (до 3 сек)
            $verify = "FAIL"
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Milliseconds 200
                $check = (Invoke-WSL -Command "ss -tln | grep -qE ':($($p.port))\b' && echo 'OK' || echo 'FAIL'" -ReturnOutput).Trim()
                if ($check -eq "OK") {
                    $verify = "OK"
                    break
                }
            }

            if ($verify -eq "OK") {
                Write-Host "  [SERVER] Started successfully on :$($p.port)!" -ForegroundColor Green
            } else {
                Write-Host "  [SERVER] Failed to start! See log: ~/.wsl-servers/logs/$($pn).log" -ForegroundColor Red
                $lastLog = Invoke-WSL -Command "tail -n 5 ~/.wsl-servers/logs/$($pn).log 2>/dev/null" -ReturnOutput
                if ($lastLog) { Write-Host "  Log: $lastLog" -ForegroundColor DarkGray }
            }
        }

        # --- 4.2 Очереди (queue:listen) ---
        if ($p.queue) {
            $qState = Get-QueueStatus -proj $p
            if ($qState -eq "RUNNING") {
                Write-Host "  [QUEUE] Already running (untouched)" -ForegroundColor Green
            } else {
                $qCmd = "start-stop-daemon --start --background --make-pidfile --pidfile ~/.wsl-servers/pids/$($pn)_queue.pid --chdir '$($p.path)' --startas /bin/bash -- -c 'exec php artisan queue:listen --tries=3 > ~/.wsl-servers/logs/$($pn)_queue.log 2>&1'"
                Invoke-WSL -Command $qCmd | Out-Null
                Write-Host "  [QUEUE] Started (queue:listen)" -ForegroundColor Green
            }
        }

        # --- 4.3 Расписание (schedule:work) ---
        if ($p.schedule) {
            $sState = Get-ScheduleStatus -proj $p
            if ($sState -eq "RUNNING") {
                Write-Host "  [SCHEDULE] Already running (untouched)" -ForegroundColor Green
            } else {
                $sCmd = "start-stop-daemon --start --background --make-pidfile --pidfile ~/.wsl-servers/pids/$($pn)_schedule.pid --chdir '$($p.path)' --startas /bin/bash -- -c 'exec php artisan schedule:work > ~/.wsl-servers/logs/$($pn)_schedule.log 2>&1'"
                Invoke-WSL -Command $sCmd | Out-Null
                Write-Host "  [SCHEDULE] Started (schedule:work)" -ForegroundColor Green
            }
        }
    }

    Get-ServerStatus
}

# Остановка всех серверов, очередей и расписаний
function Stop-AllServers {
    $cfg = Get-Config
    Write-Host ""
    Write-Host "=== Stopping WSL Laravel & Caddy Servers ===" -ForegroundColor Yellow

    Write-Host "  -> Stopping Caddy..." -ForegroundColor Gray
    Invoke-WSL -Command "pkill -x caddy 2>/dev/null" | Out-Null

    foreach ($p in $cfg.projects) {
        $pn = $p.name
        Write-Host "  -> Stopping $($p.name)..." -ForegroundColor Gray

        # Остановка веб-сервера
        $stopServerBash = 'P="$HOME/.wsl-servers/pids/' + $pn + '.pid"; [ -f "$P" ] && { kill $(cat "$P") 2>/dev/null; rm -f "$P"; }'
        Invoke-WSL -Command $stopServerBash | Out-Null
        Invoke-WSL -Command "fuser -k $($p.port)/tcp 2>/dev/null || pkill -f 'artisan serve.*$($p.port)' 2>/dev/null" | Out-Null

        # Остановка очередей
        if ($p.queue) {
            $stopQueueBash = 'P="$HOME/.wsl-servers/pids/' + $pn + '_queue.pid"; [ -f "$P" ] && { kill $(cat "$P") 2>/dev/null; rm -f "$P"; }; pkill -f "artisan queue:.*' + $p.path + '" 2>/dev/null'
            Invoke-WSL -Command $stopQueueBash | Out-Null
        }

        # Остановка расписания
        if ($p.schedule) {
            $stopSchedBash = 'P="$HOME/.wsl-servers/pids/' + $pn + '_schedule.pid"; [ -f "$P" ] && { kill $(cat "$P") 2>/dev/null; rm -f "$P"; }; pkill -f "artisan schedule:work.*' + $p.path + '" 2>/dev/null'
            Invoke-WSL -Command $stopSchedBash | Out-Null
        }
    }

    Write-Host "[OK] All servers, queues and schedules stopped." -ForegroundColor Green
    Write-Host ""
}

# Проверка текущего статуса
function Get-ServerStatus {
    $cfg = Get-Config
    Trim-Logs
    Write-Host ""
    Write-Host "================================ SERVERS STATUS ================================" -ForegroundColor Cyan

    $caddyRunning = (Invoke-WSL -Command "pgrep -x caddy >/dev/null 2>&1 || (ss -tln | grep -qE ':(80|443)\b') && echo 'YES' || echo 'NO'" -ReturnOutput).Trim()
    if ($caddyRunning -eq "YES") {
        Write-Host "Caddy Reverse Proxy (HTTP:80 & HTTPS:443): " -NoNewline
        Write-Host "RUNNING" -ForegroundColor Green
    } else {
        Write-Host "Caddy Reverse Proxy (HTTP:80 & HTTPS:443): " -NoNewline
        Write-Host "STOPPED" -ForegroundColor DarkGray
    }
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Gray
    Write-Host ("{0,-11} | {1,-8} | {2,-6} | {3,-19} | {4,-6} | {5,-8} | {6,-8}" -f "PROJECT", "SERVER", "PORT", "URL", "DB", "QUEUE", "SCHEDULE") -ForegroundColor White
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Gray

    foreach ($p in $cfg.projects) {
        $pn = $p.name
        $checkCmd = "P=`$HOME/.wsl-servers/pids/$pn.pid; ((ss -tln | grep -qE ':($($p.port))\b') || ([ -f `"`$P`" ] && kill -0 `$(cat `"`$P`") 2>/dev/null) || (pgrep -f 'artisan serve.*$($p.port)' >/dev/null 2>&1)) && echo 'UP' || echo 'DOWN'"
        $portCheck = (Invoke-WSL -Command $checkCmd -ReturnOutput).Trim()
        $isUp = ($portCheck -eq "UP")

        $dbRes = Test-ProjectDatabase -proj $p
        $qStatus = Get-QueueStatus -proj $p
        $sStatus = Get-ScheduleStatus -proj $p

        Write-Host ("{0,-11} | " -f $p.name) -NoNewline

        # Сервер
        if ($isUp) {
            Write-Host "RUNNING  " -ForegroundColor Green -NoNewline
        } else {
            Write-Host "STOPPED  " -ForegroundColor DarkGray -NoNewline
        }

        # Порт и URL
        Write-Host (":{0,-5} | https://{1,-11} | " -f $p.port, $p.domain) -NoNewline

        # БД
        $dbShort = if ($dbRes.Status -eq "UP") { "OK" } elseif ($dbRes.Status -eq "DOWN") { "DOWN" } else { "-" }
        $dbColor = if ($dbRes.Status -eq "UP") { "Green" } elseif ($dbRes.Status -eq "DOWN") { "Yellow" } else { "DarkGray" }
        Write-Host ("{0,-6} | " -f $dbShort) -ForegroundColor $dbColor -NoNewline

        # Очередь
        $qColor = if ($qStatus -eq "RUNNING") { "Green" } elseif ($qStatus -eq "STOPPED") { "Red" } else { "DarkGray" }
        Write-Host ("{0,-8} | " -f $qStatus) -ForegroundColor $qColor -NoNewline

        # Расписание
        $sColor = if ($sStatus -eq "RUNNING") { "Green" } elseif ($sStatus -eq "STOPPED") { "Red" } else { "DarkGray" }
        Write-Host ("{0,-8}" -f $sStatus) -ForegroundColor $sColor
    }
    Write-Host "================================================================================" -ForegroundColor Cyan
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $currentHosts = Get-Content -Path $hostsPath -Raw -ErrorAction SilentlyContinue
    $missingInHosts = @()
    foreach ($p in $cfg.projects) {
        if ($currentHosts -notmatch "(?m)^\s*127\.0\.0\.1\s+.*\b$($p.domain)\b") {
            $missingInHosts += $p.domain
        }
    }
    if ($missingInHosts.Count -gt 0) {
        Write-Host ("  [!] Windows hosts: missing ({0}) -> Run option [6] or Start ALL" -f ($missingInHosts -join ", ")) -ForegroundColor Yellow
    }
    if (-not (Test-CaddyCertTrusted)) {
        Write-Host "  [!] Caddy SSL Certificate: NOT TRUSTED in Windows -> Run option [6] to enable green lock" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Открытие ссылок в браузере
function Open-BrowserTabs {
    $cfg = Get-Config
    Write-Host ""
    Write-Host "Opening project URLs in browser..." -ForegroundColor Cyan
    foreach ($p in $cfg.projects) {
        $url = "https://$($p.domain)/"
        Write-Host "  -> $url" -ForegroundColor Gray
        Start-Process $url
    }
}

# Проверка доверия сертификату Caddy в Windows
function Test-CaddyCertTrusted {
    $res = & certutil.exe -verifystore Root "Caddy Local Authority" 2>&1
    return [bool]($res -match "CertUtil: -verifystore.*completed successfully")
}

# Проверка и добавление доменов в hosts + доверие SSL Caddy
function Update-WindowsHosts {
    param([bool]$Auto = $false)
    $cfg = Get-Config
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    Write-Host ""
    Write-Host "=== Checking Windows hosts & SSL Certificate ===" -ForegroundColor Cyan

    $currentHosts = Get-Content -Path $hostsPath -Raw -ErrorAction SilentlyContinue

    $missing = @()
    foreach ($p in $cfg.projects) {
        $dom = $p.domain
        if ($currentHosts -notmatch "(?m)^\s*127\.0\.0\.1\s+.*\b$dom\b") {
            $missing += $dom
        }
    }

    $isCertTrusted = Test-CaddyCertTrusted
    $distro = $cfg.wsl_distro
    $user = $cfg.wsl_user
    $wslCertPath = "\\wsl.localhost\$distro\home\$user\.local\share\caddy\pki\authorities\local\root.crt"
    if (-not (Test-Path $wslCertPath)) {
        $wslCertPath = "\\wsl$\$distro\home\$user\.local\share\caddy\pki\authorities\local\root.crt"
    }
    $hasCert = (Test-Path $wslCertPath)
    $tempCrt = Join-Path $env:TEMP "caddy_root.crt"
    if ($hasCert) {
        Copy-Item $wslCertPath $tempCrt -Force -ErrorAction SilentlyContinue
    }

    if ($missing.Count -eq 0 -and $isCertTrusted) {
        Write-Host "[OK] All project domains are in hosts and Caddy SSL certificate is trusted!" -ForegroundColor Green
        return
    }

    if ($missing.Count -gt 0) {
        Write-Host "Missing domains in hosts: $($missing -join ', ')" -ForegroundColor Yellow
    }
    if (-not $isCertTrusted) {
        Write-Host "Caddy SSL root certificate is NOT trusted in Windows." -ForegroundColor Yellow
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        if ($missing.Count -gt 0) {
            $append = "`n# WSL Laravel Manager`n" + (($missing | ForEach-Object { "127.0.0.1 $_" }) -join "`n") + "`n"
            Add-Content -Path $hostsPath -Value $append -Encoding ASCII
            Write-Host "[OK] Domains added to $hostsPath!" -ForegroundColor Green
        }
        if (-not $isCertTrusted -and (Test-Path $tempCrt)) {
            & certutil.exe -addstore -f Root $tempCrt | Out-Null
            Write-Host "[OK] Caddy SSL root certificate trusted in Windows!" -ForegroundColor Green
        }
    } else {
        $doElevate = $true
        if (-not $Auto) {
            Write-Host ""
            Write-Host "Administrator privileges required to edit hosts and trust SSL certificate." -ForegroundColor Yellow
            $choice = Read-Host "Request Administrator elevation (UAC)? (Y/N)"
            $doElevate = ($choice -eq "Y" -or $choice -eq "y" -or -not $choice)
        }
        if ($doElevate) {
            $tmpBat = Join-Path $env:TEMP "wsl_hosts_elevate.bat"
            $batLines = @("@echo off")
            if ($missing.Count -gt 0) {
                $batLines += "echo. >> `"$hostsPath`""
                $batLines += "echo # WSL Laravel Manager >> `"$hostsPath`""
                foreach ($d in $missing) {
                    $batLines += "echo 127.0.0.1 $d >> `"$hostsPath`""
                }
            }
            if (-not $isCertTrusted -and (Test-Path $tempCrt)) {
                $batLines += "certutil.exe -addstore -f Root `"$tempCrt`" >nul 2>&1"
            }
            Set-Content -Path $tmpBat -Value ($batLines -join "`r`n") -Encoding ASCII
            Write-Host "  -> Requesting UAC elevation to update hosts and trust SSL certificate..." -ForegroundColor Cyan
            Start-Process cmd.exe -Verb RunAs -Wait -ArgumentList "/c", "`"$tmpBat`""
            Remove-Item -Path $tmpBat -Force -ErrorAction SilentlyContinue

            if ($missing.Count -gt 0) {
                $stillMissing = @()
                for ($i = 0; $i -lt 10; $i++) {
                    Start-Sleep -Milliseconds 200
                    $recheckHosts = Get-Content -Path $hostsPath -Raw -ErrorAction SilentlyContinue
                    $stillMissing = @()
                    foreach ($d in $missing) {
                        if ($recheckHosts -notmatch "(?m)^\s*127\.0\.0\.1\s+.*\b$d\b") { $stillMissing += $d }
                    }
                    if ($stillMissing.Count -eq 0) { break }
                }
                if ($stillMissing.Count -eq 0) {
                    Write-Host "[OK] Domains verified in Windows hosts!" -ForegroundColor Green
                } else {
                    Write-Host "[WARNING] Elevation was cancelled or hosts update failed." -ForegroundColor Yellow
                }
            }

            if (Test-CaddyCertTrusted) {
                Write-Host "[OK] Caddy SSL root certificate trusted in Windows (HTTPS active)!" -ForegroundColor Green
            }
        } else {
            Write-Host "Add these lines manually to $hostsPath :" -ForegroundColor Yellow
            foreach ($d in $missing) {
                Write-Host "127.0.0.1 $d" -ForegroundColor Cyan
            }
        }
    }
}

# Просмотр логов
function Show-LogsMenu {
    Write-Host ""
    Write-Host "Listing available log files in ~/.wsl-servers/logs/ ..." -ForegroundColor Cyan
    $listCmd = 'for f in ~/.wsl-servers/logs/*.log; do [ -f "$f" ] && basename "$f"; done'
    $rawLogs = Invoke-WSL -Command $listCmd -ReturnOutput
    $logFiles = @($rawLogs.Split("`n") | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })

    if ($logFiles.Count -eq 0) {
        Write-Host "No log files found yet.`n" -ForegroundColor Yellow
        pause
        return
    }

    for ($i = 0; $i -lt $logFiles.Count; $i++) {
        Write-Host "  [$($i + 1)] $($logFiles[$i])"
    }
    Write-Host "  [0] Back"

    $choice = Read-Host "`nSelect log file (0-$($logFiles.Count))"
    if ($choice -eq "0" -or -not $choice) { return }

    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx)) {
        $idx = $idx - 1
        if ($idx -ge 0 -and $idx -lt $logFiles.Count) {
            $chosen = $logFiles[$idx]
            Write-Host "`n--- Last 35 lines ($chosen) ---" -ForegroundColor Yellow
            $out = Invoke-WSL -Command "tail -n 35 ~/.wsl-servers/logs/$chosen 2>/dev/null" -ReturnOutput
            Write-Host $out -ForegroundColor Gray
            Write-Host "---------------------------------------" -ForegroundColor Yellow
            pause
        }
    }
}

# Интерактивное главное меню
function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host "================================================================================" -ForegroundColor Cyan
        Write-Host "                   WSL LARAVEL, QUEUE & CADDY MANAGER                           " -ForegroundColor White
        Write-Host "================================================================================" -ForegroundColor Cyan

        Get-ServerStatus

        $cfg = Get-Config
        $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
        $currentHosts = Get-Content -Path $hostsPath -Raw -ErrorAction SilentlyContinue
        $missingHosts = @()
        foreach ($p in $cfg.projects) {
            if ($currentHosts -notmatch "(?m)^\s*127\.0\.0\.1\s+.*\b$($p.domain)\b") {
                $missingHosts += $p.domain
            }
        }

        Write-Host "Actions:" -ForegroundColor White
        Write-Host "  [1] Start ALL (Servers, Queues, Schedules - skips running)" -ForegroundColor Green
        Write-Host "  [2] Stop ALL" -ForegroundColor Yellow
        Write-Host "  [3] Restart ALL" -ForegroundColor Cyan
        Write-Host "  [4] Refresh status" -ForegroundColor White
        Write-Host "  [5] Open sites in browser" -ForegroundColor Magenta
        $isCertOk = Test-CaddyCertTrusted
        if ($missingHosts.Count -gt 0 -or (-not $isCertOk)) {
            $notes = @()
            if ($missingHosts.Count -gt 0) { $notes += "Hosts: $($missingHosts -join ', ')" }
            if (-not $isCertOk) { $notes += "SSL untrusted" }
            Write-Host ("  [6] Setup Windows hosts & SSL certificate [!] {0}" -f ($notes -join " | ")) -ForegroundColor Yellow
        } else {
            Write-Host "  [6] Setup Windows hosts & SSL certificate (OK)" -ForegroundColor Blue
        }
        Write-Host "  [7] View logs" -ForegroundColor Gray
        Write-Host "  [8] Clear all logs" -ForegroundColor DarkYellow
        Write-Host "  [0] Exit" -ForegroundColor DarkGray
        Write-Host "--------------------------------------------------------------------------------" -ForegroundColor Gray

        $sel = Read-Host "Select option (0-8)"
        switch ($sel) {
            "1" { Start-AllServers; pause }
            "2" { Stop-AllServers; pause }
            "3" { Stop-AllServers; Start-Sleep -Seconds 1; Start-AllServers; pause }
            "4" { }
            "5" { Open-BrowserTabs; pause }
            "6" { Update-WindowsHosts; pause }
            "7" { Show-LogsMenu }
            "8" { Clear-AllLogs; pause }
            "0" { exit 0 }
            default { Write-Host "Invalid option" -ForegroundColor Red; Start-Sleep -Milliseconds 800 }
        }
    }
}

# Маршрутизация аргументов
switch ($Action) {
    "start"      { Start-AllServers }
    "stop"       { Stop-AllServers }
    "status"     { Get-ServerStatus }
    "restart"    { Stop-AllServers; Start-Sleep -Seconds 1; Start-AllServers }
    "browser"    { Open-BrowserTabs }
    "hosts"      { Update-WindowsHosts }
    "logs"       { Show-LogsMenu }
    "clear-logs" { Clear-AllLogs }
    default      { Show-Menu }
}
