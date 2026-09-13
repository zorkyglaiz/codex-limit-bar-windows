$ErrorActionPreference = 'SilentlyContinue'
$base = Split-Path -Parent $MyInvocation.MyCommand.Path
$probe = Join-Path $base 'CodexLimitProbe.ps1'
$temp = Join-Path $env:TEMP 'CodexLimitBar-diagnostic-result.json'
$log  = Join-Path $env:TEMP 'CodexLimitBar-diagnostic.log'
$status = Join-Path $env:TEMP 'CodexLimitBar-diagnostic-status.txt'
foreach ($p in @($temp,$log,$status)) { try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } } catch { } }

Write-Host 'Codex Limit Bar diagnostic 1.1.0' -ForegroundColor Cyan
Write-Host 'This version prints every checkpoint immediately.' -ForegroundColor DarkGray
Write-Host ''

$psExe = Join-Path $PSHOME 'powershell.exe'
$args = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}" -DiagnosticLogPath "{2}" -StatusPath "{3}" -VerboseConsole' -f $probe,$temp,$log,$status)
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $psExe
$psi.Arguments = $args
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$p = New-Object Diagnostics.Process
$p.StartInfo = $psi
[void]$p.Start()

$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
$deadline = [datetime]::Now.AddSeconds(25)
$lastLen = 0
while (-not $p.HasExited -and [datetime]::Now -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $log) {
        try {
            $txt = Get-Content -LiteralPath $log -Raw -ErrorAction Stop
            if ($txt.Length -gt $lastLen) {
                $delta = $txt.Substring($lastLen)
                Write-Host $delta -NoNewline
                $lastLen = $txt.Length
            }
        } catch { }
    }
}
if (-not $p.HasExited) {
    Write-Host ''
    Write-Host '[TIMEOUT] Probe did not finish in 25 seconds. Killing it.' -ForegroundColor Yellow
    try { $p.Kill() } catch { }
}
try { $p.WaitForExit(2000) | Out-Null } catch { }
if (Test-Path -LiteralPath $log) {
    try {
        $txt = Get-Content -LiteralPath $log -Raw
        if ($txt.Length -gt $lastLen) { Write-Host $txt.Substring($lastLen) -NoNewline }
    } catch { }
}
Write-Host ''
Write-Host '--- RESULT ---' -ForegroundColor Cyan
if (Test-Path -LiteralPath $temp) {
    try { Get-Content -LiteralPath $temp -Raw | Write-Host } catch { Write-Host 'Could not read result file.' }
} else {
    Write-Host 'Result file was not created.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Press Enter to close.' -ForegroundColor DarkGray
[void](Read-Host)
