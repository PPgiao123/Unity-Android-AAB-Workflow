[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AabPath,
    [string]$ConfigPath = '',
    [string]$AndroidPlayerPath = '',
    [string]$UnityEditorPath = '',
    [string]$PackageName = '',
    [string]$ExpectedVersionName = '',
    [Nullable[int]]$ExpectedVersionCode = $null,
    [Nullable[int]]$ExpectedMinSdk = $null,
    [Nullable[int]]$ExpectedTargetSdk = $null,
    [string[]]$AllowedAbis = @(),
    [switch]$SkipIl2cppCheck,
    [switch]$Skip16KbCheck,
    [switch]$SkipSignatureCheck,
    [string]$ExpectedCertificateSha256 = '',
    [string]$KeystorePath = '',
    [string]$KeyAlias = '',
    [string]$StorePasswordEnvVar = 'UNITY_AAB_STORE_PASSWORD',
    [string]$Sha256File = '',
    [string]$ReportPath = '',
    [string[]]$RequiredPermissions = @(),
    [hashtable]$RequiredMetaData = $null,
    [hashtable]$RequiredFeatures = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'tools\Common.ps1')

if (-not (Test-Path -LiteralPath $AabPath -PathType Leaf)) {
    throw "AAB file not found: $AabPath"
}
$resolvedAab = (Resolve-Path -LiteralPath $AabPath).Path

$cfg = $null
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Config file not found: $ConfigPath"
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

$verifyCfg = Get-ConfigProperty -Object $cfg -Name 'verify'
$signCfg = Get-ConfigProperty -Object $cfg -Name 'signing'

if ([string]::IsNullOrWhiteSpace($PackageName)) {
    $PackageName = [string](Get-ConfigProperty -Object $verifyCfg -Name 'packageName' -Default '')
}
if ($null -eq $ExpectedMinSdk) {
    $cfgMin = Get-ConfigProperty -Object $verifyCfg -Name 'expectedMinSdk'
    if ($null -ne $cfgMin) { $ExpectedMinSdk = [int]$cfgMin }
}
if ($null -eq $ExpectedTargetSdk) {
    $cfgTarget = Get-ConfigProperty -Object $verifyCfg -Name 'expectedTargetSdk'
    if ($null -ne $cfgTarget) { $ExpectedTargetSdk = [int]$cfgTarget }
}
if ($AllowedAbis.Count -eq 0) {
    $cfgAbis = Get-ConfigProperty -Object $verifyCfg -Name 'allowedAbis'
    if ($null -ne $cfgAbis -and @($cfgAbis).Count -gt 0) {
        $AllowedAbis = @($cfgAbis | ForEach-Object { [string]$_ })
    } else {
        $AllowedAbis = @('arm64-v8a')
    }
}
if (-not $PSBoundParameters.ContainsKey('SkipIl2cppCheck')) {
    $cfgIl2cpp = Get-ConfigProperty -Object $verifyCfg -Name 'requireIl2cpp'
    if ($null -ne $cfgIl2cpp -and (-not [bool]$cfgIl2cpp)) {
        $SkipIl2cppCheck = $true
    }
}
if (-not $PSBoundParameters.ContainsKey('Skip16KbCheck')) {
    $cfg16k = Get-ConfigProperty -Object $verifyCfg -Name 'require16KbElfAlignment'
    if ($null -ne $cfg16k -and (-not [bool]$cfg16k)) {
        $Skip16KbCheck = $true
    }
}
if ($RequiredPermissions.Count -eq 0) {
    $cfgPerms = Get-ConfigProperty -Object $verifyCfg -Name 'requiredPermissions'
    if ($null -ne $cfgPerms) {
        $RequiredPermissions = @($cfgPerms | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}
if ($null -eq $RequiredMetaData) {
    $RequiredMetaData = @{}
    $cfgMeta = Get-ConfigProperty -Object $verifyCfg -Name 'requiredMetaData'
    if ($null -ne $cfgMeta) {
        foreach ($p in $cfgMeta.PSObject.Properties) {
            $RequiredMetaData[$p.Name] = [string]$p.Value
        }
    }
}
if ($null -eq $RequiredFeatures) {
    $RequiredFeatures = @{}
    $cfgFeat = Get-ConfigProperty -Object $verifyCfg -Name 'requiredFeatures'
    if ($null -ne $cfgFeat) {
        foreach ($p in $cfgFeat.PSObject.Properties) {
            $RequiredFeatures[$p.Name] = [string]$p.Value
        }
    }
}
if ([string]::IsNullOrWhiteSpace($ExpectedCertificateSha256)) {
    $ExpectedCertificateSha256 = [string](Get-ConfigProperty -Object $signCfg -Name 'expectedCertificateSha256' -Default '')
}
if ([string]::IsNullOrWhiteSpace($KeystorePath)) {
    $KeystorePath = [string](Get-ConfigProperty -Object $signCfg -Name 'keystorePath' -Default '')
}
if ([string]::IsNullOrWhiteSpace($KeyAlias)) {
    $KeyAlias = [string](Get-ConfigProperty -Object $signCfg -Name 'keyAlias' -Default '')
}
if (-not $PSBoundParameters.ContainsKey('StorePasswordEnvVar')) {
    $cfgPassEnv = [string](Get-ConfigProperty -Object $signCfg -Name 'storePasswordEnvVar' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($cfgPassEnv)) {
        $StorePasswordEnvVar = $cfgPassEnv
    }
}

$tools = Find-AndroidPlayerTools -UnityEditorPath $UnityEditorPath -OverrideAndroidPlayerPath $AndroidPlayerPath
$reportLines = New-Object System.Collections.Generic.List[string]

$aabSha256 = (Get-FileHash -LiteralPath $resolvedAab -Algorithm SHA256).Hash.ToUpperInvariant()
$aabSize = (Get-Item -LiteralPath $resolvedAab).Length
Write-Host "Verifying AAB: $resolvedAab ($aabSize bytes)"

if (-not [string]::IsNullOrWhiteSpace($Sha256File)) {
    $matchedHash = Assert-Sha256FileMatches -TargetPath $resolvedAab -Sha256FilePath $Sha256File
    Write-Host "[OK] SHA-256 checksum matches file: $matchedHash"
    $reportLines.Add("ChecksumFile: PASS ($matchedHash)")
} else {
    $reportLines.Add("AAB-SHA256: $aabSha256")
}

# 1. bundletool validate
$null = Invoke-ExternalProcessChecked -FilePath $tools.JavaExe -ArgumentList @('-jar', $tools.BundletoolJar, 'validate', "--bundle=$resolvedAab") -TimeoutSeconds 120
Write-Host '[OK] bundletool validate passed.'
$reportLines.Add('BundletoolValidate: PASS')

# 2. bundletool dump manifest
$manifestRes = Invoke-ExternalProcessChecked -FilePath $tools.JavaExe -ArgumentList @('-jar', $tools.BundletoolJar, 'dump', 'manifest', "--bundle=$resolvedAab", '--module=base') -TimeoutSeconds 120
[xml]$xml = $manifestRes.Stdout
$androidNs = 'http://schemas.android.com/apk/res/android'

$actualPackage = [string]$xml.manifest.package
$actualVersionName = [string]$xml.manifest.GetAttribute('versionName', $androidNs)
$actualVersionCodeStr = [string]$xml.manifest.GetAttribute('versionCode', $androidNs)

if ([string]::IsNullOrWhiteSpace($actualPackage)) {
    throw 'AAB manifest is missing package attribute.'
}
if (-not [string]::IsNullOrWhiteSpace($PackageName) -and ($actualPackage -cne $PackageName)) {
    throw "AAB package mismatch: expected '$PackageName', actual '$actualPackage'."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedVersionName) -and ($actualVersionName -cne $ExpectedVersionName)) {
    throw "AAB versionName mismatch: expected '$ExpectedVersionName', actual '$actualVersionName'."
}
if ($null -ne $ExpectedVersionCode -and ($actualVersionCodeStr -ne [string]$ExpectedVersionCode)) {
    throw "AAB versionCode mismatch: expected '$ExpectedVersionCode', actual '$actualVersionCodeStr'."
}

$usesSdk = $xml.SelectSingleNode('/manifest/uses-sdk')
if ($null -eq $usesSdk) {
    throw 'Missing <uses-sdk> element in AAB manifest.'
}
$actualMinSdk = $usesSdk.GetAttribute('minSdkVersion', $androidNs)
$actualTargetSdk = $usesSdk.GetAttribute('targetSdkVersion', $androidNs)
if ($null -ne $ExpectedMinSdk -and ($actualMinSdk -ne [string]$ExpectedMinSdk)) {
    throw "AAB minSdkVersion mismatch: expected '$ExpectedMinSdk', actual '$actualMinSdk'."
}
if ($null -ne $ExpectedTargetSdk -and ($actualTargetSdk -ne [string]$ExpectedTargetSdk)) {
    throw "AAB targetSdkVersion mismatch: expected '$ExpectedTargetSdk', actual '$actualTargetSdk'."
}

foreach ($perm in $RequiredPermissions) {
    if ([string]::IsNullOrWhiteSpace($perm)) { continue }
    $permNode = $xml.SelectSingleNode("/manifest/uses-permission[@*[local-name()='name']='$perm']")
    if ($null -eq $permNode) {
        throw "AAB manifest missing required uses-permission: $perm"
    }
}

foreach ($metaKey in $RequiredMetaData.Keys) {
    $expectedVal = [string]$RequiredMetaData[$metaKey]
    $metaNode = $xml.SelectSingleNode("/manifest/application/meta-data[@*[local-name()='name']='$metaKey']")
    if ($null -eq $metaNode) {
        throw "AAB manifest missing required application meta-data: $metaKey"
    }
    if (-not [string]::IsNullOrEmpty($expectedVal)) {
        $actualVal = $metaNode.GetAttribute('value', $androidNs)
        if ($actualVal -cne $expectedVal) {
            throw "AAB manifest meta-data '$metaKey' mismatch: expected '$expectedVal', actual '$actualVal'"
        }
    }
}

foreach ($featKey in $RequiredFeatures.Keys) {
    $expectedReq = [string]$RequiredFeatures[$featKey]
    $featNode = $xml.SelectSingleNode("/manifest/uses-feature[@*[local-name()='name']='$featKey']")
    if ($null -eq $featNode) {
        throw "AAB manifest missing required uses-feature: $featKey"
    }
    if (-not [string]::IsNullOrEmpty($expectedReq)) {
        $actualReq = $featNode.GetAttribute('required', $androidNs)
        if ($actualReq -cne $expectedReq) {
            throw "AAB manifest uses-feature '$featKey' required mismatch: expected '$expectedReq', actual '$actualReq'"
        }
    }
}

Write-Host "[OK] Manifest verified: package=$actualPackage versionName=$actualVersionName versionCode=$actualVersionCodeStr minSdk=$actualMinSdk targetSdk=$actualTargetSdk"
$reportLines.Add("Manifest: PASS (package=$actualPackage, versionName=$actualVersionName, versionCode=$actualVersionCodeStr, minSdk=$actualMinSdk, targetSdk=$actualTargetSdk)")

# 3. Native ABIs, libil2cpp.so, and 16 KB ELF alignment
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedAab)
$nativePaths = New-Object System.Collections.Generic.List[string]
$checked16KbCount = 0
try {
    foreach ($entry in $archive.Entries) {
        if ($entry.FullName -notmatch '^base/lib/([^/]+)/.+\.so$') { continue }
        $abi = $Matches[1]
        if ($AllowedAbis -notcontains $abi) {
            throw "Unexpected ABI in AAB: '$abi' ($($entry.FullName)). Allowed: $($AllowedAbis -join ', ')"
        }
        $nativePaths.Add($entry.FullName)
        if (-not $Skip16KbCheck -and $abi -eq 'arm64-v8a') {
            $stream = $entry.Open()
            $memory = [System.IO.MemoryStream]::new()
            try {
                $stream.CopyTo($memory)
                $bytes = $memory.ToArray()
            } finally {
                $stream.Dispose()
                $memory.Dispose()
            }
            $null = Test-Elf16KbAlignment -Bytes $bytes -EntryPath $entry.FullName
            $checked16KbCount++
        }
    }
} finally {
    $archive.Dispose()
}

if ($nativePaths.Count -eq 0) {
    throw 'No native .so libraries found under base/lib/ in AAB.'
}
if (-not $SkipIl2cppCheck) {
    $il2cppLibs = @($nativePaths | Where-Object { $_ -like '*/libil2cpp.so' })
    if ($il2cppLibs.Count -eq 0) {
        throw 'Required IL2CPP library (libil2cpp.so) is missing from AAB.'
    }
}

Write-Host "[OK] Native libraries verified: count=$($nativePaths.Count) abis=$($AllowedAbis -join ',') 16KB_ELF_checked=$checked16KbCount"
$reportLines.Add("NativeLibs: PASS (count=$($nativePaths.Count), abis=$($AllowedAbis -join ','), 16KB_ELF_checked=$checked16KbCount)")

# 4. Signature & upload certificate SHA-256 verification
$certSha256 = ''
if (-not $SkipSignatureCheck) {
    $storePass = if (-not [string]::IsNullOrWhiteSpace($StorePasswordEnvVar)) { [Environment]::GetEnvironmentVariable($StorePasswordEnvVar) } else { '' }
    $hasKeystoreCreds = (-not [string]::IsNullOrWhiteSpace($KeystorePath)) -and (Test-Path -LiteralPath $KeystorePath -PathType Leaf) -and (-not [string]::IsNullOrWhiteSpace($storePass))
    $jarArgs = New-Object System.Collections.Generic.List[string]
    $jarArgs.Add('-J-Duser.language=en')
    $jarArgs.Add('-J-Duser.country=US')
    $jarArgs.Add('-verify')
    if ($hasKeystoreCreds) {
        $jarArgs.Add('-strict')
        $jarArgs.Add('-keystore')
        $jarArgs.Add((Resolve-Path -LiteralPath $KeystorePath).Path)
        $jarArgs.Add('-storepass:env')
        $jarArgs.Add($StorePasswordEnvVar)
    }
    $jarArgs.Add($resolvedAab)
    if ($hasKeystoreCreds -and -not [string]::IsNullOrWhiteSpace($KeyAlias)) {
        $jarArgs.Add($KeyAlias)
    }

    $verifyRes = Invoke-ExternalProcessChecked -FilePath $tools.JarsignerExe -ArgumentList $jarArgs.ToArray() -TimeoutSeconds 120
    if ($verifyRes.Stdout -notmatch '(?i)(jar verified\.|jar 已验证)') {
        throw "jarsigner did not confirm 'jar verified.':`n$($verifyRes.Stdout)"
    }
    $certSha256 = Get-AabCertificateSha256 -KeytoolExe $tools.KeytoolExe -AabPath $resolvedAab

    if (-not [string]::IsNullOrWhiteSpace($ExpectedCertificateSha256)) {
        $expectedNorm = Normalize-Sha256Hex -Raw $ExpectedCertificateSha256
        if ($certSha256 -cne $expectedNorm) {
            throw "Signing certificate SHA-256 mismatch! expected=$expectedNorm actual=$certSha256"
        }
    }
    $sigMode = if ($hasKeystoreCreds) { 'jarsigner -verify -strict -keystore' } else { 'jarsigner -verify' }
    Write-Host "[OK] Signature verified ($sigMode), Cert SHA-256: $certSha256"
    $reportLines.Add("Signature: PASS ($sigMode, CertSHA256=$certSha256)")
} else {
    Write-Host '[SKIP] Signature check skipped (-SkipSignatureCheck).'
    $reportLines.Add('Signature: SKIPPED')
}

if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $reportParent = Split-Path -Parent $ReportPath
    if (-not [string]::IsNullOrWhiteSpace($reportParent)) {
        New-Item -ItemType Directory -Path $reportParent -Force | Out-Null
    }
    $reportLines | Set-Content -LiteralPath $ReportPath -Encoding UTF8
}

Write-Host "AAB VERIFICATION PASSED: $resolvedAab (SHA-256: $aabSha256)"

[PSCustomObject]@{
    AabPath           = $resolvedAab
    SizeBytes         = $aabSize
    AabSha256         = $aabSha256
    PackageName       = $actualPackage
    VersionName       = $actualVersionName
    VersionCode       = $actualVersionCodeStr
    MinSdk            = $actualMinSdk
    TargetSdk         = $actualTargetSdk
    NativeLibCount    = $nativePaths.Count
    Checked16KbCount  = $checked16KbCount
    CertificateSha256 = $certSha256
}
