# helper.ps1
# NetLab UZ — Stage C helper functions
# Reconstructed implementation based on the available Stage C requirements.
# This is NOT guaranteed to be byte-for-byte identical to the earlier file.

Set-StrictMode -Version 2.0

function Assert-Eq {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected
    )

    $actualText = if ($null -eq $Actual) { '<null>' } else { [string]$Actual }
    $expectedText = if ($null -eq $Expected) { '<null>' } else { [string]$Expected }

    if ($null -eq $Actual -and $null -eq $Expected) {
        $script:pass++
        Write-Host "  PASS $Name" -ForegroundColor Green
        return
    }

    if ($null -ne $Actual -and $null -ne $Expected -and
        ([string]$Actual -ceq [string]$Expected)) {
        $script:pass++
        Write-Host "  PASS $Name" -ForegroundColor Green
    }
    else {
        $script:fail++
        $script:failedNames += $Name
        Write-Host "  FAIL $Name (expected=$expectedText; actual=$actualText)" -ForegroundColor Red
    }
}

function Invoke-Section {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )

    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    try {
        & $Script
    }
    catch {
        $message = $_.Exception.Message
        Write-Host "  SECTION EXCEPTION in '$Name': $message" -ForegroundColor Red
        if ($_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        }
        $script:fail++
        $script:failedNames += "$Name [SECTION EXCEPTION]"
    }
}

function Get-OverallResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Checks,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$SkippedReasons,
        [Parameter(Mandatory = $true)][string[]]$MandatoryChecks,
        [Parameter(Mandatory = $true)][object[]]$ReadErrors,
        [Parameter(Mandatory = $true)][object[]]$CleanupErrors,
        [AllowNull()][string[]]$StartedProcessNames = $null
    )

    # Invalid/unknown status values must not be interpreted as PASS.
    $validStatuses = @('PASS', 'FAIL', 'UNKNOWN', 'SKIPPED')

    foreach ($key in $Checks.Keys) {
        $value = [string]$Checks[$key]
        if ($value -notin $validStatuses) { return 'UNKNOWN' }
    }

    # Any confirmed failure takes priority.
    foreach ($key in $Checks.Keys) {
        if ([string]$Checks[$key] -eq 'FAIL') { return 'FAIL' }
    }
    if (@($ReadErrors).Count -gt 0 -or @($CleanupErrors).Count -gt 0) {
        return 'FAIL'
    }

    # Mandatory checks must exist and pass.
    foreach ($key in $MandatoryChecks) {
        if (-not $Checks.Contains($key)) { return 'UNKNOWN' }
        if ([string]$Checks[$key] -ne 'PASS') { return 'UNKNOWN' }
    }

    # If a process registry is supplied, check consistency between the
    # expected process names and Process_<name>_Stopped check keys.
    if ($null -ne $StartedProcessNames) {
        $regs = @($StartedProcessNames | ForEach-Object { [string]$_ })
        $regUnique = @($regs | Sort-Object -Unique)
        if ($regUnique.Count -ne $regs.Count) { return 'UNKNOWN' }

        foreach ($name in $regs) {
            $key = "Process_${name}_Stopped"
            if (-not $Checks.Contains($key)) { return 'UNKNOWN' }
            if ([string]$Checks[$key] -ne 'PASS') { return 'UNKNOWN' }
        }

        foreach ($key in $Checks.Keys) {
            if ([string]$key -match '^Process_(.+)_Stopped$') {
                $name = $Matches[1]
                if ($name -notin $regs) { return 'UNKNOWN' }
            }
        }
    }

    # Explicitly skipped checks do not count as a successful full result.
    foreach ($key in $MandatoryChecks) {
        if ($SkippedReasons.Contains($key)) { return 'UNKNOWN' }
    }
    foreach ($key in $Checks.Keys) {
        if ([string]$Checks[$key] -eq 'UNKNOWN' -or
            [string]$Checks[$key] -eq 'SKIPPED') {
            return 'UNKNOWN'
        }
    }

    return 'PASS'
}

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Arguments = '',
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int]$TimeoutMs
    )

    $result = [ordered]@{
        Label          = $Label
        ProcessStarted = $false
        FailureKind    = 'start_other'
        ExitCode       = $null
        ExitCodeRead   = $false
        StdoutLines    = @()
        StderrLines    = @()
        ProcessStopped = $false
        NativeErrorCode = $null
    }

    $process = $null
    $stdout = $null
    $stderr = $null

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $FilePath
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi

        $started = $process.Start()
        if (-not $started) {
            $result.FailureKind = 'start_other'
            return [pscustomobject]$result
        }

        $result.ProcessStarted = $true

        # Read asynchronously to avoid deadlock if either redirected stream fills.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutMs)) {
            $result.FailureKind = 'timeout'
            try {
                $process.Kill()
                $stopped = $process.WaitForExit(2000)
                $result.ProcessStopped = [bool]($stopped -or $process.HasExited)
            }
            catch {
                $result.ProcessStopped = $false
            }
            if ($stdoutTask.IsCompleted) {
                $stdout = $stdoutTask.Result
                $result.StdoutLines = @($stdout -split "`r?`n" | Where-Object { $_ -ne '' })
            }
            if ($stderrTask.IsCompleted) {
                $stderr = $stderrTask.Result
                $result.StderrLines = @($stderr -split "`r?`n" | Where-Object { $_ -ne '' })
            }
            return [pscustomobject]$result
        }

        # Ensure asynchronous stream reads have completed after process exit.
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $result.StdoutLines = @($stdout -split "`r?`n" | Where-Object { $_ -ne '' })
        $result.StderrLines = @($stderr -split "`r?`n" | Where-Object { $_ -ne '' })
        $result.ExitCode = $process.ExitCode
        $result.ExitCodeRead = $true
        $result.ProcessStopped = $true
        $result.FailureKind = 'ok'
        return [pscustomobject]$result
    }
    catch {
        $exception = $_.Exception
        if ($exception -is [System.ComponentModel.Win32Exception]) {
            $result.NativeErrorCode = $exception.NativeErrorCode
            if ($exception.NativeErrorCode -in @(2, 3)) {
                $result.FailureKind = 'start_not_found'
            }
            else {
                $result.FailureKind = 'start_other'
            }
        }
        else {
            $result.FailureKind = 'start_other'
        }

        if ($null -ne $process) {
            try {
                if ($process.HasExited) {
                    $result.ProcessStopped = $true
                }
            }
            catch { }
        }
        return [pscustomobject]$result
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}
