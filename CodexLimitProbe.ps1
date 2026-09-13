param(
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$DiagnosticLogPath = '',
    [string]$StatusPath = '',
    [switch]$VerboseConsole
)

$ErrorActionPreference = 'SilentlyContinue'
$script:Version = '1.1.0'
$script:Diag = New-Object System.Collections.Generic.List[string]

function Set-Stage([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    if ($StatusPath) {
        try { [IO.File]::WriteAllText($StatusPath, $text, (New-Object Text.UTF8Encoding($false))) } catch { }
    }
}

function Add-Diag([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    [void]$script:Diag.Add($text)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $text)
    if ($DiagnosticLogPath) {
        try { Add-Content -LiteralPath $DiagnosticLogPath -Value $line -Encoding UTF8 } catch { }
    }
    if ($VerboseConsole) { Write-Host $line }
}

function Get-PropertyValue($obj, [string[]]$names) {
    if ($null -eq $obj) { return $null }
    foreach ($name in $names) {
        $p = $obj.PSObject.Properties[$name]
        if ($null -ne $p) { return $p.Value }
    }
    return $null
}

function Clamp-Percent([double]$value) {
    if ($value -lt 0) { return 0 }
    if ($value -gt 100) { return 100 }
    return [math]::Round($value, 1)
}

function Convert-Window($window) {
    if ($null -eq $window) { return $null }
    $used = Get-PropertyValue $window @('usedPercent','used_percent')
    $mins = Get-PropertyValue $window @('windowDurationMins','window_minutes')
    $reset = Get-PropertyValue $window @('resetsAt','resets_at')
    if ($null -eq $used) { return $null }
    try { $usedD = [Convert]::ToDouble($used, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
    $minsI = $null
    if ($null -ne $mins) { try { $minsI = [int64]$mins } catch { } }
    $resetI = $null
    if ($null -ne $reset) { try { $resetI = [int64]$reset } catch { } }
    [pscustomobject]@{
        usedPercent = (Clamp-Percent $usedD)
        remainingPercent = (Clamp-Percent (100.0 - $usedD))
        windowMinutes = $minsI
        resetAtEpoch = $resetI
    }
}

function Build-UsageResult($snapshot, [string]$source, [int64]$observedAtEpoch) {
    if ($null -eq $snapshot) { return $null }
    $limitId = Get-PropertyValue $snapshot @('limitId','limit_id')
    if ($limitId -and [string]$limitId -ne 'codex') { return $null }

    $windows = New-Object System.Collections.ArrayList
    foreach ($slotName in @('primary','secondary')) {
        $slot = Get-PropertyValue $snapshot @($slotName)
        $w = Convert-Window $slot
        if ($null -ne $w) { [void]$windows.Add($w) }
    }
    if ($windows.Count -eq 0) {
        $w = Convert-Window $snapshot
        if ($null -ne $w) { [void]$windows.Add($w) }
    }
    if ($windows.Count -eq 0) { return $null }

    $five = $windows | Where-Object { $_.windowMinutes -eq 300 } | Select-Object -First 1
    $weekly = $windows | Where-Object { $_.windowMinutes -eq 10080 } | Select-Object -First 1
    if ($null -eq $five) { $five = $windows | Where-Object { $null -ne $_.windowMinutes -and $_.windowMinutes -ge 240 -and $_.windowMinutes -le 360 } | Select-Object -First 1 }
    if ($null -eq $weekly) { $weekly = $windows | Where-Object { $null -ne $_.windowMinutes -and $_.windowMinutes -ge 9000 -and $_.windowMinutes -le 11000 } | Select-Object -First 1 }
    $plan = Get-PropertyValue $snapshot @('planType','plan_type')

    [pscustomobject]@{
        status = 'ok'
        source = $source
        planType = if ($plan) { [string]$plan } else { '' }
        observedAtEpoch = $observedAtEpoch
        fiveHour = $five
        weekly = $weekly
        firstWindow = ($windows | Select-Object -First 1)
    }
}

function Write-Result($obj) {
    try {
        $dir = Split-Path -Parent $OutputPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = $OutputPath + '.tmp'
        $json = $obj | ConvertTo-Json -Depth 10 -Compress
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $OutputPath -Force
    } catch { Add-Diag ('write result failed: ' + $_.Exception.Message) }
}

function Find-RateLimitsInSessionObject($obj) {
    if ($null -eq $obj) { return $null }
    $direct = Get-PropertyValue $obj @('rate_limits','rateLimits')
    if ($null -ne $direct) { return $direct }
    $payload = Get-PropertyValue $obj @('payload')
    if ($null -ne $payload) {
        $p = Get-PropertyValue $payload @('rate_limits','rateLimits')
        if ($null -ne $p) { return $p }
        $info = Get-PropertyValue $payload @('info')
        if ($null -ne $info) {
            $i = Get-PropertyValue $info @('rate_limits','rateLimits')
            if ($null -ne $i) { return $i }
        }
    }
    return $null
}

function Get-ObservationEpoch($obj, $file) {
    try {
        $ts = Get-PropertyValue $obj @('timestamp')
        if ($ts) { return ([DateTimeOffset]::Parse([string]$ts)).ToUnixTimeSeconds() }
    } catch { }
    try { return ([DateTimeOffset]$file.LastWriteTime).ToUnixTimeSeconds() } catch { return [DateTimeOffset]::Now.ToUnixTimeSeconds() }
}

function Get-RecentSessionFiles {
    $sessions = Join-Path $env:USERPROFILE '.codex\sessions'
    Add-Diag ('sessions path: ' + $sessions)
    if (-not (Test-Path -LiteralPath $sessions)) {
        Add-Diag 'sessions folder not found'
        return @()
    }

    $files = New-Object System.Collections.ArrayList
    foreach ($offset in 0..3) {
        $d = (Get-Date).Date.AddDays(-$offset)
        $folder = Join-Path (Join-Path (Join-Path $sessions $d.ToString('yyyy')) $d.ToString('MM')) $d.ToString('dd')
        if (Test-Path -LiteralPath $folder) {
            Add-Diag ('session day found: ' + $folder)
            $dayFiles = @(Get-ChildItem -LiteralPath $folder -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue)
            foreach ($f in $dayFiles) { [void]$files.Add($f) }
        }
    }
    $out = @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 8)
    Add-Diag ('recent rollout files: ' + $out.Count)
    return $out
}

function Read-FileTailBounded($file, [int]$maxBytes = 2097152) {
    # Never use Get-Content -Tail here. On some large/active rollout JSONL files
    # Windows PowerShell 5.1 can spend a very long time seeking backwards.
    # Read at most the final 2 MiB with FileShare.ReadWrite instead.
    $fs = $null
    try {
        $fs = New-Object IO.FileStream($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $len = $fs.Length
        if ($len -le 0) { return @() }
        $count = [int][math]::Min([int64]$maxBytes, $len)
        $start = $len - $count
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $n = $fs.Read($buffer, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -le 0) { return @() }
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
        $lines = @($text -split "`r?`n")
        # If we started in the middle of a JSONL record, drop that fragment.
        if ($start -gt 0 -and $lines.Count -gt 0) {
            if ($lines.Count -eq 1) { return @() }
            $lines = @($lines[1..($lines.Count - 1)])
        }
        return $lines
    } catch {
        Add-Diag ('bounded tail read failed: ' + $_.Exception.Message)
        return @()
    } finally {
        if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
    }
}

function Get-UsageFromSessionFiles {
    Set-Stage 'Проверяю свежий локальный кэш…'
    $files = @(Get-RecentSessionFiles)
    if ($files.Count -eq 0) { return $null }

    foreach ($file in $files) {
        $ageHours = ([datetime]::Now - $file.LastWriteTime).TotalHours
        $sizeMB = [math]::Round($file.Length / 1MB, 1)
        Add-Diag ('session candidate: {0}; age={1:N1}h; size={2}MB' -f $file.Name, $ageHours, $sizeMB)
        # Session data is only a fallback. Do not present old quota snapshots as current.
        if ($ageHours -gt 24) {
            Add-Diag ('skip stale session (>24h): ' + $file.Name)
            continue
        }
        Add-Diag ('bounded scan tail (max 2MiB): ' + $file.Name)
        $lines = @(Read-FileTailBounded $file 2097152)
        Add-Diag ('tail lines read: ' + $lines.Count)
        if ($lines.Count -eq 0) { continue }
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            if ($line -notmatch 'rate_limits|rateLimits') { continue }
            try {
                $obj = $line | ConvertFrom-Json -ErrorAction Stop
                $rl = Find-RateLimitsInSessionObject $obj
                if ($null -eq $rl) { continue }
                $usage = Build-UsageResult $rl 'локальная сессия Codex' (Get-ObservationEpoch $obj $file)
                if ($null -ne $usage) {
                    Add-Diag ('local rate_limits hit: ' + $file.Name)
                    return $usage
                }
            } catch { }
        }
    }
    Add-Diag 'fresh rate_limits not found in bounded session tails'
    return $null
}

function Select-RateLimitSnapshot($result) {
    if ($null -eq $result) { return $null }
    $byId = Get-PropertyValue $result @('rateLimitsByLimitId')
    if ($null -ne $byId) {
        $p = $byId.PSObject.Properties['codex']
        if ($null -ne $p) { return $p.Value }
    }
    return (Get-PropertyValue $result @('rateLimits'))
}

function Get-CodexLaunchers {
    Set-Stage 'Ищу codex.exe…'
    $items = New-Object System.Collections.ArrayList

    function Add-Candidate([string]$path, [string]$label) {
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $full = $path
        try { $full = [IO.Path]::GetFullPath($path) } catch { }
        if (-not (@($items) -contains $full)) {
            [void]$items.Add($full)
            Add-Diag ($label + ': ' + $full)
        }
    }

    if ($env:CODEX_CLI_PATH) { Add-Candidate $env:CODEX_CLI_PATH 'CODEX_CLI_PATH' }

    # Microsoft Store build: prefer the runnable backend copy in LocalAppData.
    # Bounded wildcard search only; no WMI, no Get-AppxPackage and no whole-disk recursion.
    $cacheBase = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    Add-Diag ('Store cache path: ' + $cacheBase)
    if (Test-Path -LiteralPath $cacheBase) {
        $patterns = @(
            (Join-Path $cacheBase 'codex.exe'),
            (Join-Path $cacheBase '*\codex.exe'),
            (Join-Path $cacheBase '*\*\codex.exe'),
            (Join-Path $cacheBase '*\*\*\codex.exe')
        )
        foreach ($pattern in $patterns) {
            $hits = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 4)
            foreach ($hit in $hits) { Add-Candidate $hit.FullName 'Store backend' }
        }
    }

    $cmd = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and $cmd.Source) { Add-Candidate $cmd.Source 'PATH' }

    foreach ($c in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'),
        (Join-Path $env:APPDATA 'npm\codex.cmd'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\codex.exe')
    )) { Add-Candidate $c 'fixed path' }

    $result = @($items | Select-Object -Unique)
    Add-Diag ('codex candidates: ' + $result.Count)
    return $result
}

function Read-JsonLineForId($proc, $wantedId, [int]$timeoutMs) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $task = $proc.StandardOutput.ReadLineAsync()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $left = $timeoutMs - [int]$sw.ElapsedMilliseconds
        if ($left -lt 1) { break }
        $slice = [Math]::Min(200, $left)
        if ($task.Wait($slice)) {
            $line = $task.Result
            if ($null -eq $line) { break }
            if ($line.Trim().Length -gt 0) {
                try {
                    $obj = $line | ConvertFrom-Json -ErrorAction Stop
                    if ($null -ne $obj.id -and [string]$obj.id -eq [string]$wantedId) { return $obj }
                } catch { }
            }
            $task = $proc.StandardOutput.ReadLineAsync()
        }
    }
    return $null
}

function Invoke-CodexRateLimitsWithLauncher([string]$launcher) {
    Set-Stage 'Свежие лимиты через app-server…'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $ext = [IO.Path]::GetExtension($launcher).ToLowerInvariant()
    if ($ext -eq '.cmd' -or $ext -eq '.bat') {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = ('/d /s /c ""{0}" app-server --listen stdio://"' -f $launcher)
    } else {
        $psi.FileName = $launcher
        $psi.Arguments = 'app-server --listen stdio://'
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $false

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        Add-Diag ('starting app-server: ' + $launcher)
        if (-not $proc.Start()) { Add-Diag 'Process.Start returned false'; return $null }
        Add-Diag ('app-server pid: ' + $proc.Id)

        $init = '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-limit-bar","title":"Codex Limit Bar","version":"1.1.0"},"capabilities":{"experimentalApi":false}}}'
        $proc.StandardInput.WriteLine($init)
        $proc.StandardInput.Flush()
        $initReply = Read-JsonLineForId $proc 1 4500
        if ($null -eq $initReply) { Add-Diag 'initialize timeout'; return $null }
        if ($null -ne $initReply.error) { Add-Diag ('initialize error: ' + ($initReply.error | ConvertTo-Json -Compress)); return $null }
        Add-Diag 'initialize ok'

        $proc.StandardInput.WriteLine('{"method":"initialized"}')
        $proc.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read"}')
        $proc.StandardInput.Flush()
        $reply = Read-JsonLineForId $proc 2 7000
        if ($null -eq $reply) { Add-Diag 'rateLimits timeout'; return $null }
        if ($null -ne $reply.error) { Add-Diag ('rateLimits error: ' + ($reply.error | ConvertTo-Json -Compress)); return $null }
        if ($null -eq $reply.result) { Add-Diag 'rateLimits empty result'; return $null }
        $snapshot = Select-RateLimitSnapshot $reply.result
        if ($null -eq $snapshot) { Add-Diag 'rateLimits snapshot missing'; return $null }
        Add-Diag 'account/rateLimits/read ok'
        return Build-UsageResult $snapshot 'Codex app-server' ([DateTimeOffset]::Now.ToUnixTimeSeconds())
    } catch {
        Add-Diag ('app-server exception: ' + $_.Exception.Message)
        return $null
    } finally {
        try { $proc.StandardInput.Close() } catch { }
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { $proc.Dispose() } catch { }
    }
}

function Invoke-CodexRateLimits {
    $launchers = @(Get-CodexLaunchers)
    if ($launchers.Count -eq 0) { Add-Diag 'codex executable not found'; return $null }
    foreach ($launcher in @($launchers | Select-Object -First 2)) {
        $result = Invoke-CodexRateLimitsWithLauncher $launcher
        if ($null -ne $result) { return $result }
    }
    Add-Diag 'all app-server candidates failed'
    return $null
}

Add-Diag ('probe start v' + $script:Version)
Add-Diag ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
Add-Diag ('USERPROFILE: ' + $env:USERPROFILE)
Add-Diag ('LOCALAPPDATA: ' + $env:LOCALAPPDATA)

# Prefer the official read-only app-server RPC. It is the current source of truth
# and avoids touching potentially huge rollout files on the normal path.
$live = Invoke-CodexRateLimits
if ($null -ne $live) {
    $live | Add-Member -NotePropertyName diagnostic -NotePropertyValue @($script:Diag) -Force
    Write-Result $live
    Set-Stage 'Готово'
    Add-Diag 'live result written'
    exit 0
}

Add-Diag 'live read unavailable; trying bounded local fallback'
$cached = Get-UsageFromSessionFiles
if ($null -ne $cached) {
    $cached | Add-Member -NotePropertyName diagnostic -NotePropertyValue @($script:Diag) -Force
    Write-Result $cached
    Set-Stage 'Локальные данные'
    Add-Diag 'using fresh local fallback'
    exit 0
}

Set-Stage 'Лимиты не найдены'
Write-Result ([pscustomobject]@{
    status = 'error'
    message = 'Лимиты не найдены. Запустите Diagnose.cmd.'
    diagnostic = @($script:Diag)
    observedAtEpoch = [DateTimeOffset]::Now.ToUnixTimeSeconds()
})
Add-Diag 'probe finished without data'
exit 1
