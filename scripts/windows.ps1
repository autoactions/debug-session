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
    Assert-RcloneHomeLinks
    Assert-GitWorkspaces

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

function Get-WslTextLines {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][object[]]$Output)

    if ($null -eq $Output) {
        return @()
    }
    return @(
        $Output | ForEach-Object {
            $line = [string]$_
            if ($line.Contains([char]0)) {
                $line = $line.Replace([string][char]0, '')
            }
            $line.Trim()
        } | Where-Object { $_ }
    )
}

function Test-WslNoDistributionsOutput {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }
    return $Text -match 'no installed distributions' -or
        $Text -match 'WSL_E_DEFAULT_DISTRO_NOT_FOUND'
}

function Resolve-WslDistributionVersion {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowNull()][object[]]$Output,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Distribution
    )

    $lines = Get-WslTextLines -Output $Output
    $text = $lines -join "`n"
    if (Test-WslNoDistributionsOutput -Text $text) {
        return $null
    }

    foreach ($line in $lines) {
        if ($line -match '^(?:\*\s*)?(\S+)\s+\S+\s+(\d+)\s*$' -and $Matches[1] -eq $Distribution) {
            return $Matches[2]
        }
    }
    if ($ExitCode -eq 0 -or [string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    throw "Could not list installed WSL distributions: $text"
}

function Get-WslDistributionVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Wsl,
        [Parameter(Mandatory = $true)][string]$Distribution
    )

    $output = & $Wsl --list --verbose 2>&1
    return (Resolve-WslDistributionVersion -Output @($output) -ExitCode $LASTEXITCODE -Distribution $Distribution)
}

function Get-WslRootInitScript {
    return @'
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
if command -v ubuntu-insights >/dev/null 2>&1; then
    su runneradmin -c 'ubuntu-insights consent wsl_setup -s=false' >/dev/null 2>&1 || true
fi
'@
}

function Set-UbuntuInsightsConsent {
    $path = 'HKCU:\Software\Canonical\Ubuntu'
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    New-ItemProperty -Path $path -Name 'UbuntuInsightsConsent' -Value 0 -PropertyType DWord -Force | Out-Null
}

function Write-WslUnixScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Script
    )

    $unix = $Script.Replace("`r`n", "`n").Replace("`r", "`n").Trim() + "`n"
    [System.IO.File]::WriteAllText($Path, $unix, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-WslRootScript {
    param(
        [Parameter(Mandatory = $true)][string]$Wsl,
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string]$Script
    )

    $temp = Join-Path $env:TEMP 'debug-session-wsl-init.sh'
    Write-WslUnixScript -Path $temp -Script $Script
    try {
        $linuxPath = ConvertTo-WslWindowsPath -WindowsPath $temp
        & $Wsl --distribution $Distribution --user root -- /bin/true
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not start Ubuntu as root'
        }
        & $Wsl --distribution $Distribution --user root -- /bin/bash $linuxPath
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not initialize the runneradmin user in Ubuntu'
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-WslUbuntu {
    $distribution = 'Ubuntu'
    $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
    $env:WSL_UTF8 = '1'

    & $wsl --set-default-version 2
    if ($LASTEXITCODE -ne 0) { throw 'Could not set WSL 2 as the default version' }

    if ($null -eq (Get-WslDistributionVersion -Wsl $wsl -Distribution $distribution)) {
        & $wsl --install --distribution $distribution --no-launch --web-download
        if ($LASTEXITCODE -ne 0) {
            throw 'Ubuntu installation for WSL failed'
        }
    }

    if ((Get-WslDistributionVersion -Wsl $wsl -Distribution $distribution) -ne '2') {
        & $wsl --set-version $distribution 2
        if ((Get-WslDistributionVersion -Wsl $wsl -Distribution $distribution) -ne '2') {
            throw 'Could not configure Ubuntu to use WSL 2'
        }
    }
    & $wsl --set-default $distribution
    if ($LASTEXITCODE -ne 0) { throw 'Could not set Ubuntu as the default WSL distribution' }

    Set-UbuntuInsightsConsent
    Invoke-WslRootScript -Wsl $wsl -Distribution $distribution -Script (Get-WslRootInitScript)
    & $wsl --terminate $distribution
    if ($LASTEXITCODE -ne 0) { throw 'Could not restart Ubuntu after configuring its default user' }
    & $wsl --distribution $distribution /bin/true
    if ($LASTEXITCODE -ne 0) { throw 'Could not complete Ubuntu first-launch setup' }
    & $wsl --terminate $distribution
    if ($LASTEXITCODE -ne 0) { throw 'Could not restart Ubuntu after first-launch setup' }

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
    return (Join-Path $env:USERPROFILE 'rclone')
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
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $false)]$Process
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Process -and $Process.HasExited) {
            return $false
        }
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

function Initialize-RcloneWindowsMountPoint {
    param([Parameter(Mandatory = $true)][string]$Remote)

    $parent = Get-RcloneCloudRoot
    New-Item -Path $parent -ItemType Directory -Force | Out-Null
    $dest = Join-Path $parent $Remote
    if (Test-Path -LiteralPath $dest) {
        $item = Get-Item -LiteralPath $dest -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "rclone mount point already in use: $dest"
        }
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    return $dest
}

function Get-RcloneLogSummary {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 'rclone log is empty'
    }
    $lines = @(Get-Content -LiteralPath $Path -Tail 20 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) {
        return 'rclone log is empty'
    }
    return ($lines -join '; ')
}

function Mount-RcloneRemote {
    param([Parameter(Mandatory = $true)][string]$Remote)

    $dest = Initialize-RcloneWindowsMountPoint -Remote $Remote
    $logDir = Get-RcloneLogDirectory
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    $logFile = Join-Path $logDir "rclone-$Remote.log"
    $rclone = Get-RcloneCommand
    $process = Start-Process -FilePath $rclone -PassThru -WindowStyle Hidden -ArgumentList @(
        'mount', "${Remote}:", $dest,
        '--config', (Get-RcloneConfigPath),
        '--vfs-cache-mode', 'writes',
        '--log-level', 'INFO',
        '--log-file', $logFile
    )
    if (-not (Wait-RcloneMount -Path $dest -TimeoutSeconds 60 -Process $process)) {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        throw "rclone mount did not become ready for ${Remote}: $(Get-RcloneLogSummary -Path $logFile)"
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
        $launcher = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
        if ($launcher -and $launcher.Status -ne 'Running') {
            Start-Service -Name 'WinFsp.Launcher'
        }
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

function Get-RcloneWritebackWaitSeconds {
    return 120
}

function Test-RcloneProcessRunning {
    return [bool](Get-Process -Name rclone -ErrorAction SilentlyContinue)
}

function Wait-RcloneExit {
    param([Parameter(Mandatory = $true)][int]$TimeoutSeconds)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-RcloneProcessRunning)) {
            return $true
        }
        Start-Sleep -Seconds 1
    }
    return -not (Test-RcloneProcessRunning)
}

function Close-RcloneMounts {
    Get-Process -Name rclone -ErrorAction SilentlyContinue | ForEach-Object {
        & taskkill.exe /PID $_.Id 2>$null | Out-Null
    }
    if (-not (Wait-RcloneExit -TimeoutSeconds (Get-RcloneWritebackWaitSeconds))) {
        Write-Warning 'rclone did not exit after unmount; unflushed VFS writes may be lost'
        Get-Process -Name rclone -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        $null = Wait-RcloneExit -TimeoutSeconds 5
    }

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

function Test-RcloneHomeLinksPresent {
    return -not [string]::IsNullOrWhiteSpace($env:RCLONE_HOME_LINKS)
}

function Test-RcloneHomeLinkComponentValid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Part)

    if ($Part -notmatch '^[A-Za-z0-9._][A-Za-z0-9._-]*$') {
        return $false
    }
    if ($Part -eq '.' -or $Part -eq '..') {
        return $false
    }
    return $true
}

function Test-RcloneHomeLinkTargetValid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $false
    }
    if ($Target.StartsWith('/') -or $Target.Contains('\') -or $Target -match '\s') {
        return $false
    }
    $parts = @($Target.Split('/'))
    if ($parts.Count -lt 1 -or $parts.Count -gt 8) {
        return $false
    }
    foreach ($part in $parts) {
        if (-not (Test-RcloneHomeLinkComponentValid -Part $part)) {
            return $false
        }
    }
    if ($parts[0] -eq 'rclone') {
        return $false
    }
    return $true
}

function Test-RcloneHomeLinkTargetsConflict {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return ($Left -eq $Right -or $Left.StartsWith("$Right/") -or $Right.StartsWith("$Left/"))
}

function Test-RcloneHomeLinkSourceValid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) {
        return $false
    }
    if ($Source.StartsWith('/') -or $Source.Contains('\') -or $Source -match '\s') {
        return $false
    }
    foreach ($part in $Source.Split('/')) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.' -or $part -eq '..') {
            return $false
        }
    }
    return $true
}

function Get-RcloneHomeLinks {
    $links = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $lineno = 0
    foreach ($raw in ($env:RCLONE_HOME_LINKS -split '\r?\n', [StringSplitOptions]::None)) {
        $lineno += 1
        $line = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -lt 0) {
            throw "RCLONE_HOME_LINKS line $lineno is missing ="
        }
        $target = $line.Substring(0, $separator).Trim()
        $source = $line.Substring($separator + 1).Trim()
        $targetDir = $target.EndsWith('/')
        $sourceDir = $source.EndsWith('/')
        $target = $target.TrimEnd('/')
        $source = $source.TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($source)) {
            throw "RCLONE_HOME_LINKS source is invalid: $source"
        }
        if ($targetDir -ne $sourceDir) {
            throw "RCLONE_HOME_LINKS directory marker mismatch: $target=$source"
        }
        $kind = if ($targetDir) { 'dir' } else { 'file' }
        if (-not (Test-RcloneHomeLinkTargetValid -Target $target)) {
            throw "RCLONE_HOME_LINKS target is invalid: $target"
        }
        if (-not (Test-RcloneHomeLinkSourceValid -Source $source)) {
            throw "RCLONE_HOME_LINKS source is invalid: $source"
        }
        if ($seen.ContainsKey($target)) {
            throw "RCLONE_HOME_LINKS has a duplicate target: $target"
        }
        foreach ($existing in @($seen.Keys)) {
            if (Test-RcloneHomeLinkTargetsConflict -Left $existing -Right $target) {
                throw "RCLONE_HOME_LINKS target conflicts with ${existing}: $target"
            }
        }
        $seen[$target] = $true
        $links.Add([pscustomobject]@{ Target = $target; Source = $source; Kind = $kind })
    }
    return $links
}

function Assert-RcloneHomeLinks {
    if (-not (Test-RcloneHomeLinksPresent)) {
        return
    }
    $null = Get-RcloneHomeLinks
}

function Test-RcloneMountIsLive {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Test-RcloneHasLiveMounts {
    $root = Get-RcloneCloudRoot
    if (-not (Test-Path -LiteralPath $root)) {
        return $false
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
        if ($dir.PSIsContainer -and (Test-RcloneMountIsLive -Path $dir.FullName)) {
            return $true
        }
    }
    return $false
}

function Test-DirectoryIsEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)

    return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -eq 0
}

function ConvertTo-RcloneHomeLinkSourcePath {
    param([Parameter(Mandatory = $true)][string]$Source)

    return ('rclone\' + ($Source -replace '/', '\'))
}

function ConvertTo-RcloneHomeLinkRelativeTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    $parent = [IO.Path]::GetFullPath((Split-Path -Parent $Destination)).TrimEnd('\')
    $prefix = ''
    if ($parent.StartsWith($profileRoot, [StringComparison]::OrdinalIgnoreCase) -and $parent.Length -gt $profileRoot.Length) {
        $suffix = $parent.Substring($profileRoot.Length).TrimStart('\')
        $depth = @($suffix.Split('\') | Where-Object { $_ }).Count
        if ($depth -gt 0) {
            $prefix = ('..\' * $depth)
        }
    }
    return ($prefix + (ConvertTo-RcloneHomeLinkSourcePath -Source $Source))
}

function Test-HomeLinkRelativeTargetValid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$RelativeTarget)

    $normalized = $RelativeTarget -replace '/', '\'
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }
    if ($normalized.StartsWith('\') -or $normalized -match '^[A-Za-z]:') {
        return $false
    }
    $seenRclone = $false
    foreach ($part in $normalized.Split('\')) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.') {
            return $false
        }
        if ($part -eq '..') {
            if ($seenRclone) {
                return $false
            }
            continue
        }
        if (-not $seenRclone) {
            if ($part -ne 'rclone') {
                return $false
            }
            $seenRclone = $true
            continue
        }
    }
    return $seenRclone
}

function Test-HomeLinkAncestorsAreLocal {
    param([Parameter(Mandatory = $true)][string]$Destination)

    $profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    $cursor = Split-Path -Parent $Destination
    while ($cursor) {
        $normalized = [IO.Path]::GetFullPath($cursor).TrimEnd('\')
        if ($normalized.Equals($profileRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if (-not $item) {
            return $false
        }
        if ($item.LinkType -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            return $false
        }
        if (-not $item.PSIsContainer) {
            return $false
        }
        $next = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($next) -or $next.Equals($cursor, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        $cursor = $next
    }
    return $true
}

function Resolve-HomeLinkAbsoluteTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$RelativeTarget
    )

    $normalized = $RelativeTarget -replace '/', '\'
    $parent = Split-Path -Parent $Destination
    return [IO.Path]::GetFullPath((Join-Path $parent $normalized))
}

function Test-HomeLinkMatches {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$RelativeTarget
    )

    if (-not $Item.LinkType) {
        return $false
    }
    $normalized = $RelativeTarget -replace '/', '\'
    $absolute = Resolve-HomeLinkAbsoluteTarget -Destination $Destination -RelativeTarget $RelativeTarget
    $current = (@($Item.Target)[0] -replace '/', '\')
    if ([string]::IsNullOrWhiteSpace($current)) {
        return $false
    }
    if ($current -eq $normalized) {
        return $true
    }
    try {
        return ([IO.Path]::GetFullPath($current) -eq $absolute)
    } catch {
        return $false
    }
}

function Ensure-RcloneHomeLinkSource {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AsFile
    )

    $parent = Split-Path -Parent $Path
    New-Item -Path $parent -ItemType Directory -Force | Out-Null
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($AsFile -and $item.PSIsContainer -and (Test-DirectoryIsEmpty -Path $Path)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            New-Item -Path $Path -ItemType File -Force | Out-Null
        }
        return
    }
    if ($AsFile) {
        New-Item -Path $Path -ItemType File -Force | Out-Null
        return
    }
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
}

function New-HomeLink {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$RelativeTarget,
        [switch]$AsFile
    )

    $normalized = $RelativeTarget -replace '/', '\'
    $absolute = Resolve-HomeLinkAbsoluteTarget -Destination $Destination -RelativeTarget $RelativeTarget
    $errors = [System.Collections.Generic.List[string]]::new()

    try {
        New-Item -ItemType SymbolicLink -Path $Destination -Target $normalized -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $errors.Add("symlink: $_")
    }
    if (-not $AsFile) {
        try {
            New-Item -ItemType Junction -Path $Destination -Target $absolute -ErrorAction Stop | Out-Null
            return $true
        } catch {
            $errors.Add("junction: $_")
        }
        $mklink = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList @(
            '/c', 'mklink', '/J', $Destination, $absolute
        ) -Wait -PassThru -WindowStyle Hidden
        if ($mklink.ExitCode -eq 0) {
            return $true
        }
        $errors.Add("mklink /J exit $($mklink.ExitCode)")
    } else {
        $mklink = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList @(
            '/c', 'mklink', $Destination, $normalized
        ) -Wait -PassThru -WindowStyle Hidden
        if ($mklink.ExitCode -eq 0) {
            return $true
        }
        $errors.Add("mklink exit $($mklink.ExitCode)")
    }
    Write-Warning ("Could not create home link {0} ({1})" -f $Destination, ($errors -join '; '))
    return $false
}

function Install-HomeSymlink {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$RelativeTarget,
        [switch]$AsFile
    )

    $normalized = $RelativeTarget -replace '/', '\'
    if (-not (Test-HomeLinkRelativeTargetValid -RelativeTarget $normalized)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    if ($item) {
        if ($item.LinkType) {
            if (Test-HomeLinkMatches -Item $item -Destination $Destination -RelativeTarget $normalized) {
                return $true
            }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
        } elseif ($item.PSIsContainer) {
            if (-not (Test-DirectoryIsEmpty -Path $Destination)) {
                return $false
            }
            Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
        } else {
            return $false
        }
    }

    return (New-HomeLink -Destination $Destination -RelativeTarget $normalized -AsFile:$AsFile)
}

function Add-RcloneHomeLink {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$Kind = 'dir'
    )

    $dest = $env:USERPROFILE
    foreach ($part in $Target.Split('/')) {
        $dest = Join-Path $dest $part
    }
    $srcPath = $env:USERPROFILE
    foreach ($part in (ConvertTo-RcloneHomeLinkSourcePath -Source $Source).Split('\')) {
        $srcPath = Join-Path $srcPath $part
    }
    $rel = ConvertTo-RcloneHomeLinkRelativeTarget -Source $Source -Destination $dest
    $first = ($Source -split '/')[0]
    $mount = Join-Path (Get-RcloneCloudRoot) $first
    $parent = Split-Path -Parent $dest

    if (-not (Test-RcloneMountIsLive -Path $mount)) {
        Write-Warning "Skipping home link ${Target}: rclone remote $first is not mounted"
        return
    }
    $asFile = $Kind -eq 'file'
    try {
        Ensure-RcloneHomeLinkSource -Path $srcPath -AsFile:$asFile
    } catch {
        Write-Warning "Skipping home link ${Target}: could not create $srcPath"
        return
    }
    $srcItem = Get-Item -LiteralPath $srcPath -Force -ErrorAction SilentlyContinue
    if (-not $srcItem) {
        Write-Warning "Skipping home link ${Target}: source is not a file or directory"
        return
    }
    if ($asFile) {
        if ($srcItem.PSIsContainer) {
            Write-Warning "Skipping home link ${Target}: source is a directory but the mapping is a file"
            return
        }
    } elseif (-not $srcItem.PSIsContainer) {
        Write-Warning "Skipping home link ${Target}: source is not a directory"
        return
    }
    try {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    } catch {
        Write-Warning "Skipping home link ${Target}: could not create parent $parent"
        return
    }
    if (-not (Test-HomeLinkAncestorsAreLocal -Destination $dest)) {
        Write-Warning "Skipping home link ${Target}: parent is not a local directory"
        return
    }
    if (Install-HomeSymlink -Destination $dest -RelativeTarget $rel -AsFile:$asFile) {
        Write-Output "[debug-session] home link ready: $dest -> $rel"
        return
    }
    Write-Warning "Skipping home link ${Target}: $dest already exists or could not be replaced"
}

function Enable-RcloneHomeLinks {
    if (-not (Test-RcloneHomeLinksPresent)) {
        Write-Output '[debug-session] RCLONE_HOME_LINKS is empty; skipping home links'
        return
    }
    if (-not (Test-RcloneHasLiveMounts)) {
        Write-Warning 'RCLONE_HOME_LINKS is set but rclone mounts are unavailable; skipping home links'
        return
    }

    try {
        $links = @(Get-RcloneHomeLinks)
    } catch {
        Write-Warning "RCLONE_HOME_LINKS is invalid after validate; skipping home links"
        return
    }
    Write-Output "[debug-session] applying $($links.Count) rclone home link(s)"
    foreach ($link in $links) {
        Add-RcloneHomeLink -Target $link.Target -Source $link.Source -Kind $link.Kind
    }
}

function Test-GitWorkspacesPresent {
    return -not [string]::IsNullOrWhiteSpace($env:GIT_WORKSPACES)
}

function Get-GitWorkspaceRoot {
    return (Join-Path $env:USERPROFILE 'workspaces')
}

function Test-GitWorkspaceNameComponentValid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Part)

    if ($Part -notmatch '^[A-Za-z0-9._][A-Za-z0-9._-]*$') {
        return $false
    }
    if ($Part -eq '.' -or $Part -eq '..') {
        return $false
    }
    return $true
}

function Test-GitWorkspaceNameValid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    if ($Name.StartsWith('/') -or $Name.EndsWith('/') -or $Name.Contains('//')) {
        return $false
    }
    $parts = @($Name.Split('/'))
    if ($parts.Count -lt 1 -or $parts.Count -gt 8) {
        return $false
    }
    foreach ($part in $parts) {
        if (-not (Test-GitWorkspaceNameComponentValid -Part $part)) {
            return $false
        }
    }
    return $true
}

function Test-GitWorkspaceNamesConflict {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return ($Left -eq $Right -or $Left.StartsWith("$Right/") -or $Right.StartsWith("$Left/"))
}

function Test-GitWorkspaceUrlValid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Url)

    return [bool]($Url -match '^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~-]+)+$')
}

function Test-GitWorkspaceShorthandValid {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Spec)

    if ([string]::IsNullOrWhiteSpace($Spec)) {
        return $false
    }
    if ($Spec.StartsWith('/') -or $Spec.EndsWith('/') -or $Spec.Contains('//') -or -not $Spec.Contains('/')) {
        return $false
    }
    $parts = @($Spec.Split('/'))
    if ($parts.Count -ne 2) {
        return $false
    }
    $repo = $parts[1]
    if ($repo.EndsWith('.git')) {
        $repo = $repo.Substring(0, $repo.Length - 4)
    }
    return (Test-GitWorkspaceNameComponentValid -Part $parts[0]) -and
        (Test-GitWorkspaceNameComponentValid -Part $repo)
}

function ConvertTo-GitWorkspaceUrlFromShorthand {
    param([Parameter(Mandatory = $true)][string]$Spec)

    return "https://github.com/$Spec"
}

function ConvertTo-GitWorkspaceNameFromShorthand {
    param([Parameter(Mandatory = $true)][string]$Spec)

    if ($Spec.EndsWith('.git')) {
        return $Spec.Substring(0, $Spec.Length - 4)
    }
    return $Spec
}

function ConvertTo-GitWorkspaceNameFromUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $rest = $Url.Substring('https://'.Length)
    $slash = $rest.IndexOf('/')
    if ($slash -lt 0) {
        return ''
    }
    $name = $rest.Substring($slash + 1)
    if ($name.EndsWith('.git')) {
        $name = $name.Substring(0, $name.Length - 4)
    }
    return $name
}

function Get-GitWorkspaces {
    $workspaces = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $lineno = 0
    foreach ($raw in ($env:GIT_WORKSPACES -split '\r?\n', [StringSplitOptions]::None)) {
        $lineno += 1
        $line = $raw.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }

        $name = ''
        $url = ''
        if ($line -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
            $url = $line
        } elseif ($line.Contains('=')) {
            $separator = $line.IndexOf('=')
            $name = $line.Substring(0, $separator).Trim()
            $url = $line.Substring($separator + 1).Trim()
        } elseif (Test-GitWorkspaceShorthandValid -Spec $line) {
            $url = $line
        } else {
            throw "GIT_WORKSPACES line $lineno is missing a URL"
        }

        $url = $url.TrimEnd('/')
        if (Test-GitWorkspaceShorthandValid -Spec $url) {
            if ([string]::IsNullOrWhiteSpace($name)) {
                $name = ConvertTo-GitWorkspaceNameFromShorthand -Spec $url
            }
            $url = ConvertTo-GitWorkspaceUrlFromShorthand -Spec $url
        } elseif (-not (Test-GitWorkspaceUrlValid -Url $url)) {
            throw "GIT_WORKSPACES URL is invalid: $url"
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = ConvertTo-GitWorkspaceNameFromUrl -Url $url
        }
        if (-not (Test-GitWorkspaceNameValid -Name $name)) {
            throw "GIT_WORKSPACES name is invalid: $name"
        }
        if ($seen.ContainsKey($name)) {
            throw "GIT_WORKSPACES has a duplicate name: $name"
        }
        foreach ($existing in @($seen.Keys)) {
            if (Test-GitWorkspaceNamesConflict -Left $existing -Right $name) {
                throw "GIT_WORKSPACES name conflicts with ${existing}: $name"
            }
        }
        $seen[$name] = $true
        $workspaces.Add([pscustomobject]@{ Name = $name; Url = $url })
    }
    return $workspaces
}

function Assert-GitWorkspaces {
    if (-not (Test-GitWorkspacesPresent)) {
        return
    }
    $null = Get-GitWorkspaces
}

function Get-GitWorkspaceCredentialHelper {
    return '!f() { echo username=x-access-token; echo password=$GIT_WORKSPACES_TOKEN; }; f'
}

function Test-GitAvailable {
    return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Add-GitWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $dest = Get-GitWorkspaceRoot
    foreach ($part in $Name.Split('/')) {
        $dest = Join-Path $dest $part
    }
    if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
        Write-Output "[debug-session] git workspace already present: $dest"
        return
    }
    if (Test-Path -LiteralPath $dest) {
        Write-Warning "Skipping git workspace ${Name}: $dest already exists"
        return
    }

    $parent = Split-Path -Parent $dest
    try {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    } catch {
        Write-Warning "Skipping git workspace ${Name}: could not create $parent"
        return
    }

    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    $env:GIT_TERMINAL_PROMPT = '0'
    $gitArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($env:GIT_WORKSPACES_TOKEN)) {
        $gitArgs += @('-c', 'credential.helper=', '-c', ('credential.helper=' + (Get-GitWorkspaceCredentialHelper)))
    }
    $gitArgs += @('clone', '--depth=1', '--', $Url, $dest)
    & git @gitArgs
    $cloneFailed = $LASTEXITCODE -ne 0
    if ($null -ne $previousPrompt) {
        $env:GIT_TERMINAL_PROMPT = $previousPrompt
    } else {
        Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    }
    if (-not $cloneFailed) {
        Write-Output "[debug-session] git workspace ready: $dest"
        return
    }
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Warning "git clone failed for $Name"
}

function Enable-GitWorkspaces {
    if (-not (Test-GitWorkspacesPresent)) {
        return
    }
    if (-not (Test-GitAvailable)) {
        Write-Warning 'git is unavailable; skipping git workspaces'
        return
    }

    try {
        $workspaces = @(Get-GitWorkspaces)
    } catch {
        Write-Warning 'GIT_WORKSPACES is invalid after validate; skipping git workspaces'
        return
    }

    foreach ($workspace in $workspaces) {
        Add-GitWorkspace -Name $workspace.Name -Url $workspace.Url
    }
}

function Enter-DebugSession {
    $inputs = Get-ValidatedSessionInput
    Enter-CoreSession
    Enable-RcloneMounts
    Enable-RcloneHomeLinks
    Enable-GitWorkspaces
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
