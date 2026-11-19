#!/usr/bin/env powershell
#
# locking-demo.ps1
# Demonstrates a row-level lock when two transactions update the same row.
#
# Scenario 1: session A updates users.id=1 and holds the lock; session B runs
#             the same UPDATE and blocks until A commits.
# Scenario 2: session B uses lock_timeout and aborts after N seconds.
# Scenario 3: session B uses SELECT ... FOR UPDATE NOWAIT and fails instantly.
#
# Usage (Windows PowerShell 5.1+):
#   powershell -ExecutionPolicy Bypass -File .\exercises\03-locking\locking-demo.ps1
#   powershell -ExecutionPolicy Bypass -File .\exercises\03-locking\locking-demo.ps1 -LockSeconds 15

param(
    [int]$LockSeconds = 10,
    [int]$LockTimeoutSeconds = 2,
    [string]$Container = 'pg-benchmark',
    [string]$Db = 'benchmark',
    [string]$User = 'benchmark',
    [string]$QueryDir = '/exercises/03-locking/queries'
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

function Wait-ForRowLock {
    param([int]$TimeoutMs = 8000)

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        $result = Invoke-PsqlFile '07-lock-held-check.sql'
        $match = [regex]::Match($result.Output, '(?m)^\s*(\d+)\s*$')
        if ($result.ExitCode -eq 0 -and $match.Success -and [int]$match.Groups[1].Value -ge 1) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host ("=== " + $Title + " ===") -ForegroundColor Cyan
}

function Get-LastRow([string]$Output) {
    $lines = $Output -split "`r?`n" | Where-Object { $_.Trim() -ne '' }
    return $lines[-1]
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
# Demo 1: same-row UPDATE blocks
# ---------------------------------------------------------------------------
Write-Section "Demo 1: two sessions UPDATE the same row"
Invoke-PsqlFile '01-reset-demo-row.sql' | Out-Null

$sessionA = Start-PsqlSession '02-session-a-hold-lock.sql' @{ lock_seconds = $LockSeconds }
if (-not (Wait-ForRowLock 8000)) {
    throw "Session A did not acquire the row lock in time."
}
Write-Host "Session A holds the lock on users.id=1 (sleeping $LockSeconds s)..."

$blockedWatch = [System.Diagnostics.Stopwatch]::StartNew()
$sessionB = Start-PsqlSession '03-session-b-blocked-update.sql'
Start-Sleep -Seconds 2

Write-Host "Session B has been waiting; current lock state:"
$observed = Invoke-PsqlFile '06-observe-waits.sql'
Write-Host $observed.Output

$bResult = Receive-PsqlSession $sessionB
$blockedWatch.Stop()
$aResult = Receive-PsqlSession $sessionA

Write-Host ""
Write-Host ("Session B wall time (including startup): {0:N2} s" -f $blockedWatch.Elapsed.TotalSeconds)
Write-Host ("Session B exit code: {0}" -f $bResult.ExitCode)
Write-Host ("Final demo row: {0}" -f (Get-LastRow $bResult.Output))
Write-Host "Note: B waited for A's lock, then overwrote A's value (lost update)."

# ---------------------------------------------------------------------------
# Demo 2: lock_timeout instead of waiting
# ---------------------------------------------------------------------------
Write-Section "Demo 2: session B uses lock_timeout = ${LockTimeoutSeconds}s"
Invoke-PsqlFile '01-reset-demo-row.sql' | Out-Null

$sessionA = Start-PsqlSession '02-session-a-hold-lock.sql' @{ lock_seconds = 6 }
if (-not (Wait-ForRowLock 8000)) {
    throw "Session A did not acquire the row lock in time."
}

$timeoutWatch = [System.Diagnostics.Stopwatch]::StartNew()
$timeoutResult = Invoke-PsqlFile '04-session-b-lock-timeout.sql' @{ lock_timeout = "$($LockTimeoutSeconds)s" }
$timeoutWatch.Stop()
$aResult = Receive-PsqlSession $sessionA

Write-Host ("Elapsed: {0:N2} s, exit code: {1}" -f $timeoutWatch.Elapsed.TotalSeconds, $timeoutResult.ExitCode)
Write-Host $timeoutResult.Output

# ---------------------------------------------------------------------------
# Demo 3: NOWAIT fails immediately
# ---------------------------------------------------------------------------
Write-Section "Demo 3: session B uses SELECT ... FOR UPDATE NOWAIT"
Invoke-PsqlFile '01-reset-demo-row.sql' | Out-Null

$sessionA = Start-PsqlSession '02-session-a-hold-lock.sql' @{ lock_seconds = 6 }
if (-not (Wait-ForRowLock 8000)) {
    throw "Session A did not acquire the row lock in time."
}

$nowaitWatch = [System.Diagnostics.Stopwatch]::StartNew()
$nowaitResult = Invoke-PsqlFile '05-session-b-nowait.sql'
$nowaitWatch.Stop()
$aResult = Receive-PsqlSession $sessionA

Write-Host ("Elapsed: {0:N2} s, exit code: {1}" -f $nowaitWatch.Elapsed.TotalSeconds, $nowaitResult.ExitCode)
Write-Host $nowaitResult.Output

# ---------------------------------------------------------------------------
# Restore the demo row
# ---------------------------------------------------------------------------
Write-Section "Restore"
$reset = Invoke-PsqlFile '01-reset-demo-row.sql'
Write-Host $reset.Output
$final = Invoke-PsqlFile '08-current-row.sql'
Write-Host ("Final row: {0}" -f $final.Output)

Write-Host ""
Write-Host "==> Locking demo complete."
