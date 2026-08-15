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

$env:RCLONE_HOME_LINKS = @"
# comment
.agents/=drive/dotfiles/agents/
.grok/=drive/dotfiles/grok/
"@
Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline `
    -Candidate '12345678'
Remove-Item Env:RCLONE_HOME_LINKS -ErrorAction SilentlyContinue

$env:RCLONE_HOME_LINKS = ".agents/=drive/a/`n.agents/=drive/b/"
try {
    Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline
    throw 'Windows validation accepted a duplicate RCLONE_HOME_LINKS target'
} catch {
    if ($_.Exception.Message -eq 'Windows validation accepted a duplicate RCLONE_HOME_LINKS target') {
        throw
    }
    if ($_.Exception.Message -notlike '*duplicate target*') {
        throw "Windows validation returned an unexpected home-link error: $_"
    }
}
Remove-Item Env:RCLONE_HOME_LINKS -ErrorAction SilentlyContinue

$env:RCLONE_HOME_LINKS = ".grok/sessions/=koofr/Home/.grok/sessions/`n.grok/config.toml=koofr/Home/.grok/config.toml"
Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline `
    -Candidate '12345678'
Remove-Item Env:RCLONE_HOME_LINKS -ErrorAction SilentlyContinue

$env:RCLONE_HOME_LINKS = ".agents/=koofr/Home/.agents"
try {
    Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline
    throw 'Windows validation accepted a directory marker mismatch'
} catch {
    if ($_.Exception.Message -eq 'Windows validation accepted a directory marker mismatch') {
        throw
    }
    if ($_.Exception.Message -notlike '*directory marker mismatch*') {
        throw "Windows validation returned an unexpected marker-mismatch error: $_"
    }
}
Remove-Item Env:RCLONE_HOME_LINKS -ErrorAction SilentlyContinue

$env:RCLONE_HOME_LINKS = ".grok/=drive/g/`n.grok/sessions/=drive/g/sessions/"
try {
    Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline
    throw 'Windows validation accepted a conflicting RCLONE_HOME_LINKS target'
} catch {
    if ($_.Exception.Message -eq 'Windows validation accepted a conflicting RCLONE_HOME_LINKS target') {
        throw
    }
    if ($_.Exception.Message -notlike '*conflicts*') {
        throw "Windows validation returned an unexpected home-link conflict error: $_"
    }
}
Remove-Item Env:RCLONE_HOME_LINKS -ErrorAction SilentlyContinue

$env:GIT_WORKSPACES = @"
# comment
https://github.com/org/proj-a
my-app=https://github.com/org/proj-c
org/priv
"@
Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline `
    -Candidate '12345678'
Remove-Item Env:GIT_WORKSPACES -ErrorAction SilentlyContinue

$env:GIT_WORKSPACES = "https://github.com/org/a`nhttps://github.com/other/a.git"
try {
    Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline
    throw 'Windows validation accepted a duplicate GIT_WORKSPACES name'
} catch {
    if ($_.Exception.Message -eq 'Windows validation accepted a duplicate GIT_WORKSPACES name') {
        throw
    }
    if ($_.Exception.Message -notlike '*duplicate name*') {
        throw "Windows validation returned an unexpected git workspace error: $_"
    }
}
Remove-Item Env:GIT_WORKSPACES -ErrorAction SilentlyContinue

$env:GIT_WORKSPACES = 'https://user:pass@github.com/org/proj'
try {
    Invoke-Validation -SessionProfile 'core' -EnableWsl 'false' -Deadline $futureDeadline
    throw 'Windows validation accepted a GIT_WORKSPACES URL with userinfo'
} catch {
    if ($_.Exception.Message -eq 'Windows validation accepted a GIT_WORKSPACES URL with userinfo') {
        throw
    }
    if ($_.Exception.Message -notlike '*URL is invalid*') {
        throw "Windows validation returned an unexpected git workspace URL error: $_"
    }
}
Remove-Item Env:GIT_WORKSPACES -ErrorAction SilentlyContinue

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
if ($windowsScript -notmatch "Join-Path \$env:USERPROFILE 'rclone'") {
    throw 'Windows does not mount remotes under the user rclone directory'
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
if ($windowsScript -notmatch 'Enable-RcloneHomeLinks') {
    throw 'Windows does not provision rclone home links'
}
if ($windowsScript -notmatch 'Enable-GitWorkspaces') {
    throw 'Windows does not provision git workspaces'
}
if ($windowsScript -notmatch "Join-Path \$env:USERPROFILE 'workspaces'") {
    throw 'Windows does not clone git workspaces under the user workspaces directory'
}
if ($windowsScript -match 'home links are not implemented on Windows') {
    throw 'Windows still no-ops rclone home links'
}
if ($windowsScript -notmatch 'Wait-RcloneExit') {
    throw 'Windows does not wait for rclone VFS write-back before deleting the cache'
}

$enableCore = $windowsScript.LastIndexOf('Enter-CoreSession')
$enableRclone = $windowsScript.LastIndexOf('Enable-RcloneMounts')
$enableLinks = $windowsScript.LastIndexOf('Enable-RcloneHomeLinks')
$enableGit = $windowsScript.LastIndexOf('Enable-GitWorkspaces')
$enableDeveloper = $windowsScript.LastIndexOf('Install-DeveloperProfile')
$enableWsl = $windowsScript.LastIndexOf('Initialize-WslUbuntu')
if ($enableCore -lt 0 -or $enableRclone -lt 0 -or $enableLinks -lt 0 -or $enableGit -lt 0 -or $enableDeveloper -lt 0 -or $enableWsl -lt 0) {
    throw 'Windows session startup is missing core, rclone, home links, git workspaces, developer, or WSL steps'
}
if (-not ($enableCore -lt $enableRclone -and $enableRclone -lt $enableLinks -and $enableLinks -lt $enableGit -and $enableGit -lt $enableDeveloper -and $enableGit -lt $enableWsl)) {
    throw 'Windows does not clone git workspaces after home links and before Developer/WSL'
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

$closeFn = $windowsScript.IndexOf('function Close-RcloneMounts')
$waitRclone = $windowsScript.IndexOf('Wait-RcloneExit', $closeFn)
$forceKill = $windowsScript.IndexOf('Stop-Process -Force', $closeFn)
$cacheRemove = $windowsScript.IndexOf("Join-Path `$env:LOCALAPPDATA 'rclone'", $closeFn)
if ($closeFn -lt 0 -or $waitRclone -lt 0 -or $forceKill -lt 0 -or $cacheRemove -lt 0) {
    throw 'Windows cleanup is missing VFS write-back wait, force-kill fallback, or cache removal'
}
if (-not ($waitRclone -lt $forceKill -and $forceKill -lt $cacheRemove)) {
    throw 'Windows does not wait for rclone to exit before force-killing it and deleting the VFS cache'
}

$linkStart = $windowsScript.IndexOf('function Test-RcloneHomeLinkComponentValid')
$linkEnd = $windowsScript.IndexOf('function Add-RcloneHomeLink')
if ($linkStart -lt 0 -or $linkEnd -lt 0 -or $linkEnd -le $linkStart) {
    throw 'Windows is missing rclone home link helper functions'
}
Invoke-Expression $windowsScript.Substring($linkStart, $linkEnd - $linkStart)

if (-not (Test-RcloneHomeLinkTargetValid -Target '.agents')) {
    throw 'Windows rejected a valid home link target'
}
if (-not (Test-RcloneHomeLinkTargetValid -Target '.grok/sessions')) {
    throw 'Windows rejected a valid nested home link target'
}
if (Test-RcloneHomeLinkTargetValid -Target 'rclone') {
    throw 'Windows accepted rclone as a home link target'
}
if (Test-RcloneHomeLinkTargetValid -Target 'rclone/foo') {
    throw 'Windows accepted rclone as a nested home link target'
}
if (Test-RcloneHomeLinkTargetValid -Target '.grok/../sessions') {
    throw 'Windows accepted a nested target containing ..'
}
if (Test-RcloneHomeLinkSourceValid -Source 'drive/../foo') {
    throw 'Windows accepted a source path containing ..'
}

$env:RCLONE_HOME_LINKS = @"
# keep
.agents/=drive/dotfiles/agents/
.grok/config.toml=drive/grok/config.toml
"@
$parsed = @(Get-RcloneHomeLinks)
if ($parsed.Count -ne 2) {
    throw "Windows parsed $($parsed.Count) home links, expected 2"
}
if ($parsed[0].Target -ne '.agents' -or $parsed[0].Source -ne 'drive/dotfiles/agents' -or $parsed[0].Kind -ne 'dir') {
    throw "Windows first home link was $($parsed[0].Target)=$($parsed[0].Source) kind=$($parsed[0].Kind)"
}
if ($parsed[1].Target -ne '.grok/config.toml' -or $parsed[1].Kind -ne 'file') {
    throw "Windows file home link was $($parsed[1].Target) kind=$($parsed[1].Kind)"
}
Remove-Item Env:RCLONE_HOME_LINKS -ErrorAction SilentlyContinue

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('debug-session-home-links-' + [guid]::NewGuid().ToString('N'))
New-Item -Path $scratchRoot -ItemType Directory | Out-Null
$previousProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $scratchRoot
    $nestedRel = ConvertTo-RcloneHomeLinkRelativeTarget -Source 'koofr/Home/.grok/sessions' `
        -Destination (Join-Path (Join-Path $scratchRoot '.grok') 'sessions')
    if ($nestedRel -ne '..\rclone\koofr\Home\.grok\sessions') {
        throw "ConvertTo-RcloneHomeLinkRelativeTarget returned $nestedRel"
    }
    $topRel = ConvertTo-RcloneHomeLinkRelativeTarget -Source 'drive/dotfiles/agents' `
        -Destination (Join-Path $scratchRoot '.agents')
    if ($topRel -ne 'rclone\drive\dotfiles\agents') {
        throw "ConvertTo-RcloneHomeLinkRelativeTarget top-level returned $topRel"
    }
    foreach ($rel in @(
            'rclone\drive\dotfiles\agents',
            'rclone\drive\other',
            'rclone\drive\empty',
            'rclone\koofr\Home\.grok\sessions'
        )) {
        New-Item -Path (Join-Path $scratchRoot $rel) -ItemType Directory -Force | Out-Null
    }
    $dest = Join-Path $scratchRoot '.agents'
    if (-not (Install-HomeSymlink -Destination $dest -RelativeTarget 'rclone\drive\dotfiles\agents')) {
        throw 'Install-HomeSymlink failed for a missing destination'
    }
    $created = Get-Item -LiteralPath $dest -Force
    if ($created.LinkType -notin @('SymbolicLink', 'Junction')) {
        throw "Install-HomeSymlink did not create a link: LinkType=$($created.LinkType)"
    }
    if (-not (Test-HomeLinkMatches -Item $created -Destination $dest -RelativeTarget 'rclone\drive\dotfiles\agents')) {
        throw "Install-HomeSymlink target was $(@($created.Target)[0])"
    }
    if (-not (Install-HomeSymlink -Destination $dest -RelativeTarget 'rclone\drive\dotfiles\agents')) {
        throw 'Install-HomeSymlink was not idempotent for the same target'
    }
    if (-not (Install-HomeSymlink -Destination $dest -RelativeTarget 'rclone\drive\other')) {
        throw 'Install-HomeSymlink did not replace a wrong symlink'
    }
    $empty = Join-Path $scratchRoot '.empty'
    New-Item -Path $empty -ItemType Directory | Out-Null
    if (-not (Install-HomeSymlink -Destination $empty -RelativeTarget 'rclone\drive\empty')) {
        throw 'Install-HomeSymlink did not replace an empty directory'
    }
    $full = Join-Path $scratchRoot '.full'
    New-Item -Path (Join-Path $full 'keep') -ItemType Directory -Force | Out-Null
    if (Install-HomeSymlink -Destination $full -RelativeTarget 'rclone\drive\full') {
        throw 'Install-HomeSymlink replaced a non-empty directory'
    }
    $file = Join-Path $scratchRoot '.file'
    Set-Content -LiteralPath $file -Value 'x'
    if (Install-HomeSymlink -Destination $file -RelativeTarget 'rclone\drive\file') {
        throw 'Install-HomeSymlink replaced a regular file'
    }
    $nestedParent = Join-Path $scratchRoot '.grok'
    $nested = Join-Path $nestedParent 'sessions'
    New-Item -Path $nestedParent -ItemType Directory -Force | Out-Null
    if (-not (Install-HomeSymlink -Destination $nested -RelativeTarget '..\rclone\koofr\Home\.grok\sessions')) {
        throw 'Install-HomeSymlink failed for a nested destination'
    }
    $nestedItem = Get-Item -LiteralPath $nested -Force
    if ($nestedItem.LinkType -notin @('SymbolicLink', 'Junction')) {
        throw "Install-HomeSymlink did not create a nested link: LinkType=$($nestedItem.LinkType)"
    }
    if (-not (Test-HomeLinkMatches -Item $nestedItem -Destination $nested -RelativeTarget '..\rclone\koofr\Home\.grok\sessions')) {
        throw "Install-HomeSymlink nested target was $(@($nestedItem.Target)[0])"
    }
    $fileSource = Join-Path $scratchRoot 'rclone\koofr\Home\.grok\config.toml'
    Ensure-RcloneHomeLinkSource -Path $fileSource -AsFile
    $fileSourceItem = Get-Item -LiteralPath $fileSource -Force
    if ($fileSourceItem.PSIsContainer) {
        throw 'Ensure-RcloneHomeLinkSource created config.toml as a directory'
    }
    $authDir = Join-Path $scratchRoot 'rclone\koofr\Home\.grok\auth.json'
    New-Item -Path $authDir -ItemType Directory -Force | Out-Null
    Ensure-RcloneHomeLinkSource -Path $authDir -AsFile
    $authItem = Get-Item -LiteralPath $authDir -Force
    if ($authItem.PSIsContainer) {
        throw 'Ensure-RcloneHomeLinkSource did not convert an empty auth.json directory into a file'
    }
    $fileDest = Join-Path $nestedParent 'config.toml'
    if (-not (Install-HomeSymlink -Destination $fileDest -RelativeTarget '..\rclone\koofr\Home\.grok\config.toml' -AsFile)) {
        throw 'Install-HomeSymlink failed for a file destination'
    }
    $fileLink = Get-Item -LiteralPath $fileDest -Force
    if ($fileLink.LinkType -ne 'SymbolicLink') {
        throw "Install-HomeSymlink did not create a file symlink: LinkType=$($fileLink.LinkType)"
    }
} finally {
    $env:USERPROFILE = $previousProfile
    Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($windowsScript -notmatch '(?s)function Get-RcloneWritebackWaitSeconds\s*\{\s*return 120') {
    throw 'Windows rclone write-back wait is not 120 seconds'
}

$gitStart = $windowsScript.IndexOf('function Test-GitWorkspacesPresent')
$gitEnd = $windowsScript.IndexOf('function Enable-GitWorkspaces')
if ($gitStart -lt 0 -or $gitEnd -lt 0 -or $gitEnd -le $gitStart) {
    throw 'Windows is missing git workspace helper functions'
}
Invoke-Expression $windowsScript.Substring($gitStart, $gitEnd - $gitStart)

$env:GIT_WORKSPACES = @"
# keep
https://github.com/org/proj-a.git
my-app=https://github.com/org/proj-c
org/priv
"@
$gitParsed = @(Get-GitWorkspaces)
if ($gitParsed.Count -ne 3) {
    throw "Windows parsed $($gitParsed.Count) git workspaces, expected 3"
}
if ($gitParsed[0].Name -ne 'proj-a' -or $gitParsed[0].Url -ne 'https://github.com/org/proj-a.git') {
    throw "Windows first git workspace was $($gitParsed[0].Name)=$($gitParsed[0].Url)"
}
if ($gitParsed[1].Name -ne 'my-app' -or $gitParsed[1].Url -ne 'https://github.com/org/proj-c') {
    throw "Windows custom-name git workspace was $($gitParsed[1].Name)=$($gitParsed[1].Url)"
}
if ($gitParsed[2].Name -ne 'org/priv' -or $gitParsed[2].Url -ne 'https://github.com/org/priv') {
    throw "Windows shorthand git workspace was $($gitParsed[2].Name)=$($gitParsed[2].Url)"
}
Remove-Item Env:GIT_WORKSPACES -ErrorAction SilentlyContinue

if ((Get-GitWorkspaceCredentialHelper) -cne '!f() { echo username=x-access-token; echo password=$GIT_WORKSPACES_TOKEN; }; f') {
    throw 'Windows credential helper does not read GIT_WORKSPACES_TOKEN from the environment'
}
if ((ConvertTo-GitWorkspaceNameFromUrl -Url 'https://github.com/org/proj-b.git') -ne 'proj-b') {
    throw 'Windows did not strip .git from the derived workspace name'
}
if (-not (Test-GitWorkspaceUrlValid -Url 'https://gitlab.example.com:8443/group/sub/repo.git')) {
    throw 'Windows rejected a valid git workspace URL with a port'
}
if (Test-GitWorkspaceUrlValid -Url 'https://user:pass@github.com/org/proj') {
    throw 'Windows accepted a git workspace URL with userinfo'
}
if (Test-GitWorkspaceNameValid -Name '..') {
    throw 'Windows accepted .. as a git workspace name'
}
if (-not (Test-GitWorkspaceShorthandValid -Spec 'org/priv')) {
    throw 'Windows rejected the org/priv git workspace shorthand'
}
if (Test-GitWorkspaceShorthandValid -Spec 'org/priv/extra') {
    throw 'Windows accepted a three-segment git workspace shorthand'
}
if (-not (Test-GitWorkspaceNameValid -Name 'org/priv')) {
    throw 'Windows rejected org/priv as a git workspace name'
}

Write-Output 'Windows input behavior: PASS'
