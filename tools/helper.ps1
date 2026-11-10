# NetLab UZ — Stage C isolated helper.
# Никаких обращений к проекту, uv, Python, netlab.
# Запускает только процессы, явно перечисленные в тесте.

$ErrorActionPreference = 'Stop'

# =========================================================
# Применимость одной проверки
# =========================================================
function Test-CheckApplicability {
    param(
        [Parameter(Mandatory)] [string]    $CheckKey,
        [Parameter(Mandatory)] [hashtable] $Context
    )
    $py    = [string]$Context['PythonReady']
    $pif   = [string]$Context['PortInitiallyFree']
    $ss    = [string]$Context['ServerStarted']
    $hr    = [string]$Context['HttpReady']
    $procs = @($Context['StartedProcessNames'])
    $launchNecessary = ($py -eq 'PASS' -and $pif -eq 'PASS')

    switch ($CheckKey) {
        'PythonReady'       { return $true }
        'PortInitiallyFree' { return $true }
        'ServerStarted'     { return $launchNecessary }
        'HttpReady'         { return ($ss -eq 'PASS') }
        'HttpRoutesOK'      { return ($hr -eq 'PASS') }
        'PortFreeAfterStop' { return $launchNecessary }
        default {
            if ($CheckKey -match '^Process_(?<name>.+)_Stopped$') {
                return ($procs -contains $Matches['name'])
            }
            return $false
        }
    }
}

# =========================================================
# Полный список обязательных проверок
# =========================================================
function Get-MandatoryChecks {
    param(
        [string]   $PythonReady,
        [string]   $PortInitiallyFree,
        [string]   $ServerStarted,
        [string]   $HttpReady,
        [string[]] $StartedProcessNames
    )
    $procs = if ($null -eq $StartedProcessNames) { @() } else { @($StartedProcessNames) }
    $context = @{
        PythonReady         = [string]$PythonReady
        PortInitiallyFree   = [string]$PortInitiallyFree
        ServerStarted       = [string]$ServerStarted
        HttpReady           = [string]$HttpReady
        StartedProcessNames = $procs
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($k in @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop')) {
        if (Test-CheckApplicability -CheckKey $k -Context $context) { $out.Add($k) }
    }
    foreach ($p in $procs) { $out.Add("Process_${p}_Stopped") }
    return ,$out.ToArray()
}

# =========================================================
# Согласованность контекста — отдельная проверка
# ---------------------------------------------------------
# Используется только в тестах C1–C9 для явной проверки правил контекста.
# Get-OverallResult реализует свою inline-логику (с приоритетом FAIL).
# Если правила изменятся, обе реализации должны быть обновлены согласованно.
# =========================================================
function Test-ContextConsistency {
    param([Parameter(Mandatory)] [hashtable] $Context)
    $py  = [string]$Context['PythonReady']
    $pif = [string]$Context['PortInitiallyFree']
    $ss  = [string]$Context['ServerStarted']
    $hr  = [string]$Context['HttpReady']
    $hro = [string]$Context['HttpRoutesOK']
    $pfs = [string]$Context['PortFreeAfterStop']

    $launchNecessary = ($py -eq 'PASS' -and $pif -eq 'PASS')

    if (-not $launchNecessary) {
        if ($ss  -in @('PASS','FAIL')) { return 'CONTRADICTION' }
        if ($hr  -in @('PASS','FAIL')) { return 'CONTRADICTION' }
        if ($hro -in @('PASS','FAIL')) { return 'CONTRADICTION' }
        if ($pfs -in @('PASS','FAIL')) { return 'CONTRADICTION' }
    } else {
        if ($ss  -eq 'SKIPPED') { return 'CONTRADICTION' }
        if ($pfs -eq 'SKIPPED') { return 'CONTRADICTION' }
    }
    if ($ss -ne 'PASS') {
        if ($hr -in @('PASS','FAIL')) { return 'CONTRADICTION' }
    }
    if ($hr -ne 'PASS') {
        if ($hro -in @('PASS','FAIL')) { return 'CONTRADICTION' }
    }
    return 'CONSISTENT'
}

# =========================================================
# Агрегация статусов
# ---------------------------------------------------------
# Порядок проверок (контракт приоритетов):
#   1. Нормализация аргументов
#   2. Проверка базовой структуры
#   3. Проверка неизвестных ключей
#   4. Проверка согласованности реестра процессов (если передан)
#   5. Проверка подтверждённого FAIL применимой проверки
#   6. Проверка противоречий применимости/статусов
#   7. Проверка допустимости статусов
#   8. Проверка полноты MandatoryChecks (с детекцией дубликатов)
#   9. Проверка наличия обязательных ключей
#  10. Проверка обязательных SKIPPED
#  11. Проверка причин для необязательных SKIPPED
#  12. Проверка наличия UNKNOWN
#  13. Проверка ошибок чтения и очистки
#  14. PASS только при полном успехе
# =========================================================
function Get-OverallResult {
    param(
        $Checks,
        $SkippedReasons,
        $MandatoryChecks,
        $ReadErrors,
        $CleanupErrors,
        [string[]] $StartedProcessNames = $null
    )
    $FIXED = @('PythonReady','PortInitiallyFree','ServerStarted','HttpReady','HttpRoutesOK','PortFreeAfterStop')
    $VALID = @('PASS','FAIL','UNKNOWN','SKIPPED')

    # 1. Нормализация
    if ($null -eq $SkippedReasons)  { $SkippedReasons  = @{} }
    if ($null -eq $MandatoryChecks) { $MandatoryChecks = @() }
    if ($null -eq $ReadErrors)      { $ReadErrors      = @() }
    if ($null -eq $CleanupErrors)   { $CleanupErrors   = @() }

    # 2. Базовая структура
    if (-not ($Checks -is [hashtable]) -or $Checks.Count -eq 0) { return 'UNKNOWN' }
    if (-not ($SkippedReasons -is [hashtable]))                 { return 'UNKNOWN' }
    if (@($MandatoryChecks).Count -eq 0)                        { return 'UNKNOWN' }

    # 3. Неизвестные ключи
    foreach ($k in $Checks.Keys) {
        if ($FIXED -notcontains $k -and $k -notmatch '^Process_.+_Stopped$') {
            Write-Verbose "Get-OverallResult: unknown key '$k'"
            return 'UNKNOWN'
        }
    }

    # 4. Согласованность реестра процессов (до FAIL-приоритета)
    if ($null -ne $StartedProcessNames) {
        $regs = @($StartedProcessNames)
        $regUnique = @($regs | Sort-Object -Unique)
        if ($regUnique.Count -ne $regs.Count) {
            Write-Verbose "Get-OverallResult: duplicate process names in registry"
            return 'UNKNOWN'
        }
        foreach ($n in $regs) {
            $k = "Process_${n}_Stopped"
            if (-not $Checks.ContainsKey($k)) {
                Write-Verbose "Get-OverallResult: registered process '$n' has no Process_${n}_Stopped key"
                return 'UNKNOWN'
            }
            $v = $Checks[$k]
            if ($null -eq $v -or -not ($v -is [string]) -or $VALID -notcontains $v) {
                Write-Verbose "Get-OverallResult: registered process '$n' has invalid status"
                return 'UNKNOWN'
            }
            if ($v -eq 'SKIPPED') {
                Write-Verbose "Get-OverallResult: registered process '$n' is SKIPPED"
                return 'UNKNOWN'
            }
        }
        foreach ($k in $Checks.Keys) {
            if ($k -match '^Process_(?<n>.+)_Stopped$') {
                if ($Matches['n'] -notin $regs) {
                    Write-Verbose "Get-OverallResult: ghost process key '$k' not in registry"
                    return 'UNKNOWN'
                }
            }
        }
    }

    # Контекст для применимости
    $context = @{
        PythonReady         = if ($Checks.ContainsKey('PythonReady'))       { [string]$Checks['PythonReady'] }       else { '' }
        PortInitiallyFree   = if ($Checks.ContainsKey('PortInitiallyFree')) { [string]$Checks['PortInitiallyFree'] } else { '' }
        ServerStarted       = if ($Checks.ContainsKey('ServerStarted'))     { [string]$Checks['ServerStarted'] }     else { '' }
        HttpReady           = if ($Checks.ContainsKey('HttpReady'))         { [string]$Checks['HttpReady'] }         else { '' }
        StartedProcessNames = if ($null -eq $StartedProcessNames) { @() } else { @($StartedProcessNames) }
    }

    # 5. Подтверждённый FAIL применимой проверки
    foreach ($k in $Checks.Keys) {
        $v = $Checks[$k]
        if (-not ($v -is [string]) -or $v -ne 'FAIL') { continue }
        $applicable = if ($FIXED -contains $k) {
            Test-CheckApplicability -CheckKey $k -Context $context
        } else {
            $MandatoryChecks -contains $k
        }
        if ($applicable) {
            Write-Verbose "Get-OverallResult: confirmed FAIL from applicable '$k'"
            return 'FAIL'
        }
    }

    # 6. Противоречия применимости/статусов
    foreach ($k in $Checks.Keys) {
        $v = $Checks[$k]
        if (-not ($v -is [string])) { continue }
        $applicable = if ($FIXED -contains $k) {
            Test-CheckApplicability -CheckKey $k -Context $context
        } else {
            $MandatoryChecks -contains $k
        }
        if ($applicable -and $v -eq 'SKIPPED') {
            Write-Verbose "Get-OverallResult: contradiction — applicable '$k' is SKIPPED"
            return 'UNKNOWN'
        }
        if ((-not $applicable) -and ($v -in @('PASS','FAIL','UNKNOWN'))) {
            Write-Verbose "Get-OverallResult: contradiction — inapplicable '$k' has value $v"
            return 'UNKNOWN'
        }
    }

    # 7. Допустимость статусов
    foreach ($k in $Checks.Keys) {
        $v = $Checks[$k]
        if ($null -eq $v) {
            Write-Verbose "Get-OverallResult: null status at '$k'"
            return 'UNKNOWN'
        }
        if (-not ($v -is [string])) {
            Write-Verbose "Get-OverallResult: non-string status at '$k'"
            return 'UNKNOWN'
        }
        if ($VALID -notcontains $v) {
            Write-Verbose "Get-OverallResult: invalid status '$v' at '$k'"
            return 'UNKNOWN'
        }
    }

    # 8. Полнота MandatoryChecks (с явной детекцией дубликатов)
    $mandDupes = @($MandatoryChecks | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($mandDupes.Count -gt 0) {
        Write-Verbose "Get-OverallResult: duplicate entries in MandatoryChecks: $($mandDupes -join ',')"
        return 'UNKNOWN'
    }

    $expectedMandatory = @(Get-MandatoryChecks `
        -PythonReady       ([string]$context['PythonReady']) `
        -PortInitiallyFree ([string]$context['PortInitiallyFree']) `
        -ServerStarted     ([string]$context['ServerStarted']) `
        -HttpReady         ([string]$context['HttpReady']) `
        -StartedProcessNames $StartedProcessNames)

    $expectedFiltered = if ($null -eq $StartedProcessNames) {
        @($expectedMandatory | Where-Object { $_ -notmatch '^Process_.+_Stopped$' })
    } else { @($expectedMandatory) }

    $actualFiltered = if ($null -eq $StartedProcessNames) {
        @($MandatoryChecks | Where-Object { $_ -notmatch '^Process_.+_Stopped$' })
    } else { @($MandatoryChecks) }

    $expDupes = @($expectedFiltered | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($expDupes.Count -gt 0) {
        Write-Verbose "Get-OverallResult: unexpected duplicates in expected mandatory (internal error)"
        return 'UNKNOWN'
    }
    $actDupes = @($actualFiltered | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($actDupes.Count -gt 0) {
        Write-Verbose "Get-OverallResult: unexpected duplicates in actual mandatory"
        return 'UNKNOWN'
    }

    $expSorted = @($expectedFiltered | Sort-Object)
    $actSorted = @($actualFiltered | Sort-Object)
    if ($expSorted.Count -ne $actSorted.Count) {
        Write-Verbose "Get-OverallResult: Mandatory count mismatch — expected $($expSorted.Count), actual $($actSorted.Count)"
        return 'UNKNOWN'
    }
    for ($i = 0; $i -lt $expSorted.Count; $i++) {
        if ($expSorted[$i] -ne $actSorted[$i]) {
            Write-Verbose "Get-OverallResult: Mandatory mismatch — expected [$($expSorted -join ',')], actual [$($actSorted -join ',')]"
            return 'UNKNOWN'
        }
    }

    # 9. Наличие обязательных ключей
    foreach ($m in $MandatoryChecks) {
        if (-not $Checks.ContainsKey($m)) {
            Write-Verbose "Get-OverallResult: missing mandatory '$m'"
            return 'UNKNOWN'
        }
    }

    # 10. Обязательные SKIPPED
    foreach ($m in $MandatoryChecks) {
        if ($Checks[$m] -eq 'SKIPPED') {
            Write-Verbose "Get-OverallResult: mandatory '$m' is SKIPPED"
            return 'UNKNOWN'
        }
    }

    # 11. Причины для SKIPPED
    foreach ($k in $Checks.Keys) {
        if ($Checks[$k] -eq 'SKIPPED') {
            if (-not $SkippedReasons.ContainsKey($k) -or
                [string]::IsNullOrWhiteSpace([string]$SkippedReasons[$k])) {
                Write-Verbose "Get-OverallResult: SKIPPED '$k' without valid reason"
                return 'UNKNOWN'
            }
        }
    }

    # 12. UNKNOWN в Checks
    foreach ($k in $Checks.Keys) {
        if ($Checks[$k] -eq 'UNKNOWN') {
            Write-Verbose "Get-OverallResult: UNKNOWN at '$k'"
            return 'UNKNOWN'
        }
    }

    # 13. Ошибки чтения/очистки
    if (@($ReadErrors).Count    -gt 0) { Write-Verbose 'Get-OverallResult: ReadErrors';    return 'UNKNOWN' }
    if (@($CleanupErrors).Count -gt 0) { Write-Verbose 'Get-OverallResult: CleanupErrors'; return 'UNKNOWN' }

    return 'PASS'
}

# =========================================================
# Invoke-ExternalCommand
# ---------------------------------------------------------
# Контракт полей результата:
#   ProcessStarted   true iff Process.Start() вернул объект.
#   ProcessExited    true iff WaitForExit(TimeoutMs) или WaitForExit(2000) после Kill подтвердили выход.
#   ProcessStopped   финальная проверка HasExited в finally: $true/$false/$null.
#   ExitCodeRead     true iff $p.ExitCode прочитан без исключения.
#   ExitCode         $null if ExitCodeRead=false, иначе — код возврата.
#   FailureKind      'ok'|'timeout'|'start_not_found'|'start_access_denied'|'start_other'|'unknown'.
#                    'ok' = запуск + завершение в срок без exception.
#                    'ok' НЕ означает ExitCode=0 — проверяй ExitCodeRead и ExitCode отдельно.
#   StdoutRead       true iff ReadToEndAsync завершился без faulted.
#   StderrRead       то же для stderr.
#   ReadErrors       ошибки чтения потоков.
#   CleanupErrors    ошибки Kill/WaitForExit/HasExited/Dispose (диагностика).
# =========================================================
function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Arguments,
        [Parameter(Mandatory)] [string] $Label,
        [int] $TimeoutMs = 5000
    )
    $r = [pscustomobject]@{
        ProcessStarted   = $false
        ProcessExited    = $false
        FailureKind      = 'unknown'
        ExitCodeRead     = $false
        ExitCode         = $null
        StdoutRead       = $false
        StderrRead       = $false
        StdoutLines      = @()
        StderrLines      = @()
        ReadErrors       = @()
        CleanupErrors    = @()
        ProcessStopped   = $null
        ExceptionMessage = $null
    }
    $p = $null
    $failureKind = 'unknown'

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $FilePath
        $psi.Arguments              = $Arguments
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true

        try {
            $p = [System.Diagnostics.Process]::Start($psi)
        } catch [System.ComponentModel.Win32Exception] {
            $code = $_.Exception.NativeErrorCode
            if ($code -eq 2 -or $code -eq 3) { $failureKind = 'start_not_found' }
            elseif ($code -eq 5)             { $failureKind = 'start_access_denied' }
            else                             { $failureKind = 'start_other' }
            $r.ExceptionMessage = "${Label}: Win32 $code - $($_.Exception.Message)"
            return $r
        } catch {
            $failureKind = 'start_other'
            $r.ExceptionMessage = "${Label}: $($_.Exception.Message)"
            return $r
        }

        if (-not $p) {
            $failureKind = 'start_other'
            $r.ExceptionMessage = "${Label}: Process.Start returned null"
            return $r
        }
        $r.ProcessStarted = $true

        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        $exitedInTime = $p.WaitForExit($TimeoutMs)
        if ($exitedInTime) {
            $r.ProcessExited = $true
            $failureKind = 'ok'
            try { $r.ExitCode = $p.ExitCode; $r.ExitCodeRead = $true } catch {
                $r.CleanupErrors += "${Label}: ExitCode: $($_.Exception.Message)"
            }
        } else {
            $failureKind = 'timeout'
            try { $p.Kill() } catch {
                $r.CleanupErrors += "${Label}: Kill(timeout): $($_.Exception.Message)"
            }
            try {
                if ($p.WaitForExit(2000)) { $r.ProcessExited = $true }
                else { $r.CleanupErrors += "${Label}: WaitForExit(2000) not confirmed" }
            } catch {
                $r.CleanupErrors += "${Label}: WaitForExit(2000): $($_.Exception.Message)"
            }
        }

        try { $outDone = $outTask.Wait(2000) } catch {
            $outDone = $false; $r.ReadErrors += "${Label}: stdout Wait: $($_.Exception.Message)"
        }
        try { $errDone = $errTask.Wait(2000) } catch {
            $errDone = $false; $r.ReadErrors += "${Label}: stderr Wait: $($_.Exception.Message)"
        }

        if ($outDone -and -not $outTask.IsFaulted) {
            $r.StdoutLines = @(($outTask.Result) -split "\r?\n" | Where-Object { $_ -ne '' })
            $r.StdoutRead  = $true
        } else {
            $r.ReadErrors += "${Label}: stdout not read"
        }

        if ($errDone -and -not $errTask.IsFaulted) {
            $r.StderrLines = @(($errTask.Result) -split "\r?\n" | Where-Object { $_ -ne '' })
            $r.StderrRead  = $true
        } else {
            $r.ReadErrors += "${Label}: stderr not read"
        }
    } catch {
        if ($failureKind -eq 'unknown') { $failureKind = 'start_other' }
        $r.ExceptionMessage = "${Label}: $($_.Exception.Message)"
    } finally {
        if ($p) {
            try {
                if (-not $p.HasExited) {
                    try { $p.Kill() } catch {
                        $r.CleanupErrors += "${Label}: Kill(finally): $($_.Exception.Message)"
                    }
                }
            } catch {
                $r.CleanupErrors += "${Label}: HasExited(finally): $($_.Exception.Message)"
            }
            try {
                if ($p.HasExited) { $r.ProcessStopped = $true }
                else              { $r.ProcessStopped = $false }
            } catch {
                $r.ProcessStopped = $null
                $r.CleanupErrors += "${Label}: HasExited(ProcessStopped): $($_.Exception.Message)"
            }
            try { $p.Dispose() } catch {
                $r.CleanupErrors += "${Label}: Dispose: $($_.Exception.Message)"
            }
        }
        $r.FailureKind = $failureKind
    }
    return $r
}