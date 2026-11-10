$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$helperPath = Join-Path $here 'helper.ps1'
if (-not (Test-Path -LiteralPath $helperPath)) { Write-Host "MISSING: $helperPath"; exit 2 }

# --- 1. Синтаксический разбор ---
$tokens = $null; $parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    Write-Host "SYNTAX: FAILED"
    $parseErrors | ForEach-Object { Write-Host "  $($_.Extent.StartLineNumber): $($_.Message)" }
    exit 1
}
Write-Host "SYNTAX: OK"

# --- 2. Загрузка helper ---
. $helperPath

# --- 3. Инфраструктура ---
$script:pass = 0
$script:fail = 0
$script:failedNames = @()

function Assert-Eq {
    param([string]$Label, $Actual, $Expected)
    $a = if ($null -eq $Actual) { '<null>' } else { [string]$Actual }
    $e = if ($null -eq $Expected) { '<null>' } else { [string]$Expected }
    if ($a -eq $e) { Write-Host "  PASS $Label"; $script:pass++ }
    else {
        Write-Host "  FAIL $Label"
        Write-Host "    expected: $e"
        Write-Host "    actual:   $a"
        $script:fail++; $script:failedNames += $Label
    }
}

function Assert-SetEq {
    param([string]$Label, [string[]]$Actual, [string[]]$Expected)
    $a = ((@($Actual) | Sort-Object) -join '|')
    $e = ((@($Expected) | Sort-Object) -join '|')
    if ($a -eq $e) { Write-Host "  PASS $Label"; $script:pass++ }
    else {
        Write-Host "  FAIL $Label"
        Write-Host "    expected: $e"
        Write-Host "    actual:   $a"
        $script:fail++; $script:failedNames += $Label
    }
}

function Invoke-Section {
    param([string]$Name, [scriptblock]$Script)
    Write-Host ""
    Write-Host "=== $Name ==="
    try {
        & $Script
    } catch {
        Write-Host "  SECTION EXCEPTION in '$Name': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
        $script:fail++
        $script:failedNames += "$Name [SECTION EXCEPTION]"
    }
}

# =========================================================
# Общий try — гарантирует печать итогового отчёта в finally
# =========================================================
try {

# =========================================================
# Секция M — Get-MandatoryChecks (M1–M8)
# =========================================================
Invoke-Section "Get-MandatoryChecks" {
    $m = Get-MandatoryChecks -PythonReady 'FAIL' -PortInitiallyFree 'PASS' -ServerStarted 'SKIPPED' -HttpReady 'SKIPPED' -StartedProcessNames @()
    Assert-SetEq 'M1 python fail' $m @('PythonReady','PortInitiallyFree')

    $m = Get-MandatoryChecks -PythonReady 'PASS' -PortInitiallyFree 'FAIL' -ServerStarted 'SKIPPED' -HttpReady 'SKIPPED' -StartedProcessNames @()
    Assert-SetEq 'M2 port busy' $m @('PythonReady','PortInitiallyFree')

    $m = Get-MandatoryChecks -PythonReady 'PASS' -PortInitiallyFree 'PASS' -ServerStarted 'PASS' -HttpReady 'PASS' -StartedProcessNames @('server')
    Assert-SetEq 'M3 server full success' $m @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop','Process_server_Stopped')

    $m = Get-MandatoryChecks -PythonReady 'PASS' -PortInitiallyFree 'PASS' -ServerStarted 'FAIL' -HttpReady 'SKIPPED' -StartedProcessNames @()
    Assert-SetEq 'M4 server start failed' $m @('PythonReady','PortInitiallyFree','ServerStarted','PortFreeAfterStop')

    $m = Get-MandatoryChecks -PythonReady 'PASS' -PortInitiallyFree 'PASS' -ServerStarted 'PASS' -HttpReady 'FAIL' -StartedProcessNames @('server')
    Assert-SetEq 'M5 http not ready' $m @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','PortFreeAfterStop','Process_server_Stopped')

    $m = Get-MandatoryChecks -PythonReady 'FAIL' -PortInitiallyFree 'PASS' -ServerStarted 'SKIPPED' -HttpReady 'SKIPPED' -StartedProcessNames @('find','ver')
    Assert-SetEq 'M6 python fail with processes' $m @('PythonReady','PortInitiallyFree','Process_find_Stopped','Process_ver_Stopped')

    $m = Get-MandatoryChecks -PythonReady 'PASS' -PortInitiallyFree 'PASS' -ServerStarted 'PASS' -HttpReady 'PASS' -StartedProcessNames @('find','ver','server')
    Assert-SetEq 'M7 full with all processes' $m @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop','Process_find_Stopped','Process_ver_Stopped','Process_server_Stopped')

    $m = Get-MandatoryChecks -PythonReady 'PASS' -PortInitiallyFree 'PASS' -ServerStarted 'PASS' -HttpReady 'PASS' -StartedProcessNames @()
    Assert-SetEq 'M8 caller bug - no processes in input' $m @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop')
}

# =========================================================
# Секция A — Test-CheckApplicability (A1–A4)
# =========================================================
Invoke-Section "Test-CheckApplicability" {
    $ctx = @{ PythonReady='FAIL'; PortInitiallyFree='PASS'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; StartedProcessNames=@() }
    Assert-Eq 'A1 python fail -> ServerStarted not applicable' (Test-CheckApplicability -CheckKey 'ServerStarted' -Context $ctx) $false

    $ctx = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='PASS'; StartedProcessNames=@('server') }
    Assert-Eq 'A2 full -> HttpRoutesOK applicable' (Test-CheckApplicability -CheckKey 'HttpRoutesOK' -Context $ctx) $true
    Assert-Eq 'A3 full -> Process_server_Stopped applicable' (Test-CheckApplicability -CheckKey 'Process_server_Stopped' -Context $ctx) $true
    Assert-Eq 'A4 full -> Process_ghost_Stopped not applicable' (Test-CheckApplicability -CheckKey 'Process_ghost_Stopped' -Context $ctx) $false
}

# =========================================================
# Секция C — Test-ContextConsistency (C1–C9)
# =========================================================
Invoke-Section "Test-ContextConsistency" {
    $ctx = @{ PythonReady='FAIL'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    Assert-Eq 'C1 python fail + server PASS -> contradiction' (Test-ContextConsistency -Context $ctx) 'CONTRADICTION'

    $ctx = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='FAIL'; HttpReady='PASS'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='PASS' }
    Assert-Eq 'C2 server FAIL + http PASS -> contradiction' (Test-ContextConsistency -Context $ctx) 'CONTRADICTION'

    $ctx = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='FAIL'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    Assert-Eq 'C3 http FAIL + routes PASS -> contradiction' (Test-ContextConsistency -Context $ctx) 'CONTRADICTION'

    $ctx = @{ PythonReady='PASS'; PortInitiallyFree='FAIL'; ServerStarted='PASS'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    Assert-Eq 'C4 port busy + server PASS -> contradiction' (Test-ContextConsistency -Context $ctx) 'CONTRADICTION'

    $ctx = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    Assert-Eq 'C5 launch necessary + server SKIPPED -> contradiction' (Test-ContextConsistency -Context $ctx) 'CONTRADICTION'

    $ctx = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='PASS'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    Assert-Eq 'C6 all pass -> consistent' (Test-ContextConsistency -Context $ctx) 'CONSISTENT'

    $ctx = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='FAIL'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    Assert-Eq 'C7 http fail + routes PASS -> contradiction' (Test-ContextConsistency -Context $ctx) 'CONTRADICTION'

    $ctx = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='FAIL'; HttpReady='SKIPPED'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    Assert-Eq 'C8 server fail + routes PASS -> contradiction' (Test-ContextConsistency -Context $ctx) 'CONTRADICTION'

    $ctx = @{ PythonReady='FAIL'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='PASS'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    Assert-Eq 'C9 python fail + server PASS -> contradiction' (Test-ContextConsistency -Context $ctx) 'CONTRADICTION'
}

# =========================================================
# Секция R — Get-OverallResult baselines (R1–R3)
# =========================================================
Invoke-Section "Get-OverallResult: baselines" {
    function New-ChecksPass {
        @{
            PythonReady='PASS'; PortInitiallyFree='PASS'
            ServerStarted='PASS'; HttpReady='PASS'
            HttpRoutesOK='PASS'; PortFreeAfterStop='PASS'
        }
    }
    $fullMandatory = @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop')

    Assert-Eq 'R1 all pass' (Get-OverallResult -Checks (New-ChecksPass) -SkippedReasons @{} -MandatoryChecks $fullMandatory -ReadErrors @() -CleanupErrors @()) 'PASS'

    $c = New-ChecksPass; $c['HttpRoutesOK'] = 'FAIL'
    Assert-Eq 'R2 http routes fail' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $fullMandatory -ReadErrors @() -CleanupErrors @()) 'FAIL'

    $c = New-ChecksPass; $c['HttpRoutesOK'] = 'SKIPPED'
    Assert-Eq 'R3 mandatory SKIPPED -> unknown' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $fullMandatory -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'
}

# =========================================================
# Секция F — FAIL priority and structure
# F1–F13, F13b, F15–F18, F10 (renamed), F10b (new)
# =========================================================
Invoke-Section "Get-OverallResult: FAIL priority and structure" {
    $fullMandatory = @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop')

    # F1
    $c = @{ PythonReady='FAIL'; PortInitiallyFree='UNKNOWN'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    $sk = @{ ServerStarted='x'; HttpReady='x'; HttpRoutesOK='x'; PortFreeAfterStop='x' }
    Assert-Eq 'F1 python FAIL + port UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'FAIL'

    # F2 — FAIL + invalid status
    $c = @{ PythonReady='FAIL'; PortInitiallyFree='BROKEN'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    $sk = @{ ServerStarted='x'; HttpReady='x'; HttpRoutesOK='x'; PortFreeAfterStop='x' }
    Assert-Eq 'F2 python FAIL + broken port -> FAIL (FAIL priority)' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'FAIL'

    # F3 — unknown key FAIL
    $c = @{
        PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='PASS'
        HttpRoutesOK='PASS'; PortFreeAfterStop='PASS'; UnexpectedCheck='FAIL'
    }
    Assert-Eq 'F3 unknown key FAIL -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $fullMandatory -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F4 — ServerStarted=FAIL + HttpReady=FAIL (contradiction, но FAIL wins)
    $c = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='FAIL'; HttpReady='FAIL'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='PASS' }
    $sk = @{ HttpRoutesOK='no http' }
    $mand = @('PythonReady','PortInitiallyFree','ServerStarted','PortFreeAfterStop')
    Assert-Eq 'F4 server FAIL + http FAIL -> FAIL (FAIL priority)' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks $mand -ReadErrors @() -CleanupErrors @()) 'FAIL'

    # F5 — null Checks
    Assert-Eq 'F5 null checks -> UNKNOWN' (Get-OverallResult -Checks $null -SkippedReasons @{} -MandatoryChecks @('PythonReady') -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F6 — empty Checks
    Assert-Eq 'F6 empty checks -> UNKNOWN' (Get-OverallResult -Checks @{} -SkippedReasons @{} -MandatoryChecks @('PythonReady') -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F7 — missing mandatory key
    $c = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; HttpReady='PASS'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    $mand = @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop')
    Assert-Eq 'F7 missing ServerStarted -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $mand -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F8 — port busy baseline
    $c = @{ PythonReady='PASS'; PortInitiallyFree='FAIL'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    $sk = @{ ServerStarted='no launch'; HttpReady='no server'; HttpRoutesOK='no http'; PortFreeAfterStop='no launch' }
    Assert-Eq 'F8 port busy -> FAIL from PortInitiallyFree' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'FAIL'

    # F8b — FAIL на неприменимой ServerStarted
    $c = @{ PythonReady='PASS'; PortInitiallyFree='UNKNOWN'; ServerStarted='FAIL'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    $sk = @{ HttpReady='no server'; HttpRoutesOK='no http'; PortFreeAfterStop='no launch' }
    Assert-Eq 'F8b FAIL on inapplicable ServerStarted -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F9 — mandatory SKIPPED with reason
    $c = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='SKIPPED'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    Assert-Eq 'F9 mandatory SKIPPED -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{HttpReady='reason'} -MandatoryChecks $fullMandatory -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F10 — mandatory SKIPPED (step 6: applicable+SKIPPED) -> UNKNOWN
    # [FIX-1] label reflects actual step
    $c = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='PASS'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='PASS' }
    Assert-Eq 'F10 mandatory SKIPPED (step 6) -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $fullMandatory -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F10b — inapplicable SKIPPED without reason (step 11) -> UNKNOWN [FIX-2]
    # HttpReady=UNKNOWN (not PASS) -> HttpRoutesOK inapplicable, not mandatory.
    # HttpRoutesOK=SKIPPED without SkippedReasons.
    # Normal flow: step 11 triggers before step 12.
    $c = @{
        PythonReady='PASS'; PortInitiallyFree='PASS'
        ServerStarted='PASS'; HttpReady='UNKNOWN'
        HttpRoutesOK='SKIPPED'; PortFreeAfterStop='PASS'
    }
    Assert-Eq 'F10b inapplicable SKIPPED no reason -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','PortFreeAfterStop') -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F11 — ReadErrors
    $c = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='PASS'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    Assert-Eq 'F11 read errors -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $fullMandatory -ReadErrors @('err') -CleanupErrors @()) 'UNKNOWN'

    # F12 — CleanupErrors
    Assert-Eq 'F12 cleanup errors -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $fullMandatory -ReadErrors @() -CleanupErrors @('dispose failed')) 'UNKNOWN'

    # F13 — partial mandatory + actual FAIL -> FAIL (FAIL priority)
    $cF13 = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='PASS'; HttpRoutesOK='FAIL'; PortFreeAfterStop='PASS' }
    $partial = @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','PortFreeAfterStop')
    Assert-Eq 'F13 partial mandatory + HttpRoutesOK=FAIL -> FAIL' (Get-OverallResult -Checks $cF13 -SkippedReasons @{} -MandatoryChecks $partial -ReadErrors @() -CleanupErrors @()) 'FAIL'

    # F13b — partial mandatory + all PASS -> UNKNOWN (completeness)
    $cAllPass = @{ PythonReady='PASS'; PortInitiallyFree='PASS'; ServerStarted='PASS'; HttpReady='PASS'; HttpRoutesOK='PASS'; PortFreeAfterStop='PASS' }
    Assert-Eq 'F13b partial mandatory + all PASS -> UNKNOWN' (Get-OverallResult -Checks $cAllPass -SkippedReasons @{} -MandatoryChecks $partial -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F15 — invalid status without FAIL
    $c = @{ PythonReady='PASS'; PortInitiallyFree='BROKEN'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    $sk = @{ ServerStarted='x'; HttpReady='x'; HttpRoutesOK='x'; PortFreeAfterStop='x' }
    Assert-Eq 'F15 invalid status alone -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # F16 — FAIL + skipped others with reasons
    $c = @{ PythonReady='FAIL'; PortInitiallyFree='PASS'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    $sk = @{ ServerStarted='x'; HttpReady='x'; HttpRoutesOK='x'; PortFreeAfterStop='x' }
    Assert-Eq 'F16 FAIL + skipped others -> FAIL' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'FAIL'

    # F17 — FAIL + UNKNOWN
    $c = @{ PythonReady='FAIL'; PortInitiallyFree='UNKNOWN'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    $sk = @{ ServerStarted='x'; HttpReady='x'; HttpRoutesOK='x'; PortFreeAfterStop='x' }
    Assert-Eq 'F17 FAIL + UNKNOWN -> FAIL' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'FAIL'

    # F18 — FAIL + invalid on other key
    $c = @{ PythonReady='FAIL'; PortInitiallyFree='BROKEN'; ServerStarted='SKIPPED'; HttpReady='SKIPPED'; HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED' }
    $sk = @{ ServerStarted='x'; HttpReady='x'; HttpRoutesOK='x'; PortFreeAfterStop='x' }
    Assert-Eq 'F18 FAIL + invalid elsewhere -> FAIL' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'FAIL'
}

# =========================================================
# Секция P — process registry (P1–P7, P4 renamed)
# =========================================================
Invoke-Section "Get-OverallResult: process registry" {
    function New-ChecksPass {
        @{
            PythonReady='PASS'; PortInitiallyFree='PASS'
            ServerStarted='PASS'; HttpReady='PASS'
            HttpRoutesOK='PASS'; PortFreeAfterStop='PASS'
        }
    }
    $fullMandatory = @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop')

    # P1 — complete registry
    $c = New-ChecksPass; $c['Process_find_Stopped']='PASS'; $c['Process_ver_Stopped']='PASS'
    $mand = $fullMandatory + @('Process_find_Stopped','Process_ver_Stopped')
    Assert-Eq 'P1 registry complete' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $mand -ReadErrors @() -CleanupErrors @() -StartedProcessNames @('find','ver')) 'PASS'

    # P2 — registry [find, ver], Checks has only Process_find_Stopped
    $c = New-ChecksPass
    $c['Process_find_Stopped'] = 'PASS'
    $mand = $fullMandatory + @('Process_find_Stopped')
    Assert-Eq 'P2 registry mismatch -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $mand -ReadErrors @() -CleanupErrors @() -StartedProcessNames @('find','ver')) 'UNKNOWN'

    # P3 — empty registry, ghost key in Checks
    $c = New-ChecksPass; $c['Process_ghost_Stopped']='PASS'
    $mand = $fullMandatory + @('Process_ghost_Stopped')
    Assert-Eq 'P3 ghost in checks + empty registry -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $mand -ReadErrors @() -CleanupErrors @() -StartedProcessNames @()) 'UNKNOWN'

    # P4 — no registry. Aggregator cannot verify Process_* completeness (documented).
    # [FIX-3] label reflects limitation
    $c = New-ChecksPass
    Assert-Eq 'P4 no registry -> PASS (completeness not verified — documented)' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $fullMandatory -ReadErrors @() -CleanupErrors @()) 'PASS'

    # P5 — ghost key with registry [find]
    $c = New-ChecksPass; $c['Process_find_Stopped']='PASS'; $c['Process_ghost_Stopped']='PASS'
    $mand = $fullMandatory + @('Process_find_Stopped','Process_ghost_Stopped')
    Assert-Eq 'P5 ghost key with registry [find] -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $mand -ReadErrors @() -CleanupErrors @() -StartedProcessNames @('find')) 'UNKNOWN'

    # P6 — duplicate process names in registry
    $c = New-ChecksPass; $c['Process_find_Stopped']='PASS'
    $mand = $fullMandatory + @('Process_find_Stopped')
    Assert-Eq 'P6 duplicate process name in registry -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $mand -ReadErrors @() -CleanupErrors @() -StartedProcessNames @('find','find')) 'UNKNOWN'

    # P7 — registered process has SKIPPED status
    $c = New-ChecksPass; $c['Process_find_Stopped']='SKIPPED'
    $mand = $fullMandatory + @('Process_find_Stopped')
    $sk = @{ Process_find_Stopped='reason' }
    Assert-Eq 'P7 registry process SKIPPED -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks $mand -ReadErrors @() -CleanupErrors @() -StartedProcessNames @('find')) 'UNKNOWN'
}

# =========================================================
# Секция D — duplicates in MandatoryChecks (D1–D2)
# =========================================================
Invoke-Section "Duplicates in MandatoryChecks" {
    function New-ChecksPass {
        @{
            PythonReady='PASS'; PortInitiallyFree='PASS'
            ServerStarted='PASS'; HttpReady='PASS'
            HttpRoutesOK='PASS'; PortFreeAfterStop='PASS'
        }
    }
    $fullMandatory = @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop')

    # D1 — duplicate in MandatoryChecks
    $mandWithDup = @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop','PythonReady')
    Assert-Eq 'D1 duplicate in MandatoryChecks -> UNKNOWN' (Get-OverallResult -Checks (New-ChecksPass) -SkippedReasons @{} -MandatoryChecks $mandWithDup -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # D2 — FAIL priority over duplicate Mandatory
    $c = New-ChecksPass; $c['PythonReady']='FAIL'
    Assert-Eq 'D2 FAIL priority over duplicate Mandatory' (Get-OverallResult -Checks $c -SkippedReasons @{} -MandatoryChecks $mandWithDup -ReadErrors @() -CleanupErrors @()) 'FAIL'
}

# =========================================================
# Секция X — inapplicable statuses (X1–X2)
# =========================================================
Invoke-Section "Inapplicable statuses" {
    $sk = @{ ServerStarted='no launch'; HttpRoutesOK='no http'; PortFreeAfterStop='no launch' }

    # X1 — inapplicable HttpReady=PASS
    $c = @{
        PythonReady='PASS'; PortInitiallyFree='UNKNOWN'
        ServerStarted='SKIPPED'; HttpReady='PASS'
        HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED'
    }
    Assert-Eq 'X1 inapplicable HttpReady=PASS -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'

    # X2 — inapplicable HttpReady=UNKNOWN
    $c = @{
        PythonReady='PASS'; PortInitiallyFree='UNKNOWN'
        ServerStarted='SKIPPED'; HttpReady='UNKNOWN'
        HttpRoutesOK='SKIPPED'; PortFreeAfterStop='SKIPPED'
    }
    Assert-Eq 'X2 inapplicable HttpReady=UNKNOWN -> UNKNOWN' (Get-OverallResult -Checks $c -SkippedReasons $sk -MandatoryChecks @('PythonReady','PortInitiallyFree') -ReadErrors @() -CleanupErrors @()) 'UNKNOWN'
}

# =========================================================
# Секция META1 — section exception
# =========================================================
Invoke-Section "META1 — section exception" {
    $passBefore  = $script:pass
    $failBefore  = $script:fail
    $namesBefore = @($script:failedNames)

    Invoke-Section "META1 inner throw" {
        throw "simulated exception for META1"
    }

    $delta   = $script:fail - $failBefore
    $hasName = $script:failedNames -contains 'META1 inner throw [SECTION EXCEPTION]'

    $script:pass        = $passBefore
    $script:fail        = $failBefore
    $script:failedNames = @($namesBefore)

    Assert-Eq 'META1 section exception increments FAIL by 1' $delta 1
    Assert-Eq 'META1 section name recorded in failedNames'   $hasName $true
}

# =========================================================
# Секция E — Invoke-ExternalCommand (E1–E5)
# =========================================================
Invoke-Section "Invoke-ExternalCommand — helper processes" {
    $cmd = "$env:ComSpec"
    if ([string]::IsNullOrWhiteSpace($cmd)) { $cmd = 'C:\Windows\System32\cmd.exe' }

    # E1 — exit 0
    $r = Invoke-ExternalCommand -FilePath $cmd -Arguments '/c exit 0' -Label 'E1' -TimeoutMs 3000
    Assert-Eq 'E1 ProcessStarted'  $r.ProcessStarted $true
    Assert-Eq 'E1 ProcessExited'   $r.ProcessExited  $true
    Assert-Eq 'E1 ExitCodeRead'    $r.ExitCodeRead   $true
    Assert-Eq 'E1 ExitCode=0'      $r.ExitCode       0
    Assert-Eq 'E1 FailureKind ok'  $r.FailureKind    'ok'
    Assert-Eq 'E1 ProcessStopped'  $r.ProcessStopped $true

    # E2 — exit 7 (nonzero exit)
    $r = Invoke-ExternalCommand -FilePath $cmd -Arguments '/c exit 7' -Label 'E2' -TimeoutMs 3000
    Assert-Eq 'E2 ExitCode=7'       $r.ExitCode       7
    Assert-Eq 'E2 FailureKind ok'   $r.FailureKind    'ok'
    Assert-Eq 'E2 ExitCodeRead'     $r.ExitCodeRead   $true
    Assert-Eq 'E2 ok != exit-code-0' ($r.FailureKind -eq 'ok' -and $r.ExitCodeRead -eq $true -and $r.ExitCode -ne 0) $true

    # E3 — stdout read
    $r = Invoke-ExternalCommand -FilePath $cmd -Arguments '/c echo test' -Label 'E3' -TimeoutMs 3000
    Assert-Eq 'E3 StdoutRead'      $r.StdoutRead     $true
    Assert-Eq 'E3 first line=test' ($r.StdoutLines | Select-Object -First 1) 'test'

    # E4 — nonexistent file
    $r = Invoke-ExternalCommand -FilePath '__no_such_file_.exe' -Arguments '' -Label 'E4' -TimeoutMs 2000
    Assert-Eq 'E4 ProcessStarted false'        $r.ProcessStarted $false
    Assert-Eq 'E4 FailureKind start_not_found' $r.FailureKind    'start_not_found'

    # E5 — timeout with confirmed stop
    $psExe = $null
    try { $psExe = (Get-Process -Id $PID -ErrorAction Stop).Path } catch { }
    if (-not $psExe -or -not (Test-Path -LiteralPath $psExe)) {
        foreach ($name in @('pwsh.exe', 'powershell.exe')) {
            $cand = Join-Path $PSHOME $name
            if (Test-Path -LiteralPath $cand) { $psExe = $cand; break }
        }
    }
    if (-not $psExe) {
        foreach ($name in @('pwsh.exe', 'powershell.exe')) {
            $found = Get-Command $name -ErrorAction SilentlyContinue
            if ($found) { $psExe = $found.Source; break }
        }
    }

    if (-not $psExe) {
        Write-Host "  FAIL E5: no PowerShell host executable found" -ForegroundColor Red
        $script:fail++; $script:failedNames += "E5 [no PS host]"
    } else {
        Write-Host "  (E5 using: $psExe)" -ForegroundColor DarkGray
        $r = Invoke-ExternalCommand -FilePath $psExe -Arguments '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' -Label 'E5' -TimeoutMs 500
        Assert-Eq 'E5 ProcessStarted'                $r.ProcessStarted $true
        Assert-Eq 'E5 FailureKind=timeout'           $r.FailureKind    'timeout'
        Assert-Eq 'E5 ProcessStopped'                $r.ProcessStopped $true
        Assert-Eq 'E5 ExitCodeRead=false on timeout' $r.ExitCodeRead   $false
    }
}

}   # конец общего try {

finally {
    Write-Host ""
    Write-Host "========================================"
    Write-Host "PASS: $script:pass"
    Write-Host "FAIL: $script:fail"
    if ($script:failedNames.Count -gt 0) {
        Write-Host "Failed:"
        $script:failedNames | ForEach-Object { Write-Host "  - $_" }
    }
    Write-Host "========================================"
}

if ($script:fail -gt 0) { exit 1 }
exit 0