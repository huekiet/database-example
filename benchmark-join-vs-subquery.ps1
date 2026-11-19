#!/usr/bin/env powershell
#
# benchmark-join-vs-subquery.ps1
# Focused JOIN vs subquery benchmark against the pg-benchmark container.
#
# Runs every query 1 warm-up + N measured times, twice:
#   1. WITHOUT the benchmark indexes (only PK/unique indexes)
#   2. WITH the indexes from init/03-indexes.sql
# and reports the median Execution Time from EXPLAIN ANALYZE.
#
# Usage (Windows PowerShell 5.1+):
#   powershell -ExecutionPolicy Bypass -File .\benchmark-join-vs-subquery.ps1
#   powershell -ExecutionPolicy Bypass -File .\benchmark-join-vs-subquery.ps1 -Runs 3 -TimeoutSeconds 60

param(
    [int]$Runs = 5,
    [int]$Warmup = 1,
    [int]$TimeoutSeconds = 30,
    [string]$Container = 'pg-benchmark',
    [string]$Db = 'benchmark',
    [string]$User = 'benchmark',
    [string]$QueryDir = '/exercises/02-join-vs-subquery/queries'
)

# Native tools (docker/psql) write NOTICEs and timeout errors to stderr. Keep the
# shell from turning those into terminating errors; exit codes are checked explicitly.
$ErrorActionPreference = 'Continue'

$queries = [ordered]@{
    '06a-join-filtered-aggregation.sql'      = '06a JOIN       filtered slice (21 users)'
    '06b-subquery-filtered-aggregation.sql'  = '06b SUBQUERY   filtered slice (21 users)'
    '07a-join-global-aggregation.sql'        = '07a JOIN       delivered orders, top 20'
    '07b-subquery-global-aggregation.sql'    = '07b SUBQUERY   delivered orders, top 20'
    '08a-join-all-users-aggregation.sql'     = '08a JOIN       100k users, no filter'
    '08b-subquery-all-users-aggregation.sql' = '08b SUBQUERY   100k users, no filter'
    '09a-join-existence.sql'                 = '09a JOIN+DISTINCT  laptop buyers'
    '09b-in-existence.sql'                   = '09b IN (subquery)  laptop buyers'
    '09c-exists-existence.sql'               = '09c EXISTS         laptop buyers'
}

$resultsDir = Join-Path $PSScriptRoot 'benchmark-results'
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

function Invoke-Psql([string[]]$PsqlArgs) {
    # Capture stderr through a temp file: PowerShell 5.1 turns native stderr into
    # error records that become very noisy under `2>&1`.
    $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ("psql-" + [guid]::NewGuid().ToString('N') + ".err")
    try {
        $stdout = & docker exec -i $Container psql -U $User -d $Db -X -q -t -A -v ON_ERROR_STOP=1 @PsqlArgs 2> $errFile
        $exitCode = $LASTEXITCODE
        $stderr = if (Test-Path $errFile) { Get-Content -Raw -Path $errFile } else { '' }
    }
    finally {
        Remove-Item -Path $errFile -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Output   = (($stdout | Out-String) + $stderr)
        ExitCode = $exitCode
    }
}

function Get-Median([double[]]$Values) {
    if ($Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $mid = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$mid] }
    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2
}

function Run-QuerySet([string]$State) {
    Write-Host ""
    Write-Host "=== State: $State ===" -ForegroundColor Cyan

    # Interleave the queries round-robin so background drift (autovacuum,
    # checkpoints, host load) affects every query similarly.
    $samples = [ordered]@{}
    foreach ($file in $queries.Keys) {
        $samples[$file] = [pscustomobject]@{
            Times    = @()
            Plan     = ''
            Timeouts = 0
            Done     = $false
        }
    }

    for ($round = 0; $round -lt ($Warmup + $Runs); $round++) {
        foreach ($file in $queries.Keys) {
            $sample = $samples[$file]
            if ($sample.Done) { continue }

            $phase = if ($round -lt $Warmup) { 'warm-up' } else { "run $round/$($Warmup + $Runs - 1)" }
            Write-Host "==> [$State] $phase  $($queries[$file])"

            $res = Invoke-Psql @(
                '-c', "SET statement_timeout = '$($TimeoutSeconds * 1000)ms'",
                '-c', 'SET jit = off',
                '-f', "$QueryDir/$file"
            )

            if ($res.ExitCode -ne 0) {
                # psql wraps long messages, so normalise whitespace before matching.
                $flat = $res.Output -replace '\s+', ' '
                if ($flat -match 'canceling statement due to statement timeout') {
                    # No point repeating a query that already exceeded the timeout.
                    $sample.Timeouts++
                    $sample.Done = $true
                    continue
                }
                Write-Host $res.Output -ForegroundColor DarkYellow
                continue
            }

            if ($res.Output -match 'Execution Time:\s*([0-9.]+)\s*ms') {
                $ms = [double]$matches[1]
                # Drop warm-up runs so cold-cache effects do not skew the median.
                if ($round -ge $Warmup) { $sample.Times += $ms }
                $sample.Plan = $res.Output
            }
        }
    }

    $rows = foreach ($file in $queries.Keys) {
        $sample = $samples[$file]
        if ($sample.Plan) {
            $sample.Plan -replace "`r", '' | Set-Content -Path (Join-Path $resultsDir "plan-$State-$file.txt")
        }

        [pscustomobject]@{
            State    = $State
            File     = $file
            Label    = $queries[$file]
            Runs     = $sample.Times
            MedianMs = Get-Median $sample.Times
            MinMs    = if ($sample.Times.Count) { ($sample.Times | Measure-Object -Minimum).Minimum } else { $null }
            MaxMs    = if ($sample.Times.Count) { ($sample.Times | Measure-Object -Maximum).Maximum } else { $null }
            Timeouts = $sample.Timeouts
        }
    }

    Write-Host ""
    Write-Host ("{0,-45} {1,12} {2,12} {3,12} {4,12}" -f 'QUERY', 'MEDIAN (ms)', 'MIN (ms)', 'MAX (ms)', 'TIMEOUTS')
    Write-Host ('-' * 96)
    foreach ($row in $rows) {
        $median = if ($null -ne $row.MedianMs) { '{0:N3}' -f $row.MedianMs } else { 'n/a' }
        $min = if ($null -ne $row.MinMs) { '{0:N3}' -f $row.MinMs } else { 'n/a' }
        $max = if ($null -ne $row.MaxMs) { '{0:N3}' -f $row.MaxMs } else { 'n/a' }
        Write-Host ("{0,-45} {1,12} {2,12} {3,12} {4,12}" -f $row.Label, $median, $min, $max, $row.Timeouts)
    }

    return $rows
}

# Reuse the repo's index definitions.
$indexScript = '/docker-entrypoint-initdb.d/03-indexes.sql'
$dropScript = '/docker-entrypoint-initdb.d/04-drop-indexes.sql'

Write-Host "==> Waiting for PostgreSQL..."
for ($i = 0; $i -lt 60; $i++) {
    & docker exec $Container pg_isready -U $User -d $Db *> $null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 2
}

Write-Host "==> Row counts:"
& docker exec -i $Container psql -U $User -d $Db -X -q -t -A -c "SELECT 'users=' || COUNT(*) FROM users UNION ALL SELECT 'orders=' || COUNT(*) FROM orders;"

$all = @()

# Silence harmless NOTICEs (e.g. `DROP INDEX IF EXISTS ... skipping`) so they do
# not clutter the benchmark output.
$quiet = @('-c', 'SET client_min_messages = warning')

# --- Pass 1: no secondary indexes ---
Invoke-Psql ($quiet + @('-f', $dropScript)) | Out-Null
$all += Run-QuerySet 'no-index'

# --- Pass 2: with indexes ---
Invoke-Psql ($quiet + @('-f', $indexScript)) | Out-Null
$all += Run-QuerySet 'with-index'

# --- Restore the repository's default state (no benchmark indexes) ---
Invoke-Psql ($quiet + @('-f', $dropScript)) | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $resultsDir "join-vs-subquery-$stamp.json"
$all | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath
Write-Host ""
Write-Host "==> Raw results saved to $jsonPath"
