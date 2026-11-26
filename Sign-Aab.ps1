[CmdletBinding()]
param(
    [switch]$GenerateKeystore,
    [switch]$ExportCertInfo,
    [string]$InputAab = '',
    [string]$OutputAab = '',
    [Parameter(Mandatory = $true)][string]$KeystorePath,
    [Parameter(Mandatory = $true)][string]$KeyAlias,
    [string]$DName = 'CN=UnityApp, O=Developer, C=CN',
    [string]$ExpectedCertificateSha256 = '',
    [string]$StorePasswordEnvVar = 'UNITY_AAB_STORE_PASSWORD',
    [string]$KeyPasswordEnvVar = 'UNITY_AAB_KEY_PASSWORD',
    [string]$AndroidPlayerPath = '',
    [string]$UnityEditorPath = '',
    [string]$SignatureReportPath = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'tools\Common.ps1')

$tools = Find-AndroidPlayerTools -UnityEditorPath $UnityEditorPath -OverrideAndroidPlayerPath $AndroidPlayerPath

$tempStoreSet = $false
$tempKeySet = $false
$tempCert = Join-Path ([IO.Path]::GetTempPath()) ("aab-cert-" + [Guid]::NewGuid().ToString('N') + '.der')
$tempWorkAab = Join-Path ([IO.Path]::GetTempPath()) ("aab-sign-" + [Guid]::NewGuid().ToString('N') + '.aab')

function Resolve-PasswordToEnv {
    param(
        [string]$EnvVarName,
        [string]$PromptText,
        [switch]$Confirm
    )
    $existing = [Environment]::GetEnvironmentVariable($EnvVarName)
    if (-not [string]::IsNullOrEmpty($existing)) {
        return $false
    }
    $s1 = Read-Host $PromptText -AsSecureString
    $p1 = ([Net.NetworkCredential]::new('', $s1)).Password
    $s1.Dispose()
    if ([string]::IsNullOrEmpty($p1)) {
        throw 'Password cannot be empty.'
    }
    if ($Confirm) {
        if ($p1.Length -lt 6) {
            throw 'Keystore password must be at least 6 characters.'
        }
        $s2 = Read-Host 'Confirm keystore password' -AsSecureString
        $p2 = ([Net.NetworkCredential]::new('', $s2)).Password
        $s2.Dispose()
        if ($p1 -cne $p2) {
            $p1 = $null; $p2 = $null
            throw 'Passwords did not match.'
        }
        $p2 = $null
    }
    [Environment]::SetEnvironmentVariable($EnvVarName, $p1)
    $p1 = $null
    return $true
}

try {
    if ($GenerateKeystore) {
        $ksDir = Split-Path -Parent $KeystorePath
        if (-not [string]::IsNullOrWhiteSpace($ksDir)) {
            New-Item -ItemType Directory -Path $ksDir -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $KeystorePath -PathType Leaf) -and -not $Force) {
            throw "Keystore already exists: $KeystorePath (pass -Force to overwrite or omit -GenerateKeystore)"
        }
        if ((Test-Path -LiteralPath $KeystorePath -PathType Leaf) -and $Force) {
            Remove-Item -LiteralPath $KeystorePath -Force
        }
        $tempStoreSet = Resolve-PasswordToEnv -EnvVarName $StorePasswordEnvVar -PromptText 'Set upload keystore password (min 6 chars)' -Confirm
        $null = Invoke-ExternalProcessChecked -FilePath $tools.KeytoolExe -ArgumentList @(
            '-genkeypair', '-v',
            '-keystore', $KeystorePath,
            '-storetype', 'PKCS12',
            '-alias', $KeyAlias,
            '-keyalg', 'RSA',
            '-keysize', '2048',
            '-validity', '10000',
            '-storepass:env', $StorePasswordEnvVar,
            '-keypass:env', $StorePasswordEnvVar,
            '-dname', $DName
        ) -TimeoutSeconds 60

        $null = Invoke-ExternalProcessChecked -FilePath $tools.KeytoolExe -ArgumentList @(
            '-exportcert',
            '-keystore', $KeystorePath,
            '-storepass:env', $StorePasswordEnvVar,
            '-alias', $KeyAlias,
            '-file', $tempCert
        ) -TimeoutSeconds 60
        $certSha256 = (Get-FileHash -LiteralPath $tempCert -Algorithm SHA256).Hash.ToUpperInvariant()

        $infoFile = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $KeystorePath).Path) ("$KeyAlias-public-info.txt")
        @(
            "KeystorePath: $((Resolve-Path -LiteralPath $KeystorePath).Path)"
            "KeyAlias: $KeyAlias"
            "Upload Certificate SHA-256: $certSha256"
        ) | Set-Content -LiteralPath $infoFile -Encoding UTF8

        Write-Host "Generated keystore: $KeystorePath"
        Write-Host "Upload Certificate SHA-256: $certSha256"
        Write-Host "Public certificate info saved (no passwords): $infoFile"
        return [PSCustomObject]@{
            KeystorePath      = (Resolve-Path -LiteralPath $KeystorePath).Path
            KeyAlias          = $KeyAlias
            CertificateSha256 = $certSha256
            PublicInfoPath    = $infoFile
        }
    }

    if (-not (Test-Path -LiteralPath $KeystorePath -PathType Leaf)) {
        throw "Keystore file not found: $KeystorePath"
    }
    $resolvedKeystore = (Resolve-Path -LiteralPath $KeystorePath).Path
    $tempStoreSet = Resolve-PasswordToEnv -EnvVarName $StorePasswordEnvVar -PromptText "Enter keystore password for $KeyAlias"

    $null = Invoke-ExternalProcessChecked -FilePath $tools.KeytoolExe -ArgumentList @(
        '-exportcert',
        '-keystore', $resolvedKeystore,
        '-storepass:env', $StorePasswordEnvVar,
        '-alias', $KeyAlias,
        '-file', $tempCert
    ) -TimeoutSeconds 60
    $certSha256 = (Get-FileHash -LiteralPath $tempCert -Algorithm SHA256).Hash.ToUpperInvariant()

    if (-not [string]::IsNullOrWhiteSpace($ExpectedCertificateSha256)) {
        $expectedNorm = Normalize-Sha256Hex -Raw $ExpectedCertificateSha256
        if ($certSha256 -cne $expectedNorm) {
            throw "Keystore certificate SHA-256 mismatch! expected=$expectedNorm actual=$certSha256"
        }
    }

    if ($ExportCertInfo) {
        Write-Host "Keystore: $resolvedKeystore (alias: $KeyAlias)"
        Write-Host "Upload Certificate SHA-256: $certSha256"
        return [PSCustomObject]@{
            KeystorePath      = $resolvedKeystore
            KeyAlias          = $KeyAlias
            CertificateSha256 = $certSha256
        }
    }

    if ([string]::IsNullOrWhiteSpace($InputAab) -or -not (Test-Path -LiteralPath $InputAab -PathType Leaf)) {
        throw "Input AAB not found: $InputAab"
    }
    if ([string]::IsNullOrWhiteSpace($OutputAab)) {
        $OutputAab = $InputAab
    }

    $resolvedInput = (Resolve-Path -LiteralPath $InputAab).Path
    Copy-Item -LiteralPath $resolvedInput -Destination $tempWorkAab -Force
    Remove-AabSigningEntries -AabPath $tempWorkAab

    $signArgs = New-Object System.Collections.Generic.List[string]
    $signArgs.Add('-keystore')
    $signArgs.Add($resolvedKeystore)
    $signArgs.Add('-storepass:env')
    $signArgs.Add($StorePasswordEnvVar)
    $keyPassVal = if (-not [string]::IsNullOrWhiteSpace($KeyPasswordEnvVar)) { [Environment]::GetEnvironmentVariable($KeyPasswordEnvVar) } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($keyPassVal)) {
        $signArgs.Add('-keypass:env')
        $signArgs.Add($KeyPasswordEnvVar)
    }
    $signArgs.Add($tempWorkAab)
    $signArgs.Add($KeyAlias)

    $null = Invoke-ExternalProcessChecked -FilePath $tools.JarsignerExe -ArgumentList $signArgs.ToArray() -TimeoutSeconds 180

    $verifyRes = Invoke-ExternalProcessChecked -FilePath $tools.JarsignerExe -ArgumentList @(
        '-J-Duser.language=en', '-J-Duser.country=US',
        '-verify', '-strict',
        '-keystore', $resolvedKeystore,
        '-storepass:env', $StorePasswordEnvVar,
        $tempWorkAab,
        $KeyAlias
    ) -TimeoutSeconds 120
    if ($verifyRes.Stdout -notmatch '(?i)(jar verified\.|jar 已验证)') {
        throw "Signed AAB failed strict verification:`n$($verifyRes.Stdout)"
    }

    $outParent = Split-Path -Parent $OutputAab
    if (-not [string]::IsNullOrWhiteSpace($outParent)) {
        New-Item -ItemType Directory -Path $outParent -Force | Out-Null
    }
    Move-Item -LiteralPath $tempWorkAab -Destination $OutputAab -Force
    $resolvedOutput = (Resolve-Path -LiteralPath $OutputAab).Path

    $aabHash = (Get-FileHash -LiteralPath $resolvedOutput -Algorithm SHA256).Hash.ToUpperInvariant()
    $shaFile = "$resolvedOutput.sha256"
    $aabLeaf = Split-Path -Leaf $resolvedOutput
    "$aabHash  $aabLeaf" | Set-Content -LiteralPath $shaFile -Encoding ASCII

    if (-not [string]::IsNullOrWhiteSpace($SignatureReportPath)) {
        $repParent = Split-Path -Parent $SignatureReportPath
        if (-not [string]::IsNullOrWhiteSpace($repParent)) {
            New-Item -ItemType Directory -Path $repParent -Force | Out-Null
        }
        @(
            $verifyRes.Stdout.Trim()
            "Certificate SHA-256: $certSha256"
            "AAB SHA-256: $aabHash"
        ) | Set-Content -LiteralPath $SignatureReportPath -Encoding UTF8
    }

    Write-Host "Signed AAB ready: $resolvedOutput"
    Write-Host "AAB SHA-256: $aabHash"
    Write-Host "Checksum file: $shaFile"

    [PSCustomObject]@{
        OutputAab         = $resolvedOutput
        Sha256File        = $shaFile
        AabSha256         = $aabHash
        CertificateSha256 = $certSha256
    }
} finally {
    if ($tempStoreSet) {
        [Environment]::SetEnvironmentVariable($StorePasswordEnvVar, $null)
    }
    if ($tempKeySet) {
        [Environment]::SetEnvironmentVariable($KeyPasswordEnvVar, $null)
    }
    Wipe-FileSecurely -Path $tempCert
    if (Test-Path -LiteralPath $tempWorkAab -PathType Leaf) {
        Remove-Item -LiteralPath $tempWorkAab -Force -ErrorAction SilentlyContinue
    }
}
