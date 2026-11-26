[CmdletBinding()]
param(
    [string]$ProjectPath = '',
    [string]$ConfigPath = '',
    [string]$OutputDir = '',
    [string]$UnityCliPath = '',
    [string]$UnityEditorPath = '',
    [string]$AndroidPlayerPath = '',
    [string]$ExecuteMethod = '',
    [switch]$UseUnityCliBuiltin,
    [switch]$UseEditorDirect,
    [string]$KeystorePath = '',
    [string]$KeyAlias = '',
    [string]$ExpectedCertificateSha256 = '',
    [string]$StorePasswordEnvVar = 'UNITY_AAB_STORE_PASSWORD',
    [string]$KeyPasswordEnvVar = 'UNITY_AAB_KEY_PASSWORD',
    [string]$VersionName = '',
    [Nullable[int]]$VersionCode = $null,
    [string]$PackageName = '',
    [Nullable[int]]$MinSdk = $null,
    [Nullable[int]]$TargetSdk = $null,
    [switch]$PrepareOnly,
    [switch]$QaSigning,
    [switch]$CheckEnv,
    [switch]$SkipGradleCacheClean,
    [string[]]$RequiredPermissions = @(),
    [hashtable]$RequiredMetaData = $null,
    [hashtable]$RequiredFeatures = $null,
    [int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'tools\Common.ps1')

if ($PrepareOnly -and $QaSigning) {
    throw 'Choose either -PrepareOnly or -QaSigning, not both.'
}

$cfg = $null
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Config file not found: $ConfigPath"
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        $ProjectPath = [string](Get-ConfigProperty -Object $cfg -Name 'projectPath' -Default '')
    }
}

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = 'Select Unity project root folder (containing Assets and ProjectSettings)'
    try {
        if ($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
            return
        }
        $ProjectPath = $picker.SelectedPath
    } finally {
        $picker.Dispose()
    }
}

$buildCfg = Get-ConfigProperty -Object $cfg -Name 'build'
$signCfg = Get-ConfigProperty -Object $cfg -Name 'signing'
$verifyCfg = Get-ConfigProperty -Object $cfg -Name 'verify'

$releaseJsonRel = [string](Get-ConfigProperty -Object $cfg -Name 'releaseJsonPath' -Default '')
$meta = Read-UnityProjectMetadata -ProjectPath $ProjectPath -ReleaseJsonRelativePath $releaseJsonRel

$projectName = [string](Get-ConfigProperty -Object $cfg -Name 'projectName' -Default '')
if ([string]::IsNullOrWhiteSpace($projectName)) { $projectName = $meta.ProjectName }
$safeProjectName = ($projectName -replace '[^A-Za-z0-9_.-]', '_')

if ([string]::IsNullOrWhiteSpace($VersionName)) { $VersionName = $meta.VersionName }
if ($null -eq $VersionCode) { $VersionCode = $meta.VersionCode }
if ([string]::IsNullOrWhiteSpace($PackageName)) {
    $PackageName = [string](Get-ConfigProperty -Object $verifyCfg -Name 'packageName' -Default '')
    if ([string]::IsNullOrWhiteSpace($PackageName)) { $PackageName = $meta.PackageName }
}
if ($null -eq $MinSdk) {
    $cfgMin = Get-ConfigProperty -Object $verifyCfg -Name 'expectedMinSdk'
    if ($null -eq $cfgMin) { $cfgMin = Get-ConfigProperty -Object $buildCfg -Name 'minSdkVersion' }
    if ($null -ne $cfgMin) { $MinSdk = [int]$cfgMin } elseif ($null -ne $meta.MinSdkVersion) { $MinSdk = [int]$meta.MinSdkVersion }
}
if ($null -eq $TargetSdk) {
    $cfgTarget = Get-ConfigProperty -Object $verifyCfg -Name 'expectedTargetSdk'
    if ($null -eq $cfgTarget) { $cfgTarget = Get-ConfigProperty -Object $buildCfg -Name 'targetSdkVersion' }
    if ($null -ne $cfgTarget) { $TargetSdk = [int]$cfgTarget } elseif ($null -ne $meta.TargetSdkVersion) { $TargetSdk = [int]$meta.TargetSdkVersion }
}

if ([string]::IsNullOrWhiteSpace($ExecuteMethod)) {
    $ExecuteMethod = [string](Get-ConfigProperty -Object $buildCfg -Name 'executeMethod' -Default '')
}
if (-not $PSBoundParameters.ContainsKey('UseUnityCliBuiltin')) {
    $cfgBuiltin = Get-ConfigProperty -Object $buildCfg -Name 'useUnityCliBuiltin'
    if ($null -ne $cfgBuiltin -and [bool]$cfgBuiltin) { $UseUnityCliBuiltin = $true }
}
if ([string]::IsNullOrWhiteSpace($KeystorePath)) {
    $KeystorePath = [string](Get-ConfigProperty -Object $signCfg -Name 'keystorePath' -Default '')
}
if ([string]::IsNullOrWhiteSpace($KeyAlias)) {
    $KeyAlias = [string](Get-ConfigProperty -Object $signCfg -Name 'keyAlias' -Default '')
}
if ([string]::IsNullOrWhiteSpace($ExpectedCertificateSha256)) {
    $ExpectedCertificateSha256 = [string](Get-ConfigProperty -Object $signCfg -Name 'expectedCertificateSha256' -Default '')
}
if (-not $PSBoundParameters.ContainsKey('StorePasswordEnvVar')) {
    $cfgStoreEnv = [string](Get-ConfigProperty -Object $signCfg -Name 'storePasswordEnvVar' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($cfgStoreEnv)) { $StorePasswordEnvVar = $cfgStoreEnv }
}
if (-not $PSBoundParameters.ContainsKey('KeyPasswordEnvVar')) {
    $cfgKeyEnv = [string](Get-ConfigProperty -Object $signCfg -Name 'keyPasswordEnvVar' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($cfgKeyEnv)) { $KeyPasswordEnvVar = $cfgKeyEnv }
}

$unityCli = Find-UnityCli -OverridePath $UnityCliPath
$unityEditor = Find-UnityEditor -EditorVersion $meta.EditorVersion -OverridePath $UnityEditorPath
if ([string]::IsNullOrWhiteSpace($unityEditor)) {
    throw "Unity Editor $($meta.EditorVersion) not found. Install it in Unity Hub or specify -UnityEditorPath."
}
$tools = Find-AndroidPlayerTools -UnityEditorPath $unityEditor -EditorVersion $meta.EditorVersion -OverrideAndroidPlayerPath $AndroidPlayerPath

if ($CheckEnv) {
    $cliText = if ($null -ne $unityCli) { "$($unityCli.Path) (version $($unityCli.Version))" } else { '<not found; will use Unity Editor -batchmode>' }
    Write-Host '=== Unity Android AAB Environment Check ==='
    Write-Host "ProjectPath      : $($meta.ProjectPath)"
    Write-Host "ProjectName      : $projectName"
    Write-Host "EditorVersion    : $($meta.EditorVersion)"
    Write-Host "UnityCLI         : $cliText"
    Write-Host "UnityEditor      : $unityEditor"
    Write-Host "AndroidPlayer    : $($tools.AndroidPlayerPath)"
    Write-Host "Java             : $($tools.JavaExe)"
    Write-Host "Keytool          : $($tools.KeytoolExe)"
    Write-Host "Jarsigner        : $($tools.JarsignerExe)"
    Write-Host "Bundletool       : $($tools.BundletoolJar)"
    Write-Host "ReleaseJson      : $(if ($meta.ReleaseJsonPath) { $meta.ReleaseJsonPath } else { '<none>' })"
    Write-Host "PackageName      : $PackageName"
    Write-Host "VersionName      : $VersionName"
    Write-Host "VersionCode      : $VersionCode"
    Write-Host "MinSdk / Target  : $MinSdk / $TargetSdk"
    return [PSCustomObject]@{
        ProjectPath   = $meta.ProjectPath
        ProjectName   = $projectName
        EditorVersion = $meta.EditorVersion
        UnityCli      = if ($null -ne $unityCli) { $unityCli.Path } else { '' }
        UnityCliVer   = if ($null -ne $unityCli) { $unityCli.Version } else { '' }
        UnityEditor   = $unityEditor
        AndroidPlayer = $tools.AndroidPlayerPath
        BundletoolJar = $tools.BundletoolJar
        PackageName   = $PackageName
        VersionName   = $VersionName
        VersionCode   = $VersionCode
        MinSdk        = $MinSdk
        TargetSdk     = $TargetSdk
    }
}

$verFolder = if (-not [string]::IsNullOrWhiteSpace($VersionName)) { $VersionName } else { 'unversioned' }
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $PSScriptRoot "out\$safeProjectName\$verFolder"
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

$qaDir = Join-Path $OutputDir 'qa'
New-Item -ItemType Directory -Path $qaDir -Force | Out-Null

$stagingRel = [string](Get-ConfigProperty -Object $buildCfg -Name 'stagingAabRelativePath' -Default '')
$stagingAab = if (-not [string]::IsNullOrWhiteSpace($stagingRel)) {
    if ([IO.Path]::IsPathRooted($stagingRel)) { $stagingRel } else { Join-Path $meta.ProjectPath $stagingRel }
} else {
    Join-Path $qaDir "$safeProjectName-$verFolder-staging.aab"
}
$stagingParent = Split-Path -Parent $stagingAab
if (-not [string]::IsNullOrWhiteSpace($stagingParent)) {
    New-Item -ItemType Directory -Path $stagingParent -Force | Out-Null
}
if (Test-Path -LiteralPath $stagingAab -PathType Leaf) {
    Remove-Item -LiteralPath $stagingAab -Force
}

$formalSigning = (-not $PrepareOnly) -and (-not $QaSigning)
$tempStoreAdded = $false
$tempQaKeystore = ''
$qaPassEnv = '_UNITY_AAB_QA_PW_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$tempCertCheck = Join-Path ([IO.Path]::GetTempPath()) ("aab-precheck-" + [Guid]::NewGuid().ToString('N') + '.der')
$injectedBridge = $false
$createdEditorFolder = $false
$editorFolder = Join-Path $meta.ProjectPath 'Assets\Editor'
$bridgeDest = Join-Path $editorFolder 'UnityAabWorkflowBridge.cs'

$savedEnv = @{}
function Save-And-SetEnv([string]$Name, [string]$Value) {
    if (-not $savedEnv.ContainsKey($Name)) {
        $savedEnv[$Name] = [Environment]::GetEnvironmentVariable($Name)
    }
    [Environment]::SetEnvironmentVariable($Name, $Value)
}

try {
    # Pre-flight formal signing validation BEFORE spending minutes building
    if ($formalSigning) {
        if ([string]::IsNullOrWhiteSpace($KeystorePath) -or [string]::IsNullOrWhiteSpace($KeyAlias)) {
            throw 'Formal signing requires -KeystorePath and -KeyAlias (or pass -QaSigning / -PrepareOnly).'
        }
        if (-not (Test-Path -LiteralPath $KeystorePath -PathType Leaf)) {
            throw "Upload keystore not found: $KeystorePath"
        }
        $existingPw = [Environment]::GetEnvironmentVariable($StorePasswordEnvVar)
        if ([string]::IsNullOrEmpty($existingPw)) {
            $sec = Read-Host "Enter keystore password for alias '$KeyAlias'" -AsSecureString
            $plain = ([Net.NetworkCredential]::new('', $sec)).Password
            $sec.Dispose()
            if ([string]::IsNullOrEmpty($plain)) {
                throw 'Keystore password cannot be empty.'
            }
            [Environment]::SetEnvironmentVariable($StorePasswordEnvVar, $plain)
            $plain = $null
            $tempStoreAdded = $true
        }
        $null = Invoke-ExternalProcessChecked -FilePath $tools.KeytoolExe -ArgumentList @(
            '-exportcert',
            '-keystore', (Resolve-Path -LiteralPath $KeystorePath).Path,
            '-storepass:env', $StorePasswordEnvVar,
            '-alias', $KeyAlias,
            '-file', $tempCertCheck
        ) -TimeoutSeconds 60
        $preCertSha = (Get-FileHash -LiteralPath $tempCertCheck -Algorithm SHA256).Hash.ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($ExpectedCertificateSha256)) {
            $expectedNorm = Normalize-Sha256Hex -Raw $ExpectedCertificateSha256
            if ($preCertSha -cne $expectedNorm) {
                throw "Pre-build certificate check failed! expected=$expectedNorm actual=$preCertSha"
            }
        }
        Write-Host "[Pre-flight] Upload keystore verified. Cert SHA-256: $preCertSha"
    }

    if (-not $SkipGradleCacheClean) {
        Clear-GradleAapt2Cache -AndroidPlayerPath $tools.AndroidPlayerPath -JavaExe $tools.JavaExe
    }

    # Hide signing passwords from Unity child processes
    $savedStorePw = [Environment]::GetEnvironmentVariable($StorePasswordEnvVar)
    $savedKeyPw = if (-not [string]::IsNullOrWhiteSpace($KeyPasswordEnvVar)) { [Environment]::GetEnvironmentVariable($KeyPasswordEnvVar) } else { $null }
    [Environment]::SetEnvironmentVariable($StorePasswordEnvVar, $null)
    if (-not [string]::IsNullOrWhiteSpace($KeyPasswordEnvVar)) {
        [Environment]::SetEnvironmentVariable($KeyPasswordEnvVar, $null)
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($PackageName)) { Save-And-SetEnv 'UNITY_AAB_PACKAGE_NAME' $PackageName }
        if (-not [string]::IsNullOrWhiteSpace($VersionName)) { Save-And-SetEnv 'UNITY_AAB_VERSION_NAME' $VersionName }
        if ($null -ne $VersionCode) { Save-And-SetEnv 'UNITY_AAB_VERSION_CODE' ([string]$VersionCode) }
        if ($null -ne $MinSdk) { Save-And-SetEnv 'UNITY_AAB_MIN_SDK' ([string]$MinSdk) }
        if ($null -ne $TargetSdk) { Save-And-SetEnv 'UNITY_AAB_TARGET_SDK' ([string]$TargetSdk) }
        Save-And-SetEnv 'UNITY_AAB_OUTPUT' $stagingAab

        $methodToInvoke = $ExecuteMethod
        if ([string]::IsNullOrWhiteSpace($methodToInvoke) -and -not $UseUnityCliBuiltin) {
            if ((Test-Path -LiteralPath $bridgeDest) -or (Test-Path -LiteralPath "$bridgeDest.meta")) {
                throw "Existing bridge file found at $bridgeDest; remove it or pass -ExecuteMethod explicitly."
            }
            $createdEditorFolder = -not (Test-Path -LiteralPath $editorFolder -PathType Container)
            if ($createdEditorFolder) {
                New-Item -ItemType Directory -Path $editorFolder -Force | Out-Null
            }
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tools\UnityAabBuildBridge.cs') -Destination $bridgeDest -Force
            $injectedBridge = $true
            $methodToInvoke = 'UnityAabWorkflowBridge.Run'
        }

        $buildLog = Join-Path $qaDir 'unity-aab-build.log'
        $buildStdout = Join-Path $qaDir 'unity-aab-build.stdout.txt'
        $buildStderr = Join-Path $qaDir 'unity-aab-build.stderr.txt'

        if (($null -ne $unityCli) -and (-not $UseEditorDirect)) {
            Write-Host "Building staging AAB via Unity CLI ($($unityCli.Version))..."
            $cliArgs = New-Object System.Collections.Generic.List[string]
            $cliArgs.Add('--non-interactive')
            $cliArgs.Add('build')
            $cliArgs.Add($meta.ProjectPath)
            $cliArgs.Add('--target')
            $cliArgs.Add('Android')
            $cliArgs.Add('--android-export-type')
            $cliArgs.Add('aab')
            $cliArgs.Add('--editor-path')
            $cliArgs.Add($unityEditor)
            $cliArgs.Add('--output-path')
            $cliArgs.Add($stagingAab)
            $cliArgs.Add('--log-file')
            $cliArgs.Add($buildLog)
            $cliArgs.Add('--no-tail')
            $cliArgs.Add('--allow-dirty-build')
            if (-not [string]::IsNullOrWhiteSpace($methodToInvoke)) {
                $cliArgs.Add('--execute-method')
                $cliArgs.Add($methodToInvoke)
            } else {
                $symbolType = [string](Get-ConfigProperty -Object $buildCfg -Name 'symbolType' -Default 'none')
                if (-not [string]::IsNullOrWhiteSpace($symbolType)) {
                    $cliArgs.Add('--android-symbol-type')
                    $cliArgs.Add($symbolType)
                }
                if ($null -ne $TargetSdk) {
                    $cliArgs.Add('--android-target-sdk-version')
                    $cliArgs.Add([string]$TargetSdk)
                }
                if ($null -ne $VersionCode) {
                    $cliArgs.Add('--android-version-code')
                    $cliArgs.Add([string]$VersionCode)
                }
                if (-not [string]::IsNullOrWhiteSpace($VersionName)) {
                    $cliArgs.Add('--versioning-strategy')
                    $cliArgs.Add('custom')
                    $cliArgs.Add('--build-version')
                    $cliArgs.Add($VersionName)
                }
            }
            $null = Invoke-ExternalProcessChecked -FilePath $unityCli.Path -ArgumentList $cliArgs.ToArray() -StdoutPath $buildStdout -StderrPath $buildStderr -TimeoutSeconds $TimeoutSeconds
        } else {
            Write-Host "Building staging AAB via Unity Editor directly: $unityEditor"
            if ([string]::IsNullOrWhiteSpace($methodToInvoke)) {
                throw 'Direct Unity Editor mode requires an executeMethod (or omit -UseUnityCliBuiltin so UnityAabWorkflowBridge.Run can be used).'
            }
            $edArgs = @(
                '-batchmode', '-nographics', '-quit',
                '-buildTarget', 'Android',
                '-projectPath', $meta.ProjectPath,
                '-executeMethod', $methodToInvoke,
                '-buildOutput', $stagingAab,
                '-logFile', $buildLog
            )
            $null = Invoke-ExternalProcessChecked -FilePath $unityEditor -ArgumentList $edArgs -StdoutPath $buildStdout -StderrPath $buildStderr -TimeoutSeconds $TimeoutSeconds
        }
    } finally {
        # Restore signing passwords into current process memory
        if ($null -ne $savedStorePw) { [Environment]::SetEnvironmentVariable($StorePasswordEnvVar, $savedStorePw) }
        if (-not [string]::IsNullOrWhiteSpace($KeyPasswordEnvVar) -and $null -ne $savedKeyPw) {
            [Environment]::SetEnvironmentVariable($KeyPasswordEnvVar, $savedKeyPw)
        }
        $savedStorePw = $null
        $savedKeyPw = $null

        foreach ($k in $savedEnv.Keys) {
            [Environment]::SetEnvironmentVariable($k, $savedEnv[$k])
        }

        if ($injectedBridge) {
            foreach ($f in @($bridgeDest, "$bridgeDest.meta")) {
                if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            }
            if ($createdEditorFolder -and (Test-Path -LiteralPath $editorFolder -PathType Container)) {
                $remaining = @(Get-ChildItem -LiteralPath $editorFolder -Force -ErrorAction SilentlyContinue)
                if ($remaining.Count -eq 0) {
                    Remove-Item -LiteralPath $editorFolder -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath "$editorFolder.meta" -PathType Leaf) {
                        Remove-Item -LiteralPath "$editorFolder.meta" -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }

    if (-not (Test-Path -LiteralPath $stagingAab -PathType Leaf)) {
        throw "Staging AAB was not generated at expected path: $stagingAab"
    }

    $verifyCommon = @{
        AndroidPlayerPath = $tools.AndroidPlayerPath
        UnityEditorPath   = $unityEditor
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $verifyCommon['ConfigPath'] = $ConfigPath }
    if (-not [string]::IsNullOrWhiteSpace($PackageName)) { $verifyCommon['PackageName'] = $PackageName }
    if (-not [string]::IsNullOrWhiteSpace($VersionName)) { $verifyCommon['ExpectedVersionName'] = $VersionName }
    if ($null -ne $VersionCode) { $verifyCommon['ExpectedVersionCode'] = $VersionCode }
    if ($null -ne $MinSdk) { $verifyCommon['ExpectedMinSdk'] = $MinSdk }
    if ($null -ne $TargetSdk) { $verifyCommon['ExpectedTargetSdk'] = $TargetSdk }
    if ($RequiredPermissions.Count -gt 0) { $verifyCommon['RequiredPermissions'] = $RequiredPermissions }
    if ($null -ne $RequiredMetaData -and $RequiredMetaData.Count -gt 0) { $verifyCommon['RequiredMetaData'] = $RequiredMetaData }
    if ($null -ne $RequiredFeatures -and $RequiredFeatures.Count -gt 0) { $verifyCommon['RequiredFeatures'] = $RequiredFeatures }

    if ($PrepareOnly) {
        $prepReport = Join-Path $qaDir 'aab-prepare-verify.txt'
        $verifyRes = & (Join-Path $PSScriptRoot 'Verify-Aab.ps1') -AabPath $stagingAab -SkipSignatureCheck -ReportPath $prepReport @verifyCommon
        Write-Host "PrepareOnly complete. Staging AAB verified (do NOT upload unsigned staging AAB): $stagingAab"
        return $verifyRes
    }

    if ($QaSigning) {
        $tempQaKeystore = Join-Path ([IO.Path]::GetTempPath()) ("aab-qa-" + [Guid]::NewGuid().ToString('N') + '.p12')
        $qaAlias = 'qa-temp'
        [Environment]::SetEnvironmentVariable($qaPassEnv, ([Guid]::NewGuid().ToString('N') + 'Qa!9'))
        $null = Invoke-ExternalProcessChecked -FilePath $tools.KeytoolExe -ArgumentList @(
            '-genkeypair',
            '-keystore', $tempQaKeystore,
            '-storetype', 'PKCS12',
            '-alias', $qaAlias,
            '-keyalg', 'RSA',
            '-keysize', '2048',
            '-validity', '30',
            '-storepass:env', $qaPassEnv,
            '-keypass:env', $qaPassEnv,
            '-dname', 'CN=QA-Local-Only, O=PlayTest, C=CN'
        ) -TimeoutSeconds 60

        $qaAab = Join-Path $OutputDir "$safeProjectName-$verFolder-qa-signed.aab"
        $qaSigReport = Join-Path $qaDir 'aab-qa-signature.txt'
        $signRes = & (Join-Path $PSScriptRoot 'Sign-Aab.ps1') `
            -InputAab $stagingAab `
            -OutputAab $qaAab `
            -KeystorePath $tempQaKeystore `
            -KeyAlias $qaAlias `
            -StorePasswordEnvVar $qaPassEnv `
            -AndroidPlayerPath $tools.AndroidPlayerPath `
            -SignatureReportPath $qaSigReport

        $verifyReport = Join-Path $qaDir 'aab-qa-verify.txt'
        $verifyRes = & (Join-Path $PSScriptRoot 'Verify-Aab.ps1') `
            -AabPath $qaAab `
            -Sha256File $signRes.Sha256File `
            -KeystorePath $tempQaKeystore `
            -KeyAlias $qaAlias `
            -StorePasswordEnvVar $qaPassEnv `
            -ExpectedCertificateSha256 $signRes.CertificateSha256 `
            -ReportPath $verifyReport `
            @verifyCommon

        Write-Host "QA signed & verified AAB ready (DO NOT upload QA bundle to Google Play): $qaAab"
        return $verifyRes
    }

    # Formal upload keystore signing + verification
    $releaseAab = Join-Path $OutputDir "$safeProjectName-$verFolder-release.aab"
    $sigReport = Join-Path $qaDir 'aab-signature.txt'
    $signRes = & (Join-Path $PSScriptRoot 'Sign-Aab.ps1') `
        -InputAab $stagingAab `
        -OutputAab $releaseAab `
        -KeystorePath (Resolve-Path -LiteralPath $KeystorePath).Path `
        -KeyAlias $KeyAlias `
        -ExpectedCertificateSha256 $ExpectedCertificateSha256 `
        -StorePasswordEnvVar $StorePasswordEnvVar `
        -KeyPasswordEnvVar $KeyPasswordEnvVar `
        -AndroidPlayerPath $tools.AndroidPlayerPath `
        -SignatureReportPath $sigReport

    $verifyReport = Join-Path $qaDir 'aab-verify.txt'
    $verifyRes = & (Join-Path $PSScriptRoot 'Verify-Aab.ps1') `
        -AabPath $releaseAab `
        -Sha256File $signRes.Sha256File `
        -KeystorePath (Resolve-Path -LiteralPath $KeystorePath).Path `
        -KeyAlias $KeyAlias `
        -StorePasswordEnvVar $StorePasswordEnvVar `
        -ExpectedCertificateSha256 $signRes.CertificateSha256 `
        -ReportPath $verifyReport `
        @verifyCommon

    $summaryPath = Join-Path $OutputDir 'aab-build-summary.json'
    $summaryObj = [ordered]@{
        projectName       = $projectName
        packageName       = $verifyRes.PackageName
        versionName       = $verifyRes.VersionName
        versionCode       = $verifyRes.VersionCode
        aabPath           = $verifyRes.AabPath
        sha256File        = $signRes.Sha256File
        aabSha256         = $verifyRes.AabSha256
        certificateSha256 = $verifyRes.CertificateSha256
        sizeBytes         = $verifyRes.SizeBytes
        minSdk            = $verifyRes.MinSdk
        targetSdk         = $verifyRes.TargetSdk
        builtAtUtc        = [DateTime]::UtcNow.ToString('o')
    }
    $summaryObj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    Write-Host "Release summary saved: $summaryPath"
    return $verifyRes
} finally {
    if ($tempStoreAdded) {
        [Environment]::SetEnvironmentVariable($StorePasswordEnvVar, $null)
    }
    [Environment]::SetEnvironmentVariable($qaPassEnv, $null)
    Wipe-FileSecurely -Path $tempCertCheck
    Wipe-FileSecurely -Path $tempQaKeystore
}
