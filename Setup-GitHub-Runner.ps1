[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$ProjectPath = '',
    [string]$Repo = '',
    [string]$KeystorePath = '',
    [string]$KeyAlias = '',
    [string]$ExpectedCertificateSha256 = '',
    [string]$RunnerDir = '',
    [string]$RunnerLabel = '',
    [string]$RunnerName = '',
    [switch]$SkipSecrets,
    [switch]$SkipRunner,
    [switch]$InstallWorkflow,
    [switch]$RegisterLogonTask,
    [switch]$NonInteractive,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'tools\Common.ps1')

function Confirm-UserAction {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($NonInteractive) {
        return $false
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $result = [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        $ans = Read-Host "$Message [y/N]"
        return ($ans -match '^(y|yes)$')
    }
}

function Refresh-ProcessPathFromRegistry {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($scope in @('Machine', 'User')) {
        try {
            $val = [Environment]::GetEnvironmentVariable('Path', $scope)
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                foreach ($item in ($val -split ';')) {
                    if (-not [string]::IsNullOrWhiteSpace($item)) { $parts.Add($item.Trim()) }
                }
            }
        } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PATH)) {
        foreach ($item in ($env:PATH -split ';')) {
            if (-not [string]::IsNullOrWhiteSpace($item)) { $parts.Add($item.Trim()) }
        }
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        if ($seen.Add($p)) { $unique.Add($p) }
    }
    $env:PATH = ($unique -join ';')
}

function Find-GitHubCliPath {
    Refresh-ProcessPathFromRegistry
    $cmd = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $cmd.Source).Path
    }
    $defaultPaths = @(
        'C:\Program Files\GitHub CLI\gh.exe',
        (Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'),
        (Join-Path $env:ProgramW6432 'GitHub CLI\gh.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'GitHub CLI\gh.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\GitHub CLI\gh.exe')
    )
    foreach ($p in $defaultPaths) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    return $null
}

function Install-GitHubCliWithConsent {
    $approved = Confirm-UserAction `
        -Title 'Install GitHub CLI (gh)' `
        -Message "GitHub CLI (gh.exe) was not detected on this PC.`n`nDo you authorize downloading and installing the official GitHub CLI MSI (verified by SHA-256) from github.com/cli/cli?"
    if (-not $approved) {
        throw 'GitHub CLI (gh) is required for automatic Secrets & Runner setup, and installation was declined.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host 'Querying latest official GitHub CLI release (cli/cli)...'
    $release = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -Headers @{ 'User-Agent' = 'Unity-Android-AAB-Workflow' }
    $msiAsset = $release.assets | Where-Object { $_.name -match '^gh_[0-9.]+_windows_amd64\.msi$' } | Select-Object -First 1
    $sumAsset = $release.assets | Where-Object { $_.name -match '^gh_[0-9.]+_checksums\.txt$' } | Select-Object -First 1
    if ($null -eq $msiAsset -or $null -eq $sumAsset) {
        throw 'Could not locate windows_amd64 MSI or checksums.txt in cli/cli latest release.'
    }

    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('gh-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $msiPath = Join-Path $tmpDir $msiAsset.name
    $sumPath = Join-Path $tmpDir $sumAsset.name
    try {
        Write-Host "Downloading $($msiAsset.name) ($($msiAsset.size) bytes)..."
        Invoke-WebRequest -Uri $sumAsset.browser_download_url -OutFile $sumPath -UseBasicParsing
        Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $msiPath -UseBasicParsing

        $sumLines = Get-Content -LiteralPath $sumPath -Encoding UTF8
        $expectedSha = ''
        foreach ($line in $sumLines) {
            if ($line -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($msiAsset.name) + '$')) {
                $expectedSha = $Matches[1].ToUpperInvariant()
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($expectedSha)) {
            throw "Expected SHA-256 entry for $($msiAsset.name) not found in $($sumAsset.name)"
        }
        $actualSha = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualSha -cne $expectedSha) {
            throw "GitHub CLI MSI SHA-256 mismatch! expected=$expectedSha actual=$actualSha"
        }
        Write-Host "Verified official GitHub CLI MSI SHA-256: $actualSha"
        Write-Host 'Installing GitHub CLI...'
        $msiArgs = Format-WindowsArgumentString -Arguments @('/i', $msiPath, '/passive', '/norestart')
        $msiProc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -PassThru -Wait
        if ($msiProc.ExitCode -notin @(0, 3010)) {
            throw "GitHub CLI MSI installation failed with exit code $($msiProc.ExitCode)."
        }
    } finally {
        if (Test-Path -LiteralPath $tmpDir -PathType Container) {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $installedGh = $null
    for ($waitIdx = 0; $waitIdx -lt 15; $waitIdx++) {
        $installedGh = Find-GitHubCliPath
        if (-not [string]::IsNullOrWhiteSpace($installedGh)) { break }
        Start-Sleep -Seconds 1
    }
    if ([string]::IsNullOrWhiteSpace($installedGh)) {
        throw 'GitHub CLI installation finished, but gh.exe was not found on disk. Reopen terminal or check Program Files\GitHub CLI.'
    }
    $ghDir = Split-Path -Parent $installedGh
    if ($env:PATH -notlike "*$ghDir*") {
        $env:PATH = "$ghDir;$env:PATH"
    }
    Write-Host "GitHub CLI ready: $installedGh"
    return $installedGh
}

function Set-GitHubSecretFromStdin {
    param(
        [Parameter(Mandatory = $true)][string]$GhExe,
        [Parameter(Mandatory = $true)][string]$TargetRepo,
        [Parameter(Mandatory = $true)][string]$SecretName,
        [Parameter(Mandatory = $true)][string]$SecretValue
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $GhExe
    $psi.Arguments = Format-WindowsArgumentString -Arguments @('secret', 'set', $SecretName, '--repo', $TargetRepo)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($SecretValue)
        $proc.StandardInput.Close()
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            throw "gh secret set $SecretName failed (ExitCode=$($proc.ExitCode)): $err $out"
        }
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

# 1. Resolve target Unity project & GitHub repository (generic direct input, zero preset list)
$explicitRepo = -not [string]::IsNullOrWhiteSpace($Repo)
$explicitKs = -not [string]::IsNullOrWhiteSpace($KeystorePath)
$explicitAlias = -not [string]::IsNullOrWhiteSpace($KeyAlias)
$explicitRunnerDir = -not [string]::IsNullOrWhiteSpace($RunnerDir)

if ([string]::IsNullOrWhiteSpace($ConfigPath) -and [string]::IsNullOrWhiteSpace($ProjectPath)) {
    if ($NonInteractive) {
        throw 'Provide -ProjectPath (or -ConfigPath) when running with -NonInteractive.'
    }
    Write-Host ''
    Write-Host '=== 选择目标 Unity 工程 ==='
    $ProjectPath = Prompt-DirectoryOrBrowse `
        -PromptText '请输入 Unity 工程根目录路径（直接回车打开文件夹选择框）' `
        -DialogDescription '选择 Unity 工程根目录（包含 Assets 和 ProjectSettings）'
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) { return }
}

if ([string]::IsNullOrWhiteSpace($ConfigPath) -and -not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $matchedLocal = Find-LocalConfigForProject -ToolRoot $PSScriptRoot -ProjectPath $ProjectPath
    if (-not [string]::IsNullOrWhiteSpace($matchedLocal)) {
        $ConfigPath = $matchedLocal
    }
}

$cfg = $null
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Config file not found: $ConfigPath"
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

$signCfg = Get-ConfigProperty -Object $cfg -Name 'signing'
$relCfg = Get-ConfigProperty -Object $cfg -Name 'release'

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = [string](Get-ConfigProperty -Object $cfg -Name 'projectPath' -Default '')
}

$releaseJsonRel = [string](Get-ConfigProperty -Object $cfg -Name 'releaseJsonPath' -Default '')
$meta = Read-UnityProjectMetadata -ProjectPath $ProjectPath -ReleaseJsonRelativePath $releaseJsonRel
$projectName = [string](Get-ConfigProperty -Object $cfg -Name 'projectName' -Default $meta.ProjectName)
$slug = ($projectName -replace '[^A-Za-z0-9_-]', '').ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'unity-app' }

if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = [string](Get-ConfigProperty -Object $relCfg -Name 'githubRepo' -Default '')
}
if ([string]::IsNullOrWhiteSpace($Repo)) {
    $Repo = Resolve-GitHubRepoFromProject -ProjectPath $meta.ProjectPath
}
if (-not $explicitRepo -and -not $NonInteractive -and -not $DryRun) {
    $repoPrompt = if ([string]::IsNullOrWhiteSpace($Repo)) {
        '请输入 GitHub 仓库 (格式 owner/repo)'
    } else {
        "请输入 GitHub 仓库 (owner/repo，回车默认: $Repo)"
    }
    $inRepo = (Read-Host $repoPrompt).Trim()
    if (-not [string]::IsNullOrWhiteSpace($inRepo)) { $Repo = $inRepo }
}
if ($Repo -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$') {
    throw "Invalid GitHub repository '$Repo'. Expected format: owner/repo."
}

if ([string]::IsNullOrWhiteSpace($KeystorePath)) {
    $KeystorePath = [string](Get-ConfigProperty -Object $signCfg -Name 'keystorePath' -Default '')
}
if ([string]::IsNullOrWhiteSpace($KeystorePath)) {
    $KeystorePath = Join-Path $env:USERPROFILE ".unity-aab-keys\$slug-upload.p12"
}
if (-not $explicitKs -and -not $NonInteractive -and -not $DryRun) {
    $inKs = (Read-Host "请输入上传密钥库 .p12 路径 (回车默认: $KeystorePath)").Trim().Trim('"', "'")
    if (-not [string]::IsNullOrWhiteSpace($inKs)) { $KeystorePath = $inKs }
}

if ([string]::IsNullOrWhiteSpace($KeyAlias)) {
    $KeyAlias = [string](Get-ConfigProperty -Object $signCfg -Name 'keyAlias' -Default '')
}
if ([string]::IsNullOrWhiteSpace($KeyAlias)) {
    $KeyAlias = "$slug-upload"
}
if (-not $explicitAlias -and -not $NonInteractive -and -not $DryRun) {
    $inAlias = (Read-Host "请输入密钥库 Key Alias (回车默认: $KeyAlias)").Trim()
    if (-not [string]::IsNullOrWhiteSpace($inAlias)) { $KeyAlias = $inAlias }
}

if ([string]::IsNullOrWhiteSpace($ExpectedCertificateSha256)) {
    $ExpectedCertificateSha256 = [string](Get-ConfigProperty -Object $signCfg -Name 'expectedCertificateSha256' -Default '')
}

if ([string]::IsNullOrWhiteSpace($RunnerDir)) {
    $runnerBase = if (Test-Path -LiteralPath 'D:\actions-runner' -PathType Container) {
        'D:\actions-runner'
    } else {
        Join-Path $env:SystemDrive 'actions-runner'
    }
    $RunnerDir = Join-Path $runnerBase $slug
}
if (-not $explicitRunnerDir -and -not $NonInteractive -and -not $DryRun) {
    $inRunner = (Read-Host "请输入本机 Runner 安装目录 (回车默认: $RunnerDir)").Trim().Trim('"', "'")
    if (-not [string]::IsNullOrWhiteSpace($inRunner)) { $RunnerDir = $inRunner }
}

if ([string]::IsNullOrWhiteSpace($RunnerLabel)) {
    $RunnerLabel = "unity-$slug"
}
if ([string]::IsNullOrWhiteSpace($RunnerName)) {
    $RunnerName = "$($env:COMPUTERNAME)-$slug-unity"
}

Write-Host ''
Write-Host '=== GitHub Self-Hosted AAB Setup Summary ==='
Write-Host "Project     : $projectName ($($meta.ProjectPath))"
Write-Host "Repository  : $Repo"
Write-Host "Keystore    : $KeystorePath (alias: $KeyAlias)"
Write-Host "RunnerDir   : $RunnerDir (label: $RunnerLabel)"

if ($DryRun) {
    Write-Host '[DryRun] Validated target metadata and setup plan cleanly.'
    return [PSCustomObject]@{
        DryRun       = $true
        ProjectName  = $projectName
        ProjectPath  = $meta.ProjectPath
        Repo         = $Repo
        KeystorePath = $KeystorePath
        KeyAlias     = $KeyAlias
        RunnerDir    = $RunnerDir
        RunnerLabel  = $RunnerLabel
    }
}

# 2. Ensure GitHub CLI (gh) is installed and authenticated
$gh = Find-GitHubCliPath
if ([string]::IsNullOrWhiteSpace($gh)) {
    $gh = Install-GitHubCliWithConsent
}

$authCheckOk = $true
try {
    $null = Invoke-ExternalProcessChecked -FilePath $gh -ArgumentList @('auth', 'status', '--hostname', 'github.com') -TimeoutSeconds 30
} catch {
    $authCheckOk = $false
}
if (-not $authCheckOk) {
    Write-Host 'Opening browser to authorize GitHub CLI (repo + workflow scopes)...'
    & $gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web --clipboard --scopes repo,workflow
    if ($LASTEXITCODE -ne 0) {
        throw 'GitHub CLI authentication failed.'
    }
}

# 3. Upload the 4 Android signing Secrets securely
if (-not $SkipSecrets) {
    $unityEditor = Find-UnityEditor -EditorVersion $meta.EditorVersion
    $tools = Find-AndroidPlayerTools -UnityEditorPath $unityEditor -EditorVersion $meta.EditorVersion

    $pwEnv = '_UNITY_AAB_SETUP_PW_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $tempCert = Join-Path ([IO.Path]::GetTempPath()) ('aab-setup-cert-' + [Guid]::NewGuid().ToString('N') + '.der')
    $ksB64 = ''
    $pwPlain = ''

    try {
        if (-not (Test-Path -LiteralPath $KeystorePath -PathType Leaf)) {
            $genOk = Confirm-UserAction `
                -Title 'Generate Upload Keystore' `
                -Message "Keystore not found at:`n$KeystorePath`n`nGenerate a new PKCS12 upload keystore now?"
            if (-not $genOk) {
                throw "Missing keystore at $KeystorePath"
            }
            $null = & (Join-Path $PSScriptRoot 'Sign-Aab.ps1') -GenerateKeystore -KeystorePath $KeystorePath -KeyAlias $KeyAlias
        }

        $presetPw = [Environment]::GetEnvironmentVariable('UNITY_AAB_STORE_PASSWORD')
        if (-not [string]::IsNullOrEmpty($presetPw)) {
            $pwPlain = $presetPw
        } else {
            $sec = Read-Host "Enter keystore password for '$KeyAlias' (input hidden)" -AsSecureString
            $pwPlain = ([Net.NetworkCredential]::new('', $sec)).Password
            $sec.Dispose()
            if ([string]::IsNullOrEmpty($pwPlain)) {
                throw 'Keystore password cannot be empty.'
            }
        }
        [Environment]::SetEnvironmentVariable($pwEnv, $pwPlain)

        $null = Invoke-ExternalProcessChecked -FilePath $tools.KeytoolExe -ArgumentList @(
            '-exportcert',
            '-keystore', (Resolve-Path -LiteralPath $KeystorePath).Path,
            '-storepass:env', $pwEnv,
            '-alias', $KeyAlias,
            '-file', $tempCert
        ) -TimeoutSeconds 60
        $actualCertSha = (Get-FileHash -LiteralPath $tempCert -Algorithm SHA256).Hash.ToUpperInvariant()

        if (-not [string]::IsNullOrWhiteSpace($ExpectedCertificateSha256)) {
            $expectedNorm = Normalize-Sha256Hex -Raw $ExpectedCertificateSha256
            if ($actualCertSha -cne $expectedNorm) {
                throw "Certificate SHA-256 mismatch! expected=$expectedNorm actual=$actualCertSha"
            }
        }

        $ksBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $KeystorePath).Path)
        $ksB64 = [Convert]::ToBase64String($ksBytes)
        [Array]::Clear($ksBytes, 0, $ksBytes.Length)

        Write-Host "Uploading 4 encrypted Android signing Secrets to $Repo..."
        Set-GitHubSecretFromStdin -GhExe $gh -TargetRepo $Repo -SecretName 'ANDROID_UPLOAD_KEYSTORE_BASE64' -SecretValue $ksB64
        Set-GitHubSecretFromStdin -GhExe $gh -TargetRepo $Repo -SecretName 'ANDROID_UPLOAD_KEYSTORE_PASSWORD' -SecretValue $pwPlain
        Set-GitHubSecretFromStdin -GhExe $gh -TargetRepo $Repo -SecretName 'ANDROID_UPLOAD_KEY_ALIAS' -SecretValue $KeyAlias
        Set-GitHubSecretFromStdin -GhExe $gh -TargetRepo $Repo -SecretName 'ANDROID_UPLOAD_CERT_SHA256' -SecretValue $actualCertSha
        Write-Host "[OK] Uploaded all 4 Secrets to $Repo (Cert SHA-256: $actualCertSha)"
    } finally {
        [Environment]::SetEnvironmentVariable($pwEnv, $null)
        $ksB64 = ''
        $pwPlain = ''
        Wipe-FileSecurely -Path $tempCert
    }
}

# 4. Install caller workflow template if requested and missing
if ($InstallWorkflow) {
    $wfDir = Join-Path $meta.ProjectPath '.github\workflows'
    $wfDest = Join-Path $wfDir 'android-aab.yml'
    if (-not (Test-Path -LiteralPath $wfDest -PathType Leaf)) {
        New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
        $tpl = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'workflows\caller-selfhosted-aab.yml') -Raw -Encoding UTF8
        $safeProject = ($projectName -replace '[^A-Za-z0-9_.-]', '')
        $rendered = $tpl.Replace('__PROJECT_NAME__', $safeProject).Replace('__RUNNER_LABEL__', $RunnerLabel).Replace('__CONFIG_FILE__', "$slug.json")
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($wfDest, $rendered, $utf8NoBom)
        Write-Host "[OK] Created workflow template: $wfDest (commit & push to enable on GitHub)"
    } else {
        Write-Host "Workflow already exists: $wfDest"
    }
}

# 5. Download official actions/runner if needed & register via API token
if (-not $SkipRunner) {
    $configCmd = Join-Path $RunnerDir 'config.cmd'
    $runCmd = Join-Path $RunnerDir 'run.cmd'
    $startCmd = Join-Path $RunnerDir ("Start-$projectName-Runner.cmd")

    if (-not (Test-Path -LiteralPath $configCmd -PathType Leaf)) {
        New-Item -ItemType Directory -Path $RunnerDir -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Write-Host 'Querying latest official actions/runner release (win-x64)...'
        $runnerRel = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Headers @{ 'User-Agent' = 'Unity-Android-AAB-Workflow' }
        $asset = $runnerRel.assets | Where-Object { $_.name -match '^actions-runner-win-x64-[0-9.]+\.zip$' } | Select-Object -First 1
        if ($null -eq $asset) {
            throw 'Could not locate win-x64 asset in latest actions/runner release.'
        }

        $expectedSha = ''
        if ($asset.PSObject.Properties.Match('digest').Count -gt 0 -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
            $expectedSha = $Matches[1].ToUpperInvariant()
        } elseif ($runnerRel.body -match 'BEGIN SHA win-x64.*?([0-9a-fA-F]{64}).*?END SHA win-x64') {
            $expectedSha = $Matches[1].ToUpperInvariant()
        }
        if ([string]::IsNullOrEmpty($expectedSha)) {
            throw 'Official SHA-256 digest was not found in actions/runner release metadata.'
        }

        $zipPath = Join-Path $RunnerDir $asset.name
        try {
            Write-Host "Downloading $($asset.name) ($($asset.size) bytes)..."
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
            $actualSha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToUpperInvariant()
            if ($actualSha -cne $expectedSha) {
                throw "Runner package SHA-256 mismatch! expected=$expectedSha actual=$actualSha"
            }
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            Write-Host "Extracting verified runner to $RunnerDir..."
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $RunnerDir)
        } finally {
            if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $cmdText = "@echo off`r`ncd /d ""%~dp0""`r`ncall run.cmd`r`n"
    Set-Content -LiteralPath $startCmd -Value $cmdText -Encoding ASCII

    $dotRunner = Join-Path $RunnerDir '.runner'
    $dotCreds = Join-Path $RunnerDir '.credentials'
    $dotCredRsa = Join-Path $RunnerDir '.credentials_rsaparams'
    $alreadyValid = $false

    if (Test-Path -LiteralPath $dotRunner -PathType Leaf) {
        if (Test-Path -LiteralPath $dotCreds -PathType Leaf) {
            try {
                $runnerCfg = Get-Content -LiteralPath $dotRunner -Raw -Encoding UTF8 | ConvertFrom-Json
                $cfgUrl = ([string](Get-ConfigProperty -Object $runnerCfg -Name 'gitHubUrl' -Default '')).TrimEnd('/')
                $cfgName = ([string](Get-ConfigProperty -Object $runnerCfg -Name 'agentName' -Default '')).Trim()
                $expectedUrl = ("https://github.com/$Repo").TrimEnd('/')
                if ([string]::Equals($cfgUrl, $expectedUrl, [StringComparison]::OrdinalIgnoreCase) -and -not [string]::IsNullOrWhiteSpace($cfgName)) {
                    $apiRes = Invoke-ExternalProcessChecked -FilePath $gh -ArgumentList @('api', "repos/$Repo/actions/runners") -TimeoutSeconds 30
                    $apiObj = $apiRes.Stdout | ConvertFrom-Json
                    $runnersList = @(Get-ConfigProperty -Object $apiObj -Name 'runners' -Default @())
                    $matchedRunner = $runnersList | Where-Object {
                        if ($null -eq $_) { return $false }
                        $rName = [string](Get-ConfigProperty -Object $_ -Name 'name' -Default '')
                        $rLabels = @(Get-ConfigProperty -Object $_ -Name 'labels' -Default @() | ForEach-Object { [string](Get-ConfigProperty -Object $_ -Name 'name' -Default '') })
                        [string]::Equals($rName, $cfgName, [StringComparison]::OrdinalIgnoreCase) -and ($rLabels -contains $RunnerLabel)
                    } | Select-Object -First 1
                    if ($null -ne $matchedRunner) {
                        $alreadyValid = $true
                        Write-Host "[OK] Local runner '$cfgName' is already registered for $Repo (label: $RunnerLabel); keeping existing registration."
                    }
                }
            } catch {
                $alreadyValid = $false
            }
        }

        if (-not $alreadyValid) {
            Write-Host "Existing runner config in $RunnerDir is stale or mismatched; removing old local registration..."
            $rmToken = ''
            try {
                $rmRes = Invoke-ExternalProcessChecked -FilePath $gh -ArgumentList @('api', '--method', 'POST', "repos/$Repo/actions/runners/remove-token", '--jq', '.token') -TimeoutSeconds 30
                $rmToken = $rmRes.Stdout.Trim()
                if (-not [string]::IsNullOrWhiteSpace($rmToken)) {
                    $null = Invoke-ExternalProcessChecked -FilePath $configCmd -WorkingDirectory $RunnerDir -ArgumentList @('remove', '--token', $rmToken) -TimeoutSeconds 60
                }
            } catch {
                Write-Warning "Graceful config.cmd remove did not complete cleanly (continuing cleanup): $($_.Exception.Message)"
            } finally {
                $rmToken = ''
            }

            foreach ($staleFile in @($dotRunner, $dotCreds, $dotCredRsa)) {
                if (Test-Path -LiteralPath $staleFile -PathType Leaf) {
                    Remove-Item -LiteralPath $staleFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    if (-not $alreadyValid) {
        Write-Host "Requesting runner registration token from GitHub for $Repo..."
        $tokenRes = Invoke-ExternalProcessChecked -FilePath $gh -ArgumentList @('api', '--method', 'POST', "repos/$Repo/actions/runners/registration-token", '--jq', '.token') -TimeoutSeconds 30
        $regToken = $tokenRes.Stdout.Trim()
        if ([string]::IsNullOrWhiteSpace($regToken)) {
            throw "Failed to obtain runner registration token for $Repo"
        }

        try {
            $null = Invoke-ExternalProcessChecked -FilePath $configCmd -WorkingDirectory $RunnerDir -ArgumentList @(
                '--url', "https://github.com/$Repo",
                '--token', $regToken,
                '--name', $RunnerName,
                '--labels', $RunnerLabel,
                '--work', '_work',
                '--unattended',
                '--replace'
            ) -TimeoutSeconds 120
        } finally {
            $regToken = ''
        }
    }

    if ($RegisterLogonTask) {
        $taskName = "$projectName-GitHub-Runner"
        $null = Invoke-ExternalProcessChecked -FilePath 'schtasks.exe' -ArgumentList @('/Create', '/TN', $taskName, '/TR', ('"' + $startCmd + '"'), '/SC', 'ONLOGON', '/RL', 'HIGHEST', '/IT', '/F') -TimeoutSeconds 30
        Write-Host "[OK] Registered interactive logon task: $taskName"
    }

    Write-Host ''
    Write-Host '=== Setup Complete ==='
    Write-Host "1. Double-click: $startCmd"
    Write-Host "2. Open: https://github.com/$Repo/actions -> Run workflow!"
}
