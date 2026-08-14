$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\scripts\windows.ps1'

function Invoke-Validation {
    param(
        [Parameter(Mandatory = $true)][string]$SessionProfile,
        [Parameter(Mandatory = $true)][string]$EnableWsl,
        [Parameter(Mandatory = $true)][string]$Deadline,
        [string]$Candidate = '12345678'
    )

    $env:SESSION_PROFILE = $SessionProfile
    $env:ENABLE_WSL = $EnableWsl
    $env:SESSION_DEADLINE_EPOCH = $Deadline
    $env:SESSION_PASSWORD = $Candidate
    & $scriptPath validate
}

function Assert-ValidationFailure {
    param(
        [Parameter(Mandatory = $true)][string]$SessionProfile,
        [Parameter(Mandatory = $true)][string]$EnableWsl,
        [Parameter(Mandatory = $true)][string]$Deadline
    )

    try {
        Invoke-Validation -SessionProfile $SessionProfile -EnableWsl $EnableWsl -Deadline $Deadline
    } catch {
        return
    }
    throw "Validation accepted profile=$SessionProfile enable_wsl=$EnableWsl deadline=$Deadline"
}

$futureDeadline = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300).ToString()
foreach ($sessionProfile in @('core', 'developer')) {
    foreach ($enableWsl in @('true', 'false')) {
        Invoke-Validation -SessionProfile $sessionProfile -EnableWsl $enableWsl -Deadline $futureDeadline
    }
}

Assert-ValidationFailure -SessionProfile 'workstation' -EnableWsl 'false' -Deadline $futureDeadline
Assert-ValidationFailure -SessionProfile 'core' -EnableWsl 'invalid' -Deadline $futureDeadline
Assert-ValidationFailure -SessionProfile 'core' -EnableWsl 'false' -Deadline 'invalid'
Assert-ValidationFailure -SessionProfile 'core' -EnableWsl 'false' `
    -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(-1).ToUnixTimeSeconds().ToString())

try {
    Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline `
        -Candidate '1234567'
    throw 'Windows validation accepted a 7-character session password'
} catch {
    if ($_.Exception.Message -eq 'Windows validation accepted a 7-character session password') {
        throw
    }
    if ($_.Exception.Message -ne 'SESSION_PASSWORD must contain at least 8 characters') {
        throw "Windows validation returned an unexpected password error: $_"
    }
}

Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline `
    -Candidate '12345678'

try {
    Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline `
        -Candidate "12345678`nsecond-line"
    throw 'Windows validation accepted a multiline session password'
} catch {
    if ($_.Exception.Message -eq 'Windows validation accepted a multiline session password') {
        throw
    }
    if ($_.Exception.Message -ne 'SESSION_PASSWORD must be a single line') {
        throw "Windows validation returned an unexpected multiline password error: $_"
    }
}

Remove-Item Env:TAILSCALE_OAUTH_CLIENT_ID -ErrorAction SilentlyContinue
Remove-Item Env:TAILSCALE_OAUTH_CLIENT_SECRET -ErrorAction SilentlyContinue
Remove-Item Env:TAILSCALE_HOSTNAME -ErrorAction SilentlyContinue
& $scriptPath cleanup

$env:SESSION_PROFILE = 'core'
$env:ENABLE_WSL = 'false'
$env:SESSION_DEADLINE_EPOCH = $futureDeadline
$env:SESSION_PASSWORD = '12345678'
$env:TAILSCALE_HOSTNAME = 'debug-session-windows'
Remove-Item Env:TAILSCALE_OAUTH_CLIENT_ID -ErrorAction SilentlyContinue
Remove-Item Env:TAILSCALE_OAUTH_CLIENT_SECRET -ErrorAction SilentlyContinue
Remove-Item Env:TAILSCALE_TAGS -ErrorAction SilentlyContinue
try {
    & $scriptPath run
    throw 'Windows run accepted a missing OAuth client ID'
} catch {
    if ($_.Exception.Message -eq 'Windows run accepted a missing OAuth client ID') {
        throw
    }
    if ($_.Exception.Message -ne 'Required environment variable TAILSCALE_OAUTH_CLIENT_ID is empty') {
        throw "Windows run did not require TAILSCALE_OAUTH_CLIENT_ID: $_"
    }
    $message = [string]$_
    if ($message -like '*choco *' -or $message -like '*Chocolatey*') {
        throw 'Windows run reached Chocolatey before the OAuth client check'
    }
}

$windowsScript = Get-Content -LiteralPath $scriptPath -Raw
if ($windowsScript -notmatch 'stop-session\.cmd') {
    throw 'Windows does not install the stop-session command on PATH'
}
if ($windowsScript -notmatch 'stop-session\.lnk') {
    throw 'Windows does not install the desktop stop-session shortcut'
}
if ($windowsScript -match 'STOP_SESSION_HERE') {
    throw 'Windows still writes the STOP_SESSION_HERE instruction file'
}
if ($windowsScript -match 'Desktop\\STOP_SESSION') {
    throw 'Windows still writes the STOP_SESSION file to the desktop'
}

Write-Output 'Windows input behavior: PASS'
