param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('validate', 'run', 'cleanup')]
    [string]$Command
)

$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Assert-EnvironmentVariable {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable $Name is empty"
    }
    return $value
}

function Assert-SessionPassword {
    $password = Assert-EnvironmentVariable 'SESSION_PASSWORD'
    if ($password.Length -lt 8) {
        throw 'SESSION_PASSWORD must contain at least 8 characters'
    }
    if ($password.Contains("`n") -or $password.Contains("`r")) {
        throw 'SESSION_PASSWORD must be a single line'
    }
    return $password
}

function Get-ValidatedSessionInput {
    $sessionProfile = Assert-EnvironmentVariable 'SESSION_PROFILE'
    $deadlineText = Assert-EnvironmentVariable 'SESSION_DEADLINE_EPOCH'

    if ($sessionProfile -notin @('core', 'developer')) {
        throw 'SESSION_PROFILE must be core or developer'
    }
    if ($env:ENABLE_WSL -notin @('true', 'false')) {
        throw 'ENABLE_WSL must be true or false'
    }

    $deadline = 0L
    if (-not [long]::TryParse($deadlineText, [ref]$deadline)) {
        throw 'SESSION_DEADLINE_EPOCH must be a Unix timestamp'
    }
    if ($deadline -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
        throw 'SESSION_DEADLINE_EPOCH must be in the future'
    }

    $null = Assert-SessionPassword

    return @{
        Deadline = $deadline
        SessionProfile = $sessionProfile
    }
}

function Get-WindowsNativeArch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        'x86' { return 'x86' }
        default { throw "Unsupported Windows architecture: $($env:PROCESSOR_ARCHITECTURE)" }
    }
}

function Sync-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Initialize-PrivateFirewallRule {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$LocalAddress
    )

    $existing = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        $existing | Remove-NetFirewallRule
    }
    New-NetFirewallRule -Name $Name -DisplayName $DisplayName -Enabled True `
        -Direction Inbound -Protocol TCP -Action Allow -LocalPort $Port `
        -LocalAddress $LocalAddress | Out-Null
}

function Assert-PrivateFirewallRule {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedAddress
    )

    $rule = Get-NetFirewallRule -Name $Name -ErrorAction Stop
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    if (-not $rule.Enabled -or $ExpectedAddress -notin @($addressFilter.LocalAddress)) {
        throw "$Name is not restricted to the Tailscale address $ExpectedAddress"
    }
}

function Initialize-SessionPasswordPolicy {
    $exportPath = Join-Path $env:TEMP 'debug-session-secpol.inf'
    $dbPath = Join-Path $env:TEMP 'debug-session-secpol.sdb'
    try {
        & secedit.exe /export /cfg $exportPath | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exportPath)) {
            throw 'Could not export the local security policy'
        }

        $desired = [ordered]@{
            PasswordComplexity = 'PasswordComplexity = 0'
            MinimumPasswordLength = 'MinimumPasswordLength = 0'
            PasswordHistorySize = 'PasswordHistorySize = 0'
            MinimumPasswordAge = 'MinimumPasswordAge = 0'
        }
        $seen = @{}
        $policy = [System.Collections.Generic.List[string]]::new()
        foreach ($line in Get-Content -LiteralPath $exportPath -Encoding unicode) {
            $replaced = $false
            foreach ($name in @($desired.Keys)) {
                if ($line -match "^\s*$name\s*=") {
                    $policy.Add($desired[$name])
                    $seen[$name] = $true
                    $replaced = $true
                    break
                }
            }
            if (-not $replaced) {
                $policy.Add($line)
            }
        }
        $missing = @($desired.Keys | Where-Object { -not $seen.ContainsKey($_) })
        if ($missing.Count -gt 0) {
            $insertAt = 0
            for ($index = 0; $index -lt $policy.Count; $index++) {
                if ($policy[$index] -match '^\s*\[System Access\]\s*$') {
                    $insertAt = $index + 1
                    break
                }
            }
            foreach ($name in $missing) {
                $policy.Insert($insertAt, $desired[$name])
                $insertAt++
            }
        }
        Set-Content -LiteralPath $exportPath -Value $policy -Encoding unicode

        & secedit.exe /configure /db $dbPath /cfg $exportPath /areas SECURITYPOLICY /quiet | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not relax the local password policy for the session user'
        }
    } finally {
        Remove-Item -LiteralPath $exportPath, $dbPath -Force -ErrorAction SilentlyContinue
    }
}

function Enable-CoreSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        '',
        Justification = 'The GitHub secret must be converted to set the temporary local runner password.'
    )]
    param([Parameter(Mandatory = $true)][string]$TailscaleIp)

    $password = Assert-SessionPassword

    $sshdExe = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    if (-not (Test-Path -LiteralPath $sshdExe)) {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    }
    Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue |
        Disable-NetFirewallRule | Out-Null
    Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue |
        Disable-NetFirewallRule | Out-Null
    Stop-Service sshd -ErrorAction SilentlyContinue

    $sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (-not (Test-Path -LiteralPath $sshdConfig)) {
        Start-Service sshd
        Stop-Service sshd
    }
    $sshdText = Get-Content -LiteralPath $sshdConfig -Raw
    $sshdText = [regex]::Replace(
        $sshdText,
        '(?im)^\s*(ListenAddress|PasswordAuthentication)\s+.*\r?\n?',
        ''
    )
    $directives = "PasswordAuthentication yes`r`nListenAddress $TailscaleIp`r`n"
    $matchBlock = [regex]::Match($sshdText, '(?im)^\s*Match\s+')
    if ($matchBlock.Success) {
        $sshdText = $sshdText.Insert($matchBlock.Index, $directives)
    } else {
        $sshdText = "$sshdText`r`n$directives"
    }
    Set-Content -LiteralPath $sshdConfig -Value $sshdText -Encoding ascii -NoNewline

    $sshd = Join-Path $env:SystemRoot 'System32\OpenSSH\sshd.exe'
    & $sshd -t -f $sshdConfig
    if ($LASTEXITCODE -ne 0) {
        throw 'The OpenSSH configuration is invalid'
    }

    Initialize-PrivateFirewallRule -Name 'Debug-Session-SSH-Tailscale' `
        -DisplayName 'Debug Session SSH over Tailscale' -Port 22 -LocalAddress $TailscaleIp
    Initialize-PrivateFirewallRule -Name 'Debug-Session-RDP-Tailscale' `
        -DisplayName 'Debug Session RDP over Tailscale' -Port 3389 -LocalAddress $TailscaleIp

    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name fDenyTSConnections -Value 0
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name UserAuthentication -Value 1
    Initialize-SessionPasswordPolicy
    try {
        Set-LocalUser -Name runneradmin -Password (ConvertTo-SecureString -AsPlainText $password -Force)
    } catch {
        throw 'Could not set the runneradmin password; SESSION_PASSWORD was rejected by Windows'
    }

    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    Start-Service TermService

    powercfg -change -monitor-timeout-ac 0 | Out-Null
    powercfg -change -disk-timeout-ac 0 | Out-Null
    powercfg -change -standby-timeout-ac 0 | Out-Null
    powercfg -change -hibernate-timeout-ac 0 | Out-Null
    powercfg -hibernate off | Out-Null

    if ((Get-Service sshd).Status -ne 'Running') {
        throw 'OpenSSH did not reach the running state'
    }
    if ((Get-Service TermService).Status -ne 'Running') {
        throw 'Remote Desktop did not reach the running state'
    }
    $sshListeners = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue)
    if ($sshListeners.Count -eq 0) {
        throw 'OpenSSH is not listening on TCP port 22'
    }
    if ($sshListeners.LocalAddress | Where-Object { $_ -ne $TailscaleIp }) {
        throw 'OpenSSH is listening outside the assigned Tailscale address'
    }
    if (-not (Get-NetTCPConnection -State Listen -LocalPort 3389 -ErrorAction SilentlyContinue)) {
        throw 'Remote Desktop is not listening on TCP port 3389'
    }
    Assert-PrivateFirewallRule -Name 'Debug-Session-SSH-Tailscale' -ExpectedAddress $TailscaleIp
    Assert-PrivateFirewallRule -Name 'Debug-Session-RDP-Tailscale' -ExpectedAddress $TailscaleIp
}

function Get-TailscaleCommand {
    return 'C:\Program Files\Tailscale\tailscale.exe'
}

function Install-TailscalePackage {
    $arch = Get-WindowsNativeArch

    try {
        $index = Invoke-RestMethod -Uri 'https://pkgs.tailscale.com/stable/?mode=json'
    } catch {
        throw 'Could not resolve the latest stable Tailscale Windows installer'
    }
    $packageName = [string]$index.MSIs.$arch
    if ([string]::IsNullOrWhiteSpace($packageName)) {
        throw "Tailscale did not publish a stable Windows installer for $arch"
    }

    $packageUrl = "https://pkgs.tailscale.com/stable/$packageName"
    $installer = Join-Path $env:TEMP $packageName
    try {
        try {
            Invoke-WebRequest -Uri $packageUrl -OutFile $installer -UseBasicParsing
        } catch {
            throw 'Could not download the latest stable Tailscale Windows installer'
        }
        try {
            $expected = ([string](Invoke-RestMethod -Uri "$packageUrl.sha256")).Trim()
        } catch {
            throw 'Could not download the Tailscale installer checksum'
        }
        $actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
        if ([string]::IsNullOrWhiteSpace($expected) -or $actual -ne $expected) {
            throw 'The Tailscale installer checksum did not match'
        }

        $process = Start-Process -FilePath msiexec.exe -Wait -PassThru -ArgumentList @(
            '/i', $installer, '/qn', '/norestart', 'TS_NOLAUNCH=1'
        )
        if ($process.ExitCode -notin @(0, 1641, 3010)) {
            throw 'The latest stable Tailscale installation failed'
        }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}

function Assert-OAuthSessionInput {
    $null = Assert-EnvironmentVariable 'TAILSCALE_OAUTH_CLIENT_ID'
    $null = Assert-EnvironmentVariable 'TAILSCALE_OAUTH_CLIENT_SECRET'
    $null = Assert-EnvironmentVariable 'TAILSCALE_HOSTNAME'
    $tags = Assert-EnvironmentVariable 'TAILSCALE_TAGS'
    foreach ($tag in $tags.Split(',')) {
        if ($tag -notmatch '^tag:[A-Za-z0-9][A-Za-z0-9_-]*$') {
            throw 'TAILSCALE_TAGS must be a comma-separated list of Tailscale tags such as tag:debug-session'
        }
    }
}

function Get-TailscaleOAuthAccessToken {
    $clientId = Assert-EnvironmentVariable 'TAILSCALE_OAUTH_CLIENT_ID'
    $clientSecret = Assert-EnvironmentVariable 'TAILSCALE_OAUTH_CLIENT_SECRET'
    try {
        $response = Invoke-RestMethod -Method Post -Uri 'https://api.tailscale.com/api/v2/oauth/token' `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{
                client_id = $clientId
                client_secret = $clientSecret
                scope = 'devices:core'
            }
    } catch {
        throw 'Could not exchange the Tailscale OAuth client for an access token'
    }
    if ([string]::IsNullOrWhiteSpace([string]$response.access_token)) {
        throw 'The Tailscale OAuth token response did not include an access token'
    }
    return [string]$response.access_token
}

function Get-TailscaleApiHeader {
    param([Parameter(Mandatory = $true)][string]$AccessToken)

    return @{ Authorization = "Bearer $AccessToken" }
}

function Test-ReservedHostnameLeftover {
    param(
        [Parameter(Mandatory = $true)][string]$ReservedName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Candidate
    )

    if ($Candidate -eq $ReservedName) {
        return $true
    }
    $prefix = "$ReservedName-"
    if ($Candidate.StartsWith($prefix) -and ($Candidate.Substring($prefix.Length) -match '^\d+$')) {
        return $true
    }
    return $false
}

function Invoke-TailscaleDeviceDelete {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [Parameter(Mandatory = $true)][string]$DeviceName
    )

    try {
        $null = Invoke-WebRequest -Method Delete `
            -Uri "https://api.tailscale.com/api/v2/device/$DeviceId" `
            -Headers (Get-TailscaleApiHeader -AccessToken $AccessToken) `
            -UseBasicParsing
    } catch {
        $status = $null
        if ($null -ne $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -ne 404) {
            throw "Could not delete leftover Tailscale device $DeviceName"
        }
    }
    Write-Output "[debug-session] Removed leftover Tailscale device $DeviceName"
}

function Invoke-ReservedHostnameReclaim {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [string]$ExcludeId = ''
    )

    $hostname = Assert-EnvironmentVariable 'TAILSCALE_HOSTNAME'
    try {
        $payload = Invoke-RestMethod -Method Get `
            -Uri 'https://api.tailscale.com/api/v2/tailnet/-/devices' `
            -Headers (Get-TailscaleApiHeader -AccessToken $AccessToken)
    } catch {
        throw 'Could not list Tailscale devices'
    }

    $devices = @()
    if ($null -ne $payload.devices) {
        $devices = @($payload.devices)
    }

    foreach ($device in $devices) {
        if ($null -eq $device) {
            continue
        }
        $name = [string]$device.hostname
        if (-not (Test-ReservedHostnameLeftover -ReservedName $hostname -Candidate $name)) {
            continue
        }
        $deviceId = if ($device.nodeId) { [string]$device.nodeId } else { [string]$device.id }
        if ([string]::IsNullOrWhiteSpace($deviceId)) {
            continue
        }
        $identifiers = @(
            [string]$device.nodeId
            [string]$device.id
            $deviceId
        )
        if ($ExcludeId -and ($identifiers -contains $ExcludeId)) {
            continue
        }
        Invoke-TailscaleDeviceDelete -AccessToken $AccessToken -DeviceId $deviceId -DeviceName $name
    }
}

function Get-TailscaleSelfIdentity {
    param([Parameter(Mandatory = $true)][string]$Tailscale)

    $statusJson = & $Tailscale status --json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($statusJson)) {
        throw 'Tailscale did not report this node identity'
    }
    $status = $statusJson | ConvertFrom-Json
    $hostname = [string]$status.Self.HostName
    $nodeId = [string]$status.Self.ID
    if ([string]::IsNullOrWhiteSpace($hostname) -or [string]::IsNullOrWhiteSpace($nodeId)) {
        throw 'Tailscale did not report this node identity'
    }
    return @{
        HostName = $hostname
        Id = $nodeId
    }
}

function Confirm-ReservedHostname {
    param(
        [Parameter(Mandatory = $true)][string]$Tailscale,
        [Parameter(Mandatory = $true)][string]$AccessToken
    )

    $hostname = Assert-EnvironmentVariable 'TAILSCALE_HOSTNAME'
    $identity = Get-TailscaleSelfIdentity -Tailscale $Tailscale
    if ($identity.HostName -ne $hostname) {
        Invoke-ReservedHostnameReclaim -AccessToken $AccessToken -ExcludeId $identity.Id
        & $Tailscale set --hostname $hostname
        if ($LASTEXITCODE -ne 0) {
            throw "Could not claim reserved Tailscale name $hostname"
        }
        $identity = Get-TailscaleSelfIdentity -Tailscale $Tailscale
    }
    if ($identity.HostName -ne $hostname) {
        throw "Could not claim reserved Tailscale name $hostname; this node is $($identity.HostName)"
    }
    Invoke-ReservedHostnameReclaim -AccessToken $AccessToken -ExcludeId $identity.Id
}

function Install-StopSessionCommand {
    $commandDir = Join-Path $env:USERPROFILE 'bin'
    New-Item -Path $commandDir -ItemType Directory -Force | Out-Null
    $commandPath = Join-Path $commandDir 'stop-session.cmd'
    @(
        '@echo off'
        'copy /y nul "%USERPROFILE%\STOP_SESSION" >nul'
    ) | Set-Content -LiteralPath $commandPath -Encoding ascii

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $pathEntries = $userPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    }
    if ($pathEntries -notcontains $commandDir) {
        $updatedPath = if ($pathEntries.Count -eq 0) { $commandDir } else { "$commandDir;$userPath" }
        [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User')
    }
    if (($env:Path -split ';') -notcontains $commandDir) {
        $env:Path = "$commandDir;$env:Path"
    }

    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = Join-Path $env:USERPROFILE 'Desktop'
    }
    New-Item -Path $desktop -ItemType Directory -Force | Out-Null
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $desktop 'stop-session.lnk'))
    $shortcut.TargetPath = $commandPath
    $shortcut.WorkingDirectory = $commandDir
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

function Enter-CoreSession {
    Assert-OAuthSessionInput
    $accessToken = Get-TailscaleOAuthAccessToken
    Invoke-ReservedHostnameReclaim -AccessToken $accessToken

    $hostname = Assert-EnvironmentVariable 'TAILSCALE_HOSTNAME'
    $tags = Assert-EnvironmentVariable 'TAILSCALE_TAGS'
    $clientSecret = Assert-EnvironmentVariable 'TAILSCALE_OAUTH_CLIENT_SECRET'
    $authKey = "${clientSecret}?ephemeral=true&preauthorized=true"

    $tailscale = Get-TailscaleCommand
    $reusedPreinstalled = Test-Path -LiteralPath $tailscale
    if (-not $reusedPreinstalled) {
        Install-TailscalePackage
    }
    & $tailscale up --unattended --auth-key $authKey --advertise-tags $tags --hostname $hostname
    if ($LASTEXITCODE -ne 0 -and $reusedPreinstalled) {
        Install-TailscalePackage
        & $tailscale up --unattended --auth-key $authKey --advertise-tags $tags --hostname $hostname
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'Tailscale failed to join the private network'
    }
    Confirm-ReservedHostname -Tailscale $tailscale -AccessToken $accessToken
    $tailscaleIp = (& $tailscale ip -4 | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($tailscaleIp)) {
        throw 'Tailscale did not assign an IPv4 address'
    }

    Enable-CoreSession -TailscaleIp $tailscaleIp
    Install-StopSessionCommand
    Write-Output '[debug-session] Windows Core Session ready; Developer Profile provisioning may continue'
    Write-Output "RDP: $tailscaleIp`:3389"
    Write-Output "SSH: runneradmin@$tailscaleIp"
    Write-Output 'Stop Signal: run stop-session'
}

function Install-VSCodePackage {
    try {
        $os = switch (Get-WindowsNativeArch) {
            'amd64' { 'win32-x64' }
            'arm64' { 'win32-arm64' }
            'x86' { 'win32' }
        }
        $installer = Join-Path $env:TEMP "vscode-setup-$os.exe"
        try {
            Invoke-WebRequest -Uri "https://update.code.visualstudio.com/latest/$os/stable" `
                -OutFile $installer -UseBasicParsing
            $process = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
                '/verysilent', '/norestart', '/mergetasks=!runcode'
            )
            if ($process.ExitCode -notin @(0, 1641, 3010)) {
                return $false
            }
        } finally {
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
        Sync-ProcessPath
        return [bool](Get-Command code.cmd -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Install-NodeJsPackage {
    try {
        $msiArch = switch (Get-WindowsNativeArch) {
            'amd64' { 'x64' }
            'arm64' { 'arm64' }
            'x86' { 'x86' }
        }
        $releases = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json'
        $lts = $releases | Where-Object { $_.lts } | Select-Object -First 1
        if (-not $lts) {
            return $false
        }
        $version = [string]$lts.version
        $packageName = "node-$version-$msiArch.msi"
        $packageUrl = "https://nodejs.org/dist/$version/$packageName"
        $installer = Join-Path $env:TEMP $packageName
        try {
            Invoke-WebRequest -Uri $packageUrl -OutFile $installer -UseBasicParsing
            $sums = [string](Invoke-RestMethod -Uri "https://nodejs.org/dist/$version/SHASUMS256.txt")
            $expected = (
                $sums -split '\r?\n' |
                    Where-Object { $_ -match [regex]::Escape($packageName) } |
                    ForEach-Object { ($_ -split '\s+')[0] } |
                    Select-Object -First 1
            )
            $actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
            if ([string]::IsNullOrWhiteSpace($expected) -or $actual -ne $expected) {
                return $false
            }
            $process = Start-Process -FilePath msiexec.exe -Wait -PassThru -ArgumentList @(
                '/i', $installer, '/qn', '/norestart'
            )
            if ($process.ExitCode -notin @(0, 1641, 3010)) {
                return $false
            }
        } finally {
            Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
        }
        Sync-ProcessPath
        return [bool](Get-Command npm.cmd -ErrorAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Install-DeveloperProfile {
    $failed = [System.Collections.Generic.List[string]]::new()

    if (-not (Get-Command code.cmd -ErrorAction SilentlyContinue)) {
        if (-not (Install-VSCodePackage)) {
            $failed.Add('vscode')
        }
    }

    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        if (-not (Install-NodeJsPackage)) {
            $failed.Add('codex')
            $failed.Add('grok')
        }
    }
    if (Get-Command npm.cmd -ErrorAction SilentlyContinue) {
        if (-not (Get-Command codex.cmd -ErrorAction SilentlyContinue)) {
            npm install --global '@openai/codex' | Out-Host
            if ($LASTEXITCODE -ne 0) { $failed.Add('codex') }
        }
        if (-not (Get-Command grok.cmd -ErrorAction SilentlyContinue)) {
            npm install --global '@xai-official/grok' | Out-Host
            if ($LASTEXITCODE -ne 0) { $failed.Add('grok') }
        }
    }

    if ($failed.Count -gt 0) {
        Write-Warning "Developer Profile is incomplete; failed tools: $($failed -join ', ')"
    } else {
        Write-Output '[debug-session] Windows Developer Profile complete'
    }
}

function Initialize-WslUbuntu {
    $distribution = 'Ubuntu'
    $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source

    $distributions = @(& $wsl --list --quiet)
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not list installed WSL distributions'
    }
    $ubuntuInstalled = $distributions | Where-Object { $_.Trim() -eq $distribution }
    if (-not $ubuntuInstalled) {
        & $wsl --install --distribution $distribution --no-launch --web-download
        if ($LASTEXITCODE -ne 0) {
            throw 'Ubuntu installation for WSL failed'
        }
    }

    & $wsl --set-default-version 2
    if ($LASTEXITCODE -ne 0) { throw 'Could not set WSL 2 as the default version' }
    & $wsl --set-version $distribution 2
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure Ubuntu to use WSL 2' }
    & $wsl --set-default $distribution
    if ($LASTEXITCODE -ne 0) { throw 'Could not set Ubuntu as the default WSL distribution' }

    $initializeUser = @'
set -eu
if ! command -v sudo >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
fi
if ! id -u runneradmin >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash runneradmin
fi
printf '%s\n' 'runneradmin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runneradmin
chmod 0440 /etc/sudoers.d/runneradmin
printf '[user]\ndefault=runneradmin\n' > /etc/wsl.conf
'@
    & $wsl --distribution $distribution --user root --exec sh -c $initializeUser
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not initialize the runneradmin user in Ubuntu'
    }
    & $wsl --terminate $distribution
    if ($LASTEXITCODE -ne 0) { throw 'Could not restart Ubuntu after configuring its default user' }

    $defaultUser = (& $wsl --exec id -un).Trim()
    if ($LASTEXITCODE -ne 0 -or $defaultUser -ne 'runneradmin') {
        throw "WSL default-user verification failed; expected runneradmin, received '$defaultUser'"
    }
    & $wsl --exec sudo -n true
    if ($LASTEXITCODE -ne 0) { throw 'WSL passwordless sudo verification failed' }

    Write-Output '[debug-session] Ubuntu WSL Environment initialized'
}

function Wait-DebugSession {
    param([Parameter(Mandatory = $true)][long]$DeadlineEpoch)

    $stopFile = "$env:USERPROFILE\STOP_SESSION"
    $tailscale = 'C:\Program Files\Tailscale\tailscale.exe'
    $tailscaleIp = (& $tailscale ip -4 | Select-Object -First 1).Trim()
    $deadline = [DateTimeOffset]::FromUnixTimeSeconds($DeadlineEpoch).UtcDateTime

    Write-Output "RDP: $tailscaleIp`:3389"
    Write-Output "SSH: runneradmin@$tailscaleIp"
    Write-Output 'Stop Signal: run stop-session'
    Write-Output '[debug-session] Debug Session provisioning finished; waiting for the Stop Signal or Session Deadline'

    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $stopFile) {
            Write-Output '[debug-session] Stop Signal received'
            return
        }
        Start-Sleep -Seconds 15
    }
    Write-Output '[debug-session] Session Deadline reached'
}

function Test-RcloneConfigPresent {
    return -not [string]::IsNullOrWhiteSpace($env:RCLONE_CONFIG)
}

function Get-RcloneConfigPath {
    return (Join-Path $env:APPDATA 'rclone\rclone.conf')
}

function Get-RcloneCloudRoot {
    return (Join-Path $env:USERPROFILE 'cloud')
}

function Get-RcloneLogDirectory {
    return (Join-Path $env:LOCALAPPDATA 'debug-session')
}

function Get-RcloneCommand {
    $installed = Join-Path $env:LOCALAPPDATA 'debug-session\bin\rclone.exe'
    if (Test-Path -LiteralPath $installed) {
        return $installed
    }
    $existing = Get-Command rclone.exe -ErrorAction SilentlyContinue
    if ($existing) {
        return $existing.Source
    }
    return $installed
}

function Test-RcloneRemoteMountable {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq '.' -or $Name -eq '..') {
        return $false
    }
    if ($Name.Contains('/') -or $Name.Contains('\')) {
        return $false
    }
    foreach ($invalid in [IO.Path]::GetInvalidFileNameChars()) {
        if ($Name.IndexOf($invalid) -ge 0) {
            return $false
        }
    }
    return $true
}

function Write-RcloneConfigFile {
    $configPath = Get-RcloneConfigPath
    $configDir = Split-Path -Parent $configPath
    New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath $configPath -Value $env:RCLONE_CONFIG -Encoding utf8
    $acl = Get-Acl -LiteralPath $configPath
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl',
        'Allow'
    )
    $acl.SetAccessRule($rule)
    try {
        Set-Acl -LiteralPath $configPath -AclObject $acl
    } catch {
        Write-Warning "Could not restrict ACL on the rclone config file: $_"
    }
    # rclone treats RCLONE_CONFIG as a file path, not the file contents.
    $env:RCLONE_CONFIG = $configPath
}

function Get-RcloneRemoteNames {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $names = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $names
    }

    $current = $null
    $hasType = $false
    foreach ($raw in Get-Content -LiteralPath $ConfigPath) {
        $line = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) {
            continue
        }
        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            if ($current -and $hasType) {
                $names.Add($current)
            }
            $current = $line.Substring(1, $line.Length - 2).Trim()
            $hasType = $false
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -lt 0) {
            continue
        }
        $key = $line.Substring(0, $separator).Trim().ToLowerInvariant()
        if ($key -eq 'type') {
            $hasType = $true
        }
    }
    if ($current -and $hasType) {
        $names.Add($current)
    }
    return $names
}

function Get-RcloneArchiveUrl {
    $arch = Get-WindowsNativeArch
    $suffix = switch ($arch) {
        'amd64' { 'amd64' }
        'arm64' { 'arm64' }
        'x86' { '386' }
        default { throw "Unsupported Windows architecture for rclone: $arch" }
    }
    return "https://downloads.rclone.org/rclone-current-windows-$suffix.zip"
}

function Install-RclonePackage {
    $destination = Get-RcloneCommand
    if (Test-Path -LiteralPath $destination) {
        return
    }
    if (Get-Command rclone.exe -ErrorAction SilentlyContinue) {
        return
    }

    $url = Get-RcloneArchiveUrl
    $archive = Join-Path $env:TEMP 'rclone-current-windows.zip'
    $staging = Join-Path $env:TEMP ("rclone-extract-" + [guid]::NewGuid().ToString('N'))
    New-Item -Path $staging -ItemType Directory -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
        Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
        $binary = Get-ChildItem -Path $staging -Filter rclone.exe -Recurse | Select-Object -First 1
        if (-not $binary) {
            throw 'The rclone archive did not contain rclone.exe'
        }
        $binDir = Split-Path -Parent $destination
        New-Item -Path $binDir -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $binary.FullName -Destination $destination -Force

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $pathEntries = @()
        if (-not [string]::IsNullOrWhiteSpace($userPath)) {
            $pathEntries = $userPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
        }
        if ($pathEntries -notcontains $binDir) {
            $updatedPath = if ($pathEntries.Count -eq 0) { $binDir } else { "$binDir;$userPath" }
            [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User')
        }
        Sync-ProcessPath
        if (($env:Path -split ';') -notcontains $binDir) {
            $env:Path = "$binDir;$env:Path"
        }
    } finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-WinFspInstalled {
    $candidates = @(
        "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-x64.dll",
        "$env:ProgramFiles\WinFsp\bin\winfsp-x64.dll",
        "${env:ProgramFiles(x86)}\WinFsp\bin\winfsp-a64.dll",
        "$env:ProgramFiles\WinFsp\bin\winfsp-a64.dll"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $true
        }
    }
    return $false
}

function Install-WinFspPackage {
    if (Test-WinFspInstalled) {
        return
    }

    $headers = @{ 'User-Agent' = 'debug-session' }
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/winfsp/winfsp/releases/latest' -Headers $headers
    } catch {
        throw 'Could not resolve the latest WinFsp release'
    }
    $asset = @(
        $release.assets |
            Where-Object { $_.name -like 'winfsp-*.msi' -and $_.name -notlike '*symbols*' }
    ) | Select-Object -First 1
    if (-not $asset) {
        throw 'The latest WinFsp release did not publish an MSI installer'
    }

    $installer = Join-Path $env:TEMP $asset.name
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing
        $process = Start-Process -FilePath msiexec.exe -Wait -PassThru -ArgumentList @(
            '/i', $installer, '/qn', '/norestart'
        )
        if ($process.ExitCode -notin @(0, 1641, 3010)) {
            throw "WinFsp installation failed with exit code $($process.ExitCode)"
        }
    } finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}

function Wait-RcloneMount {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-Item -LiteralPath $Path -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function ConvertTo-WslWindowsPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)

    if ($WindowsPath -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest = $Matches[2].Replace('\', '/')
        return "/mnt/$drive/$rest"
    }
    return $WindowsPath
}

function Mount-RcloneRemote {
    param([Parameter(Mandatory = $true)][string]$Remote)

    $dest = Join-Path (Get-RcloneCloudRoot) $Remote
    New-Item -Path $dest -ItemType Directory -Force | Out-Null
    $logDir = Get-RcloneLogDirectory
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    $logFile = Join-Path $logDir "rclone-$Remote.log"
    $rclone = Get-RcloneCommand
    $process = Start-Process -FilePath $rclone -PassThru -WindowStyle Hidden -ArgumentList @(
        'mount', "${Remote}:", $dest,
        '--config', (Get-RcloneConfigPath),
        '--vfs-cache-mode', 'writes',
        '--log-file', $logFile
    )
    if (-not (Wait-RcloneMount -Path $dest -TimeoutSeconds 60)) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        throw "rclone mount did not become ready for $Remote"
    }
    $wslPath = ConvertTo-WslWindowsPath -WindowsPath $dest
    Write-Output "[debug-session] rclone mount ready: $dest (WSL: $wslPath)"
}

function Enable-RcloneMounts {
    if (-not (Test-RcloneConfigPresent)) {
        return
    }

    try {
        Write-RcloneConfigFile
        Install-WinFspPackage
        Install-RclonePackage
        $remotes = @(Get-RcloneRemoteNames -ConfigPath (Get-RcloneConfigPath))
        if ($remotes.Count -eq 0) {
            Write-Warning 'rclone config did not contain any mountable remotes'
            return
        }
        $mounted = 0
        foreach ($remote in $remotes) {
            if (-not (Test-RcloneRemoteMountable -Name $remote)) {
                Write-Warning "Skipping rclone remote with an unsafe name: $remote"
                continue
            }
            try {
                Mount-RcloneRemote -Remote $remote
                $mounted += 1
            } catch {
                Write-Warning "rclone mount failed for ${remote}: $_"
            }
        }
        if ($mounted -eq 0) {
            Write-Warning 'rclone cloud mounts are unavailable; the Core Session remains available'
        }
    } catch {
        Write-Warning "rclone cloud mounts are unavailable; the Core Session remains available: $_"
    }
}

function Close-RcloneMounts {
    Get-Process -Name rclone -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    $configPath = Get-RcloneConfigPath
    if (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force -ErrorAction SilentlyContinue
    }
    foreach ($cache in @(
            (Join-Path $env:LOCALAPPDATA 'rclone'),
            (Join-Path $env:USERPROFILE '.cache\rclone')
        )) {
        if (Test-Path -LiteralPath $cache) {
            Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $logDir = Get-RcloneLogDirectory
    Get-ChildItem -Path $logDir -Filter 'rclone-*.log' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Enter-DebugSession {
    $inputs = Get-ValidatedSessionInput
    Enter-CoreSession
    Enable-RcloneMounts
    if ($inputs.SessionProfile -eq 'developer') {
        Install-DeveloperProfile
    }
    if ($env:ENABLE_WSL -eq 'true') {
        try {
            Initialize-WslUbuntu
        } catch {
            Write-Warning "WSL Environment provisioning failed; the Core Session remains available: $_"
        }
    }
    Wait-DebugSession -DeadlineEpoch $inputs.Deadline
}

function Test-OAuthCleanupConfigured {
    if ([string]::IsNullOrWhiteSpace($env:TAILSCALE_OAUTH_CLIENT_ID)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($env:TAILSCALE_OAUTH_CLIENT_SECRET)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($env:TAILSCALE_HOSTNAME)) {
        return $false
    }
    return $true
}

function Close-DebugSession {
    try {
        Close-RcloneMounts
    } catch {
        Write-Warning "rclone cleanup failed; continuing Tailscale cleanup: $_"
    }

    $logoutFailed = $false
    $tailscale = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path -LiteralPath $tailscale) {
        & $tailscale status *> $null
        if ($LASTEXITCODE -eq 0) {
            & $tailscale logout
            if ($LASTEXITCODE -ne 0) {
                $logoutFailed = $true
            }
        }
    }

    if (Test-OAuthCleanupConfigured) {
        $accessToken = Get-TailscaleOAuthAccessToken
        Invoke-ReservedHostnameReclaim -AccessToken $accessToken
    }

    if ($logoutFailed) {
        throw 'Tailscale logout failed; the reserved name is removed when device delete succeeds'
    }
}

switch ($Command) {
    validate { Get-ValidatedSessionInput | Out-Null }
    run { Enter-DebugSession }
    cleanup { Close-DebugSession }
}
