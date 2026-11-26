param(
    [string]$SampleAabPath = '',
    [string]$SamplePackageName = '',
    [string]$SampleVersionName = '',
    [Nullable[int]]$SampleMinSdk = $null,
    [Nullable[int]]$SampleTargetSdk = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$commonPath = Join-Path $repoRoot 'tools\Common.ps1'
$verifyScript = Join-Path $repoRoot 'Verify-Aab.ps1'
$signScript = Join-Path $repoRoot 'Sign-Aab.ps1'
$buildScript = Join-Path $repoRoot 'Build-Unity-Aab.ps1'
$setupScript = Join-Path $repoRoot 'Setup-GitHub-Runner.ps1'
$toolScript = Join-Path $repoRoot 'Unity-AAB-Tool.ps1'

$passed = 0
$failed = 0

function Run-TestCase([string]$Name, [scriptblock]$Body) {
    Write-Host "--- TEST: $Name ---"
    try {
        & $Body
        $script:passed++
        Write-Host "[PASS] $Name"
    } catch {
        $script:failed++
        Write-Host "[FAIL] $Name -> $($_.Exception.Message)"
    }
}

function New-SyntheticElf64 {
    param(
        [uint64]$Align,
        [uint64]$FileOffset,
        [uint64]$VAddr,
        [uint16]$Machine = 183
    )
    $buf = New-Object byte[] 128
    $buf[0] = 127; $buf[1] = 69; $buf[2] = 76; $buf[3] = 70; $buf[4] = 2; $buf[5] = 1; $buf[6] = 1
    [BitConverter]::GetBytes($Machine).CopyTo($buf, 18)
    [BitConverter]::GetBytes([uint64]64).CopyTo($buf, 32)
    [BitConverter]::GetBytes([uint16]56).CopyTo($buf, 54)
    [BitConverter]::GetBytes([uint16]1).CopyTo($buf, 56)
    [BitConverter]::GetBytes([uint32]1).CopyTo($buf, 64)
    [BitConverter]::GetBytes($FileOffset).CopyTo($buf, 72)
    [BitConverter]::GetBytes($VAddr).CopyTo($buf, 80)
    [BitConverter]::GetBytes($Align).CopyTo($buf, 112)
    return $buf
}

function Invoke-PsChild([string[]]$FileArgs) {
    $psExe = (Get-Command powershell.exe).Source
    $argString = '-NoProfile -ExecutionPolicy Bypass ' + (($FileArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' ')
    $tmpOut = Join-Path ([IO.Path]::GetTempPath()) ('pschild-' + [Guid]::NewGuid().ToString('N') + '.stdout.txt')
    $tmpErr = Join-Path ([IO.Path]::GetTempPath()) ('pschild-' + [Guid]::NewGuid().ToString('N') + '.stderr.txt')
    $p = $null
    try {
        $p = Start-Process -FilePath $psExe -ArgumentList $argString -WindowStyle Hidden -PassThru -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        $null = $p.Handle
        if (-not $p.WaitForExit(120000)) {
            try { $p.Kill() } catch {}
            throw "Child PowerShell process timed out after 120s: $argString"
        }
        $p.WaitForExit()
        $out = if (Test-Path -LiteralPath $tmpOut -PathType Leaf) { Get-Content -LiteralPath $tmpOut -Raw -ErrorAction SilentlyContinue } else { '' }
        $err = if (Test-Path -LiteralPath $tmpErr -PathType Leaf) { Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue } else { '' }
        return [PSCustomObject]@{
            ExitCode = $p.ExitCode
            Output   = (($out + "`n" + $err).Trim())
        }
    } finally {
        if ($null -ne $p) { $p.Dispose() }
        foreach ($f in @($tmpOut, $tmpErr)) {
            if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

$tempWork = Join-Path ([IO.Path]::GetTempPath()) ('aab-wf-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempWork -Force | Out-Null

try {
    # 1. PowerShell AST syntax check
    Run-TestCase 'PowerShell AST syntax validation across all .ps1 files' {
        $psFiles = @(Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -Recurse -File)
        if ($psFiles.Count -lt 7) { throw "Unexpected low .ps1 count: $($psFiles.Count)" }
        foreach ($f in $psFiles) {
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) {
                $msgs = ($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
                throw "Syntax error in $($f.FullName): $msgs"
            }
        }
        Write-Host "  Parsed $($psFiles.Count) PowerShell scripts with 0 syntax errors."
    }

    # 2. JSON config schema parse & privacy check
    Run-TestCase 'config/project.example.json schema and privacy check' {
        $cfgFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'config') -Filter '*.json' -File)
        if ($cfgFiles.Count -ne 1 -or $cfgFiles[0].Name -ne 'project.example.json') {
            throw 'Tracked config/ folder must contain only project.example.json (place real configs in local-config/).'
        }
        $cfg = Get-Content -LiteralPath $cfgFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($req in @('projectName', 'projectPath', 'build', 'signing', 'verify', 'release')) {
            if ($null -eq $cfg.PSObject.Properties[$req]) {
                throw "Missing required key '$req' in project.example.json"
            }
        }
        if ($cfg.verify.allowedAbis -notcontains 'arm64-v8a') {
            throw 'Expected arm64-v8a in verify.allowedAbis'
        }
    }

    # 3. Unified launcher & workflow template YAML validation
    Run-TestCase 'Unified Unity-AAB-Tool.cmd and self-hosted workflow template validation' {
        $cmdPath = Join-Path $repoRoot 'Unity-AAB-Tool.cmd'
        if (-not (Test-Path -LiteralPath $cmdPath -PathType Leaf)) { throw 'Missing Unity-AAB-Tool.cmd' }
        $tplSelf = Join-Path $repoRoot 'workflows\caller-selfhosted-aab.yml'
        if (-not (Test-Path -LiteralPath $tplSelf -PathType Leaf)) { throw 'Missing workflows/caller-selfhosted-aab.yml' }

        $pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($null -ne $pythonCmd) {
            $pyCheck = @'
import sys, yaml
with open(sys.argv[1], "r", encoding="utf-8") as f:
    doc = yaml.safe_load(f)
assert isinstance(doc, dict) and "jobs" in doc
runs_on = doc["jobs"]["build-and-sign-aab"]["runs-on"]
assert "self-hosted" in runs_on and "__RUNNER_LABEL__" in runs_on
print("PyYAML verified self-hosted template cleanly.")
'@
            $pyFile = Join-Path $tempWork 'check_tpl.py'
            Set-Content -LiteralPath $pyFile -Value $pyCheck -Encoding UTF8
            $res = & $pythonCmd.Source $pyFile $tplSelf 2>&1
            if ($LASTEXITCODE -ne 0) { throw "YAML validation failed: $res" }
            Write-Host "  $res"
        }
    }

    # 4. Synthetic Unity project metadata, -Action checkenv, and Setup-GitHub-Runner -DryRun
    $syntheticProj = Join-Path $tempWork 'SyntheticUnityGame'
    Run-TestCase 'Synthetic Unity project metadata, Unity-AAB-Tool -Action checkenv, and Setup-GitHub-Runner -DryRun' {
        $detectedEditorVer = '6000.3.28f1'
        if (-not (Test-Path -LiteralPath "D:\Unity\$detectedEditorVer\Editor\Unity.exe")) {
            $foundDir = Get-ChildItem -Path 'D:\Unity', "$env:ProgramFiles\Unity\Hub\Editor" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $foundDir) { $detectedEditorVer = $foundDir.Name }
        }

        New-Item -ItemType Directory -Path (Join-Path $syntheticProj 'Assets\Resources') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $syntheticProj 'ProjectSettings') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $syntheticProj 'ProjectSettings\ProjectVersion.txt') -Value "m_EditorVersion: $detectedEditorVer" -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $syntheticProj 'Assets\Resources\Release.json') -Value '{"version":"1.2.3","versionCode":42}' -Encoding UTF8
        $psAsset = @"
PlayerSettings:
  productName: SyntheticGame
  bundleVersion: 1.2.3
  applicationIdentifier:
    Android: com.example.synthetic
  AndroidBundleVersionCode: 40
  AndroidMinSdkVersion: 26
  AndroidTargetSdkVersion: 36
"@
        Set-Content -LiteralPath (Join-Path $syntheticProj 'ProjectSettings\ProjectSettings.asset') -Value $psAsset -Encoding UTF8

        $envInfo = & $toolScript -Action checkenv -ProjectPath $syntheticProj
        if ($envInfo.PackageName -ne 'com.example.synthetic') { throw "Unexpected PackageName: $($envInfo.PackageName)" }
        if ($envInfo.VersionName -ne '1.2.3' -or [int]$envInfo.VersionCode -ne 42) { throw "Unexpected version: $($envInfo.VersionName) ($($envInfo.VersionCode))" }

        $setupInfo = & $setupScript -ProjectPath $syntheticProj -Repo 'example-org/SyntheticGame' -DryRun
        if (-not $setupInfo.DryRun -or $setupInfo.RunnerLabel -ne 'unity-syntheticgame') {
            throw "Unexpected Setup-GitHub-Runner DryRun output: $($setupInfo | Out-String)"
        }
    }

    # 5. Synthetic ELF 16 KB alignment unit tests
    Run-TestCase 'Synthetic ELF 16KB alignment positive and negative unit tests' {
        . $commonPath
        $validElf = New-SyntheticElf64 -Align 16384 -FileOffset 16384 -VAddr 16384
        $segs = Test-Elf16KbAlignment -Bytes $validElf -EntryPath 'base/lib/arm64-v8a/libvalid.so'
        if ($segs -ne 1) { throw "Expected 1 PT_LOAD segment, got $segs" }

        $badAlign = New-SyntheticElf64 -Align 4096 -FileOffset 4096 -VAddr 4096
        $threw = $false
        try { $null = Test-Elf16KbAlignment -Bytes $badAlign -EntryPath 'base/lib/arm64-v8a/lib4k.so' } catch { $threw = $true }
        if (-not $threw) { throw '4KB-aligned ELF should have failed Test-Elf16KbAlignment' }

        $badModulo = New-SyntheticElf64 -Align 16384 -FileOffset 4096 -VAddr 16384
        $threw2 = $false
        try { $null = Test-Elf16KbAlignment -Bytes $badModulo -EntryPath 'base/lib/arm64-v8a/libbadmod.so' } catch { $threw2 = $true }
        if (-not $threw2) { throw 'Mismatched fileOffset/vaddr modulo 16KB ELF should have failed' }
    }

    # 6. Sign-Aab.ps1 keystore generation, export cert info, and archive signing test
    Run-TestCase 'Sign-Aab.ps1 keystore generation, cert info export, and jar/zip signing round-trip' {
        . $commonPath
        $ksPath = Join-Path $tempWork 'test-upload.p12'
        $ksAlias = 'test-upload'
        $testPwVar = '_TEST_UNITY_AAB_PW_' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
        [Environment]::SetEnvironmentVariable($testPwVar, 'TestPass!2026')
        try {
            $genRes = & $signScript -GenerateKeystore -KeystorePath $ksPath -KeyAlias $ksAlias -StorePasswordEnvVar $testPwVar
            if ($genRes.CertificateSha256 -notmatch '^[0-9A-F]{64}$') { throw 'Keystore generation did not output valid cert SHA-256' }

            $expRes = & $signScript -ExportCertInfo -KeystorePath $ksPath -KeyAlias $ksAlias -ExpectedCertificateSha256 $genRes.CertificateSha256 -StorePasswordEnvVar $testPwVar
            if ($expRes.CertificateSha256 -cne $genRes.CertificateSha256) { throw 'ExportCertInfo mismatch' }

            # Create tiny zip archive to exercise Sign-Aab signing + strict jarsigner check without external binaries
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $payloadDir = Join-Path $tempWork 'payload'
            New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $payloadDir 'hello.txt') -Value 'aab-signing-fixture' -Encoding UTF8
            $unsignedZip = Join-Path $tempWork 'unsigned.aab'
            [System.IO.Compression.ZipFile]::CreateFromDirectory($payloadDir, $unsignedZip)

            $signedZip = Join-Path $tempWork 'signed.aab'
            $signRes = & $signScript -InputAab $unsignedZip -OutputAab $signedZip -KeystorePath $ksPath -KeyAlias $ksAlias -ExpectedCertificateSha256 $genRes.CertificateSha256 -StorePasswordEnvVar $testPwVar
            $matchedHash = Assert-Sha256FileMatches -TargetPath $signedZip -Sha256FilePath $signRes.Sha256File
            if ($matchedHash -cne $signRes.AabSha256) { throw 'SHA-256 file mismatch' }

            $tools = Find-AndroidPlayerTools
            $extractedSha = Get-AabCertificateSha256 -KeytoolExe $tools.KeytoolExe -AabPath $signedZip
            if ($extractedSha -cne $genRes.CertificateSha256) { throw 'Extracted cert SHA-256 mismatch' }
        } finally {
            [Environment]::SetEnvironmentVariable($testPwVar, $null)
        }
    }

    # 7. Optional full Verify-Aab + negative gates when -SampleAabPath (or UNITY_AAB_TEST_SAMPLE) is supplied
    $sample = if (-not [string]::IsNullOrWhiteSpace($SampleAabPath)) { $SampleAabPath } else { [string]$env:UNITY_AAB_TEST_SAMPLE }
    if (-not [string]::IsNullOrWhiteSpace($sample) -and (Test-Path -LiteralPath $sample -PathType Leaf)) {
        Run-TestCase 'Optional real AAB Verify-Aab positive & negative gate checks' {
            $verArgs = @{ AabPath = $sample }
            if (-not [string]::IsNullOrWhiteSpace($SamplePackageName)) { $verArgs['PackageName'] = $SamplePackageName }
            if (-not [string]::IsNullOrWhiteSpace($SampleVersionName)) { $verArgs['ExpectedVersionName'] = $SampleVersionName }
            if ($null -ne $SampleMinSdk) { $verArgs['ExpectedMinSdk'] = $SampleMinSdk }
            if ($null -ne $SampleTargetSdk) { $verArgs['ExpectedTargetSdk'] = $SampleTargetSdk }

            $res = & $verifyScript @verArgs
            if ($res.Checked16KbCount -lt 1) { throw 'Expected >= 1 arm64 .so checked for 16KB ELF alignment' }

            $rPkg = Invoke-PsChild @('-File', $verifyScript, '-AabPath', $sample, '-PackageName', 'com.invalid.wrongpkg')
            if ($rPkg.ExitCode -eq 0) { throw 'Verify-Aab should fail on wrong PackageName' }

            $rCert = Invoke-PsChild @('-File', $verifyScript, '-AabPath', $sample, '-ExpectedCertificateSha256', ('0' * 64))
            if ($rCert.ExitCode -eq 0) { throw 'Verify-Aab should fail on wrong ExpectedCertificateSha256' }
        }
    } else {
        Write-Host '[INFO] No -SampleAabPath supplied; skipping optional real-AAB bundletool integration check.'
    }

    # 8. GitHub remote auto-detection, gh CLI presence, and zero preset-menu check
    Run-TestCase 'GitHub remote auto-detection, gh CLI binary check, and zero preset-menu check' {
        . $commonPath
        $sshRepo = Resolve-GitHubRepoFromRemoteUrl 'git@github.com:example-org/SampleGame.git'
        $httpsRepo = Resolve-GitHubRepoFromRemoteUrl 'https://github.com/example-org/SampleGame.git'
        if ($sshRepo -ne 'example-org/SampleGame' -or $httpsRepo -ne 'example-org/SampleGame') {
            throw "Remote URL parsing mismatch: ssh='$sshRepo' https='$httpsRepo'"
        }

        $gitProj = Join-Path $tempWork 'GitAutoDetectGame'
        New-Item -ItemType Directory -Path (Join-Path $gitProj 'Assets\Resources') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $gitProj 'ProjectSettings') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $gitProj 'ProjectSettings\ProjectVersion.txt') -Value 'm_EditorVersion: 6000.3.28f1' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $gitProj 'Assets\Resources\Release.json') -Value '{"version":"1.0.0","versionCode":1}' -Encoding UTF8
        $null = Invoke-ExternalProcessChecked -FilePath 'git.exe' -ArgumentList @('-C', $gitProj, 'init') -TimeoutSeconds 15
        $null = Invoke-ExternalProcessChecked -FilePath 'git.exe' -ArgumentList @('-C', $gitProj, 'remote', 'add', 'origin', 'git@github.com:example-org/AutoDetectedGame.git') -TimeoutSeconds 15

        $autoSetup = & $setupScript -ProjectPath $gitProj -DryRun
        if (-not $autoSetup.DryRun -or $autoSetup.Repo -ne 'example-org/AutoDetectedGame' -or $autoSetup.RunnerLabel -ne 'unity-gitautodetectgame') {
            throw "Auto-detect repo failed: $($autoSetup | Out-String)"
        }

        $toolRaw = Get-Content -LiteralPath $toolScript -Raw -Encoding UTF8
        $setupRaw = Get-Content -LiteralPath $setupScript -Raw -Encoding UTF8
        if ($toolRaw -match 'Get-PresetConfigs' -or $setupRaw -match 'Select Target Unity Project') {
            throw 'Preset project listing must remain removed from public UI scripts'
        }
        if ($toolRaw -match '请选择操作 \[0-5\]' -or $toolRaw -match 'while \(\$true\)') {
            throw 'Interactive 0-5 multi-option menu must remain removed in favor of 1-click local build'
        }
        if ($setupRaw -notmatch '--git-protocol\s+ssh' -or $setupRaw -notmatch '--skip-ssh-key') {
            throw 'gh auth login must specify --git-protocol ssh and --skip-ssh-key to avoid interactive SSH key upload prompts'
        }

        $ghPath = 'C:\Program Files\GitHub CLI\gh.exe'
        if (Test-Path -LiteralPath $ghPath -PathType Leaf) {
            $ghVer = Invoke-ExternalProcessChecked -FilePath $ghPath -ArgumentList @('--version') -TimeoutSeconds 15
            if ($ghVer.Stdout -notmatch 'gh version') { throw 'Unexpected gh --version output' }
            Write-Host "  Detected gh CLI: $($ghVer.Stdout.Trim().Split("`n")[0])"
        }
    }
} finally {
    if (Test-Path -LiteralPath $tempWork -PathType Container) {
        Remove-Item -LiteralPath $tempWork -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host "=== Test Summary: PASSED=$passed FAILED=$failed ==="
if ($failed -gt 0) {
    exit 1
}
exit 0
