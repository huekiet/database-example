#!/usr/bin/env powershell
#
# deadlock-demo.ps1
# Reproduces an ABBA deadlock between two psql sessions, then shows the fix.
#
#   x = users.id 1, y = users.id 2
#
#   Demo 1 (deadlock): A updates x then y, B updates y then x. Each waits for
#                      the row held by the other; PostgreSQL aborts one session
#                      with SQLSTATE 40P01 ("deadlock detected").
#   Demo 2 (fixed):    A and B both update x then y. B waits for A at the first
#                      row; both transactions commit, no cycle.
#
# Usage (Windows PowerShell 5.1+):
#   powershell -ExecutionPolicy Bypass -File .\exercises\04-deadlock\deadlock-demo.ps1
#   powershell -ExecutionPolicy Bypass -File .\exercises\04-deadlock\deadlock-demo.ps1 -PauseSeconds 6

param(
    [int]$PauseSeconds = 4,
    [string]$DeadlockTimeout = '5s',
    [int]$OrderedHoldSeconds = 2,
    [string]$Container = 'pg-benchmark',
    [string]$Db = 'benchmark',
    [string]$User = 'benchmark',
    [string]$QueryDir = '/exercises/04-deadlock/queries'
)

# Native tools write NOTICEs/errors to stderr; handle exit codes explicitly.
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# psql helpers
#
# System.Diagnostics.Process is used instead of Start-Process because
# PowerShell 5.1 only fills in ExitCode when Start-Process is called with
# -Wait, which is not possible for the background session A.
# ---------------------------------------------------------------------------

function New-PsqlStartInfo([hashtable]$Vars) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'docker'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $list = @(
        'exec', '-i', $Container,
        'psql', '-U', $User, '-d', $Db,
        '-X', '-q', '-t', '-A', '-F', '"|"',
        '-v', 'ON_ERROR_STOP=1'
    )
    foreach ($key in $Vars.Keys) {
        $list += @('-v', "$key=$($Vars[$key])")
    }
    $psi.Arguments = ($list -join ' ')
    return $psi
}

function Start-PsqlSession {
    param([string]$File, [hashtable]$Vars = @{})

    $info = New-PsqlStartInfo $Vars
    $info.Arguments = $info.Arguments + " -f `"$QueryDir/$File`""

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    return $process
}

function Receive-PsqlSession {
    param([System.Diagnostics.Process]$Process)

    $stdout = $Process.StandardOutput.ReadToEnd()
    $stderr = $Process.StandardError.ReadToEnd()
    $Process.WaitForExit()

    return [pscustomobject]@{
        Output   = (($stdout + $stderr).Trim())
        ExitCode = $Process.ExitCode
    }
}

function Invoke-PsqlFile {
    param([string]$File, [hashtable]$Vars = @{})

    $process = Start-PsqlSession -File $File -Vars $Vars
    return Receive-PsqlSession $process
}

function Wait-ForDeadlock {
    param([int]$TimeoutMs = 30000)

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $result = Invoke-PsqlFile '08-waiting-pair-check.sql'
        $match = [regex]::Match($result.Output, '(?m)^\s*(\d+)\s*$')
        if ($result.ExitCode -eq 0 -and $match.Success -and [int]$match.Groups[1].Value -ge 2) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host ("=== " + $Title + " ===") -ForegroundColor Cyan
}

function Write-SessionResult([string]$Label, $Result) {
    Write-Host ("{0} exit code: {1}" -f $Label, $Result.ExitCode)
    if ($Result.Output) {
        Write-Host $Result.Output
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host "==> Waiting for PostgreSQL..."
for ($i = 0; $i -lt 60; $i++) {
    & docker exec $Container pg_isready -U $User -d $Db *> $null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 2
}

Write-Host "==> Row counts:"
& docker exec -i $Container psql -U $User -d $Db -X -q -t -A `
    -c "SELECT 'users=' || COUNT(*) FROM users UNION ALL SELECT 'orders=' || COUNT(*) FROM orders;"

# ---------------------------------------------------------------------------
# Demo 1: ABBA deadlock
# ---------------------------------------------------------------------------
Write-Section "Demo 1: A locks x then y, B locks y then x (deadlock)"
Invoke-PsqlFile '01-reset-demo-rows.sql' | Out-Null

$deadlockWatch = [System.Diagnostics.Stopwatch]::StartNew()
$sessionA = Start-PsqlSession '02-session-a-lock-x-then-y.sql' @{
    pause_seconds    = $PauseSeconds
    deadlock_timeout = $DeadlockTimeout
}
$sessionB = Start-PsqlSession '03-session-b-lock-y-then-x.sql' @{
    pause_seconds    = $PauseSeconds
    deadlock_timeout = $DeadlockTimeout
}

if (-not (Wait-ForDeadlock 30000)) {
    $aFailed = Receive-PsqlSession $sessionA
    $bFailed = Receive-PsqlSession $sessionB
    Write-SessionResult 'Session A' $aFailed
    Write-SessionResult 'Session B' $bFailed
    throw "The two sessions never waited on each other; no deadlock was observed."
}

Write-Host "Both sessions are waiting for the row held by the other:"
$observed = Invoke-PsqlFile '06-observe-deadlock.sql'
Write-Host $observed.Output

$aResult = Receive-PsqlSession $sessionA
$bResult = Receive-PsqlSession $sessionB
$deadlockWatch.Stop()

$results = @($aResult, $bResult)
$aborted = @($results | Where-Object { $_.ExitCode -ne 0 })
$deadlocked = @($results | Where-Object { $_.Output -match 'deadlock detected' })

Write-Host ""
Write-Host ("Total wall time: {0:N2} s" -f $deadlockWatch.Elapsed.TotalSeconds)
Write-SessionResult 'Session A' $aResult
Write-SessionResult 'Session B' $bResult

$final = Invoke-PsqlFile '07-current-rows.sql'
Write-Host ("Final rows: {0}" -f $final.Output)

if ($aborted.Count -eq 1 -and $deadlocked.Count -ge 1) {
    Write-Host "Result: PostgreSQL aborted exactly one session with SQLSTATE 40P01; the other committed."
} else {
    Write-Host "WARNING: expected exactly one aborted session with 'deadlock detected'."
}

# ---------------------------------------------------------------------------
# Demo 2: consistent lock order
# ---------------------------------------------------------------------------
Write-Section "Demo 2: both sessions lock x then y (fixed)"
Invoke-PsqlFile '01-reset-demo-rows.sql' | Out-Null

$orderedWatch = [System.Diagnostics.Stopwatch]::StartNew()
$sessionA = Start-PsqlSession '04-session-a-lock-ordered.sql' @{
    hold_seconds = $OrderedHoldSeconds
}
Start-Sleep -Milliseconds 500
$sessionB = Start-PsqlSession '05-session-b-lock-ordered.sql'

$aResult = Receive-PsqlSession $sessionA
$bResult = Receive-PsqlSession $sessionB
$orderedWatch.Stop()

Write-Host ("Total wall time: {0:N2} s" -f $orderedWatch.Elapsed.TotalSeconds)
Write-SessionResult 'Session A' $aResult
Write-SessionResult 'Session B' $bResult

$final = Invoke-PsqlFile '07-current-rows.sql'
Write-Host ("Final rows: {0}" -f $final.Output)

if ($aResult.ExitCode -eq 0 -and $bResult.ExitCode -eq 0) {
    Write-Host "Result: both sessions committed. B simply waited for A at users.id=1."
} else {
    Write-Host "WARNING: the ordered version should not produce an error."
}

# ---------------------------------------------------------------------------
# Restore the demo rows
# ---------------------------------------------------------------------------
Write-Section "Restore"
$reset = Invoke-PsqlFile '01-reset-demo-rows.sql'
Write-Host $reset.Output
$final = Invoke-PsqlFile '07-current-rows.sql'
Write-Host ("Final rows: {0}" -f $final.Output)

Write-Host ""
Write-Host "==> Deadlock demo complete."
