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
    if ($message -like '*pkgs.tailscale.com*' -or $message -like '*msiexec*') {
        throw 'Windows run reached Tailscale install before the OAuth client check'
    }
}

$windowsScript = Get-Content -LiteralPath $scriptPath -Raw
if ($windowsScript -match 'choco install' -or $windowsScript -match 'Invoke-ChocolateyInstall') {
    throw 'Windows still installs software with Chocolatey'
}
if ($windowsScript -notmatch 'https://pkgs\.tailscale\.com/stable/\?mode=json') {
    throw 'Windows does not resolve Tailscale from the official stable packages'
}
if ($windowsScript -notmatch '--unattended') {
    throw 'Windows does not bring Tailscale up in unattended mode'
}
if ($windowsScript -notmatch 'update\.code\.visualstudio\.com/latest/') {
    throw 'Windows does not install VS Code from the official Microsoft installer'
}
if ($windowsScript -notmatch 'nodejs\.org/dist/index\.json') {
    throw 'Windows does not resolve Node.js from the official distribution index'
}
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
if ($windowsScript -notmatch 'Enable-RcloneMounts') {
    throw 'Windows does not provision rclone mounts'
}
if ($windowsScript -notmatch 'Initialize-RcloneWindowsMountPoint') {
    throw 'Windows does not prepare a WinFsp-compatible mount point'
}
if ($windowsScript -match 'New-Item -Path \$dest -ItemType Directory') {
    throw 'Windows pre-creates the rclone mount leaf; WinFsp requires a nonexistent path'
}
if ($windowsScript -notmatch 'downloads\.rclone\.org/rclone-current-windows-') {
    throw 'Windows does not install rclone from the official current package'
}
if ($windowsScript -notmatch 'api\.github\.com/repos/winfsp/winfsp/releases/latest') {
    throw 'Windows does not resolve WinFsp from the official GitHub latest release'
}
if ($windowsScript -notmatch '--vfs-cache-mode'', ''writes') {
    throw 'Windows does not use vfs-cache-mode writes'
}
if ($windowsScript -match '--allow-other') {
    throw 'Windows enables FUSE allow-other'
}
if ($windowsScript -notmatch 'Close-RcloneMounts') {
    throw 'Windows does not clean up rclone mounts'
}

$enableCore = $windowsScript.LastIndexOf('Enter-CoreSession')
$enableRclone = $windowsScript.LastIndexOf('Enable-RcloneMounts')
$enableDeveloper = $windowsScript.LastIndexOf('Install-DeveloperProfile')
$enableWsl = $windowsScript.LastIndexOf('Initialize-WslUbuntu')
if ($enableCore -lt 0 -or $enableRclone -lt 0 -or $enableDeveloper -lt 0 -or $enableWsl -lt 0) {
    throw 'Windows session startup is missing core, rclone, developer, or WSL steps'
}
if (-not ($enableCore -lt $enableRclone -and $enableRclone -lt $enableDeveloper -and $enableRclone -lt $enableWsl)) {
    throw 'Windows does not mount rclone after Core Session ready and before Developer/WSL'
}
if ($windowsScript -notmatch '\$env:WSL_UTF8 = ''1''') {
    throw 'Windows does not force UTF-8 WSL CLI output'
}
if ($windowsScript -match '(?s)--set-version \$distribution 2\s+if \(\$LASTEXITCODE -ne 0\) \{ throw ''Could not configure Ubuntu to use WSL 2'' \}') {
    throw 'Windows treats a no-op WSL --set-version as fatal'
}
if ($windowsScript -match '(?s)--list --verbose.*if \(\$LASTEXITCODE -ne 0\) \{ throw ''Could not list installed WSL distributions'' \}') {
    throw 'Windows treats an empty WSL list as a list failure'
}
if ($windowsScript -match '--exec sh -c \$initializeUser') {
    throw 'Windows still passes a multiline script to sh -c'
}
if ($windowsScript -notmatch 'UbuntuInsightsConsent') {
    throw 'Windows does not pre-seed Ubuntu Insights consent'
}
if ($windowsScript -notmatch '--distribution \$distribution /bin/true') {
    throw 'Windows does not complete Ubuntu first-launch setup without --exec'
}

$helperStart = $windowsScript.IndexOf('function Get-WslTextLines')
$helperEnd = $windowsScript.IndexOf('function Initialize-WslUbuntu')
if ($helperStart -lt 0 -or $helperEnd -lt 0 -or $helperEnd -le $helperStart) {
    throw 'Windows is missing WSL list helper functions'
}
Invoke-Expression $windowsScript.Substring($helperStart, $helperEnd - $helperStart)

function Assert-WslVersionResolve {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Output,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        $Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $got = Resolve-WslDistributionVersion -Output $Output -ExitCode $ExitCode -Distribution 'Ubuntu'
    if ($got -ne $Expected) {
        throw "$Label`: expected '$Expected', received '$got'"
    }
}

Assert-WslVersionResolve -Output @(
    'Windows Subsystem for Linux has no installed distributions.',
    'You can resolve this by installing a distribution with the instructions below:'
) -ExitCode -1 -Expected $null -Label 'WSL empty-list message'
Assert-WslVersionResolve -Output @() -ExitCode 1 -Expected $null -Label 'WSL empty captured output'
Assert-WslVersionResolve -Output @(
    'Error code: Wsl/Service/WSL_E_DEFAULT_DISTRO_NOT_FOUND'
) -ExitCode 1 -Expected $null -Label 'WSL default distro missing'
Assert-WslVersionResolve -Output @(
    '  NAME      STATE           VERSION',
    '* Ubuntu    Stopped         2'
) -ExitCode 0 -Expected '2' -Label 'Ubuntu already on WSL 2'
Assert-WslVersionResolve -Output @(
    ("* Ubuntu`0    Stopped         2")
) -ExitCode 0 -Expected '2' -Label 'UTF-16 WSL list row'
Assert-WslVersionResolve -Output @(
    '  NAME            STATE           VERSION',
    '  Ubuntu-24.04    Stopped         2'
) -ExitCode 0 -Expected $null -Label 'different distro present'

try {
    Resolve-WslDistributionVersion -Output @('Access is denied') -ExitCode 1 -Distribution 'Ubuntu'
    throw 'Windows accepted an unexpected WSL list failure'
} catch {
    if ($_.Exception.Message -eq 'Windows accepted an unexpected WSL list failure') {
        throw
    }
    if ($_.Exception.Message -notlike 'Could not list installed WSL distributions*') {
        throw "Windows returned an unexpected WSL list error: $_"
    }
}

$initScript = Get-WslRootInitScript
if ($initScript -notmatch '(?m)^set -eu$') {
    throw 'WSL root init script does not start with set -eu'
}
if ($initScript -notmatch 'ubuntu-insights consent wsl_setup -s=false') {
    throw 'WSL root init script does not opt out of Ubuntu Insights'
}
$scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) 'debug-session-wsl-init-test.sh'
try {
    Write-WslUnixScript -Path $scriptFile -Script "set -eu`r`nif true; then`r`n  echo hi`r`nfi`r`n"
    $written = [System.IO.File]::ReadAllBytes($scriptFile)
    if ($written -contains 13) {
        throw 'WSL unix script still contains carriage returns'
    }
    $text = [System.Text.Encoding]::UTF8.GetString($written)
    if (-not $text.StartsWith("set -eu`n")) {
        throw "WSL unix script did not start with LF-terminated set -eu: $text"
    }
} finally {
    Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
}

$closeRclone = $windowsScript.LastIndexOf('Close-RcloneMounts')
$logout = $windowsScript.LastIndexOf('$tailscale logout')
if ($closeRclone -lt 0 -or $logout -lt 0 -or $closeRclone -ge $logout) {
    throw 'Windows does not clean up rclone mounts before Tailscale logout'
}

Write-Output 'Windows input behavior: PASS'
