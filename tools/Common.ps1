Set-StrictMode -Version Latest

function Format-WindowsArgumentString([string[]]$Arguments) {
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        return ''
    }
    $formatted = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $Arguments) {
        if ($null -eq $arg) { continue }
        if ($arg -eq '') {
            $formatted.Add('""')
            continue
        }
        if ($arg -match '[\s"]') {
            $escaped = $arg -replace '(\\*)"', '$1$1\"'
            $escaped = $escaped -replace '(\\+)$', '$1$1'
            $formatted.Add('"' + $escaped + '"')
        } else {
            $formatted.Add($arg)
        }
    }
    return ($formatted -join ' ')
}

function Invoke-ExternalProcessChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$StdoutPath = '',
        [string]$StderrPath = '',
        [int]$TimeoutSeconds = 1800,
        [string]$WorkingDirectory = ''
    )

    $cleanupTemp = $false
    if ([string]::IsNullOrWhiteSpace($StdoutPath)) {
        $cleanupTemp = $true
        $StdoutPath = Join-Path ([IO.Path]::GetTempPath()) ("aab-proc-" + [Guid]::NewGuid().ToString('N') + '.stdout.txt')
    }
    if ([string]::IsNullOrWhiteSpace($StderrPath)) {
        $cleanupTemp = $true
        $StderrPath = Join-Path ([IO.Path]::GetTempPath()) ("aab-proc-" + [Guid]::NewGuid().ToString('N') + '.stderr.txt')
    }

    foreach ($p in @($StdoutPath, $StderrPath)) {
        $parent = Split-Path -Parent $p
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }

    $argString = Format-WindowsArgumentString -Arguments $ArgumentList
    $startParams = @{
        FilePath               = $FilePath
        WindowStyle            = 'Hidden'
        PassThru               = $true
        RedirectStandardOutput = $StdoutPath
        RedirectStandardError  = $StderrPath
    }
    if (-not [string]::IsNullOrWhiteSpace($argString)) {
        $startParams['ArgumentList'] = $argString
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startParams['WorkingDirectory'] = $WorkingDirectory
    }

    $proc = $null
    try {
        $proc = Start-Process @startParams
        $null = $proc.Handle
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            throw "Process timed out after ${TimeoutSeconds}s: $FilePath"
        }
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
        $stdoutText = if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) { Get-Content -LiteralPath $StdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderrText = if (Test-Path -LiteralPath $StderrPath -PathType Leaf) { Get-Content -LiteralPath $StderrPath -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($null -eq $exitCode -or $exitCode -ne 0) {
            $detail = (($stderrText + "`n" + $stdoutText).Trim())
            if ($detail.Length -gt 2000) {
                $detail = $detail.Substring($detail.Length - 2000)
            }
            throw "Process failed (ExitCode=$exitCode): $FilePath`n$detail"
        }
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Stdout   = $stdoutText
            Stderr   = $stderrText
        }
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
        if ($cleanupTemp) {
            foreach ($p in @($StdoutPath, $StderrPath)) {
                if (Test-Path -LiteralPath $p -PathType Leaf) {
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

function Normalize-Sha256Hex([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return ''
    }
    $clean = ($Raw -replace '[:-]|\s', '').ToUpperInvariant()
    if ($clean -notmatch '^[0-9A-F]{64}$') {
        throw "Invalid SHA-256 hex string: '$Raw'"
    }
    return $clean
}

function Assert-Sha256FileMatches {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Sha256FilePath
    )
    if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) {
        throw "File not found for SHA-256 check: $TargetPath"
    }
    if (-not (Test-Path -LiteralPath $Sha256FilePath -PathType Leaf)) {
        throw "Checksum file not found: $Sha256FilePath"
    }
    $rawLine = (Get-Content -LiteralPath $Sha256FilePath -Raw -Encoding UTF8).Trim()
    if ($rawLine -notmatch '^([0-9a-fA-F]{64})(?:\s+\*?(.+))?$') {
        throw "Invalid SHA-256 checksum file format in $Sha256FilePath"
    }
    $expected = $Matches[1].ToUpperInvariant()
    $listedName = if ($Matches[2]) { $Matches[2].Trim() } else { '' }
    $actualName = Split-Path -Leaf $TargetPath
    if (-not [string]::IsNullOrWhiteSpace($listedName) -and ($listedName -ne $actualName) -and ((Split-Path -Leaf $listedName) -ne $actualName)) {
        throw "Checksum file target mismatch: expected '$actualName', listed '$listedName'"
    }
    $actual = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $expected) {
        throw "SHA-256 mismatch for ${TargetPath}: expected=$expected actual=$actual"
    }
    return $actual
}

function Find-UnityCli([string]$OverridePath = '') {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $candidates.Add($OverridePath.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_CLI_PATH)) {
        $candidates.Add($env:UNITY_CLI_PATH.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Unity\bin\unity.exe'))
    }
    $cmdList = @(Get-Command unity.exe -All -ErrorAction SilentlyContinue)
    foreach ($cmd in $cmdList) {
        if ($cmd.Source -and ($cmd.Source -notmatch '[\\/]Editor[\\/]Unity\.exe$')) {
            $candidates.Add($cmd.Source)
        }
    }

    foreach ($c in $candidates) {
        if ([string]::IsNullOrWhiteSpace($c) -or -not (Test-Path -LiteralPath $c -PathType Leaf)) {
            continue
        }
        $resolved = (Resolve-Path -LiteralPath $c).Path
        if ($resolved -match '[\\/]Editor[\\/]Unity\.exe$') {
            continue
        }
        try {
            $res = Invoke-ExternalProcessChecked -FilePath $resolved -ArgumentList @('--version') -TimeoutSeconds 15
            $ver = ($res.Stdout + "`n" + $res.Stderr).Trim() -split "`r?`n" | Select-Object -First 1
            return [PSCustomObject]@{
                Path    = $resolved
                Version = $ver.Trim()
            }
        } catch {
            continue
        }
    }
    return $null
}

function Find-UnityEditor {
    param(
        [string]$EditorVersion = '',
        [string]$OverridePath = ''
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $candidates.Add($OverridePath.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_EDITOR_PATH)) {
        $candidates.Add($env:UNITY_EDITOR_PATH.Trim())
    }

    $hubDir = if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) { Join-Path $env:APPDATA 'UnityHub' } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($hubDir)) {
        $editorsJsonPath = Join-Path $hubDir 'editors.json'
        if ((Test-Path -LiteralPath $editorsJsonPath -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace($EditorVersion)) {
            try {
                $editorsData = Get-Content -LiteralPath $editorsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $prop = $editorsData.PSObject.Properties[$EditorVersion]
                if ($null -ne $prop -and $null -ne $prop.Value) {
                    $locProp = $prop.Value.PSObject.Properties['location']
                    if ($null -ne $locProp -and $locProp.Value) {
                        foreach ($loc in @($locProp.Value)) {
                            if ($loc) { $candidates.Add([string]$loc) }
                        }
                    }
                }
            } catch {}
        }

        $secondaryPath = Join-Path $hubDir 'secondaryInstallPath.json'
        if ((Test-Path -LiteralPath $secondaryPath -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace($EditorVersion)) {
            try {
                $secRoots = Get-Content -LiteralPath $secondaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($r in @($secRoots)) {
                    if ($r) {
                        $candidates.Add((Join-Path ([string]$r) "$EditorVersion\Editor\Unity.exe"))
                    }
                }
            } catch {}
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($EditorVersion)) {
        $candidates.Add("D:\Unity\$EditorVersion\Editor\Unity.exe")
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $candidates.Add((Join-Path $env:ProgramFiles "Unity\Hub\Editor\$EditorVersion\Editor\Unity.exe"))
        }
    }
    $candidates.Add('D:\Unity\Editor\Unity.exe')

    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

function Find-AndroidPlayerTools {
    param(
        [string]$UnityEditorPath = '',
        [string]$EditorVersion = '',
        [string]$OverrideAndroidPlayerPath = ''
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($OverrideAndroidPlayerPath)) {
        $candidates.Add($OverrideAndroidPlayerPath.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($env:UNITY_ANDROID_PLAYER_PATH)) {
        $candidates.Add($env:UNITY_ANDROID_PLAYER_PATH.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($UnityEditorPath)) {
        $editorDir = Split-Path -Parent $UnityEditorPath
        $candidates.Add((Join-Path $editorDir 'Data\PlaybackEngines\AndroidPlayer'))
    }
    if (-not [string]::IsNullOrWhiteSpace($EditorVersion)) {
        $candidates.Add("D:\Unity\$EditorVersion\Editor\Data\PlaybackEngines\AndroidPlayer")
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $candidates.Add((Join-Path $env:ProgramFiles "Unity\Hub\Editor\$EditorVersion\Editor\Data\PlaybackEngines\AndroidPlayer"))
        }
    }
    $candidates.Add('D:\Unity\Editor\Data\PlaybackEngines\AndroidPlayer')

    $playerPath = $null
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c -PathType Container)) {
            $playerPath = (Resolve-Path -LiteralPath $c).Path
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($playerPath)) {
        # Fallback: scan installed D:\Unity\*\Editor\Data\PlaybackEngines\AndroidPlayer or Hub folders
        $searchRoots = @('D:\Unity')
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $searchRoots += (Join-Path $env:ProgramFiles 'Unity\Hub\Editor')
        }
        foreach ($sr in $searchRoots) {
            if (-not (Test-Path -LiteralPath $sr -PathType Container)) { continue }
            $found = Get-ChildItem -LiteralPath $sr -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'Editor\Data\PlaybackEngines\AndroidPlayer' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
                Select-Object -First 1
            if ($found) {
                $playerPath = (Resolve-Path -LiteralPath $found).Path
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($playerPath)) {
        throw 'AndroidPlayer directory not found. Install Android Build Support in Unity Hub or specify -AndroidPlayerPath.'
    }

    $javaExe = Join-Path $playerPath 'OpenJDK\bin\java.exe'
    $jarsignerExe = Join-Path $playerPath 'OpenJDK\bin\jarsigner.exe'
    $keytoolExe = Join-Path $playerPath 'OpenJDK\bin\keytool.exe'
    foreach ($tool in @($javaExe, $jarsignerExe, $keytoolExe)) {
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
            throw "Required OpenJDK tool missing under AndroidPlayer: $tool"
        }
    }

    $toolsDir = Join-Path $playerPath 'Tools'
    $bundletoolJar = Get-ChildItem -LiteralPath $toolsDir -Filter 'bundletool-all-*.jar' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($null -eq $bundletoolJar) {
        throw "bundletool-all-*.jar not found under: $toolsDir"
    }

    return [PSCustomObject]@{
        AndroidPlayerPath = $playerPath
        JavaExe           = $javaExe
        JarsignerExe      = $jarsignerExe
        KeytoolExe        = $keytoolExe
        BundletoolJar     = $bundletoolJar.FullName
    }
}

function Read-UnityProjectMetadata {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [string]$ReleaseJsonRelativePath = ''
    )

    $project = (Resolve-Path -LiteralPath $ProjectPath).Path
    $pvPath = Join-Path $project 'ProjectSettings\ProjectVersion.txt'
    $psPath = Join-Path $project 'ProjectSettings\ProjectSettings.asset'
    if (-not (Test-Path -LiteralPath $pvPath -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $project 'Assets') -PathType Container)) {
        throw "Not a valid Unity project root (missing Assets or ProjectSettings\ProjectVersion.txt): $project"
    }

    $pvRaw = Get-Content -LiteralPath $pvPath -Raw -Encoding UTF8
    $editorVersion = ''
    if ($pvRaw -match '(?m)^m_EditorVersion:\s*(\S+)') {
        $editorVersion = $Matches[1].Trim()
    }

    $psVersion = ''
    $psVersionCode = $null
    $psPackage = ''
    $psMinSdk = $null
    $psTargetSdk = $null
    $psProductName = ''

    if (Test-Path -LiteralPath $psPath -PathType Leaf) {
        $psRaw = Get-Content -LiteralPath $psPath -Raw -Encoding UTF8
        if ($psRaw -match '(?m)^\s*productName:\s*(.+)$') {
            $psProductName = $Matches[1].Trim().Trim('"', "'")
        }
        if ($psRaw -match '(?m)^\s*bundleVersion:\s*(.+)$') {
            $psVersion = $Matches[1].Trim().Trim('"', "'")
        }
        if ($psRaw -match '(?m)^\s*AndroidBundleVersionCode:\s*(\d+)\s*$') {
            $psVersionCode = [int]$Matches[1]
        }
        if ($psRaw -match '(?m)^\s*AndroidMinSdkVersion:\s*(\d+)\s*$') {
            $psMinSdk = [int]$Matches[1]
        }
        if ($psRaw -match '(?m)^\s*AndroidTargetSdkVersion:\s*(\d+)\s*$') {
            $psTargetSdk = [int]$Matches[1]
        }
        if ($psRaw -match '(?ms)^\s*applicationIdentifier:\s*\r?\n(?:\s+(?!Android:)[A-Za-z0-9_]+:[^\r\n]*\r?\n)*\s+Android:\s*([^\r\n]+)') {
            $psPackage = $Matches[1].Trim().Trim('"', "'")
        }
    }

    $releasePath = ''
    if (-not [string]::IsNullOrWhiteSpace($ReleaseJsonRelativePath)) {
        $candidate = if ([IO.Path]::IsPathRooted($ReleaseJsonRelativePath)) { $ReleaseJsonRelativePath } else { Join-Path $project $ReleaseJsonRelativePath }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $releasePath = (Resolve-Path -LiteralPath $candidate).Path
        }
    } else {
        $defaultCandidates = @(
            (Join-Path $project 'Assets\Resources\Release.json')
        )
        $discovered = @(Get-ChildItem -Path (Join-Path $project 'Assets') -Filter 'Release.json' -File -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            Select-Object -ExpandProperty FullName)
        foreach ($cand in ($defaultCandidates + $discovered)) {
            if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) {
                $releasePath = (Resolve-Path -LiteralPath $cand).Path
                break
            }
        }
    }

    $relVersion = ''
    $relCode = $null
    if (-not [string]::IsNullOrWhiteSpace($releasePath)) {
        $relJson = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $verProp = $relJson.PSObject.Properties['version']
        if ($null -ne $verProp -and $verProp.Value) {
            $relVersion = ([string]$verProp.Value).Trim()
        }
        foreach ($codeKey in @('androidVersionCode', 'versionCode')) {
            $cp = $relJson.PSObject.Properties[$codeKey]
            if ($null -ne $cp -and $null -ne $cp.Value -and ([string]$cp.Value -match '^\d+$')) {
                $relCode = [int]$cp.Value
                break
            }
        }
    }

    $projectName = if (-not [string]::IsNullOrWhiteSpace($psProductName)) { $psProductName } else { Split-Path -Leaf $project }
    $finalVersion = if (-not [string]::IsNullOrWhiteSpace($relVersion)) { $relVersion } else { $psVersion }
    $finalCode = if ($null -ne $relCode) { $relCode } else { $psVersionCode }

    return [PSCustomObject]@{
        ProjectPath     = $project
        ProjectName     = $projectName
        EditorVersion   = $editorVersion
        ReleaseJsonPath = $releasePath
        VersionName     = $finalVersion
        VersionCode     = $finalCode
        PackageName     = $psPackage
        MinSdkVersion   = $psMinSdk
        TargetSdkVersion = $psTargetSdk
    }
}

function Clear-GradleAapt2Cache {
    param(
        [Parameter(Mandatory = $true)][string]$AndroidPlayerPath,
        [Parameter(Mandatory = $true)][string]$JavaExe
    )

    $gradleLibDir = Join-Path $AndroidPlayerPath 'Tools\gradle\lib'
    if (Test-Path -LiteralPath $gradleLibDir -PathType Container) {
        $gradleJar = Get-ChildItem -LiteralPath $gradleLibDir -Filter 'gradle-launcher-*.jar' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ((Test-Path -LiteralPath $JavaExe -PathType Leaf) -and ($null -ne $gradleJar)) {
            Write-Host 'Stopping stale Gradle daemons before AAB build...'
            try {
                $null = Invoke-ExternalProcessChecked -FilePath $JavaExe -ArgumentList @('-classpath', $gradleJar.FullName, 'org.gradle.launcher.GradleMain', '--stop') -TimeoutSeconds 30
            } catch {
                Write-Warning "Gradle --stop returned non-zero (continuing): $($_.Exception.Message)"
            }
        }
    }

    $gradleHome = if (-not [string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME)) { $env:GRADLE_USER_HOME } else { Join-Path $env:USERPROFILE '.gradle' }
    $cachesRoot = Join-Path $gradleHome 'caches'
    if (Test-Path -LiteralPath $cachesRoot -PathType Container) {
        $cacheVersions = @(Get-ChildItem -LiteralPath $cachesRoot -Directory -ErrorAction SilentlyContinue)
        foreach ($cv in $cacheVersions) {
            $transformsDir = Join-Path $cv.FullName 'transforms'
            if (-not (Test-Path -LiteralPath $transformsDir -PathType Container)) { continue }
            $tDirs = @(Get-ChildItem -LiteralPath $transformsDir -Directory -ErrorAction SilentlyContinue)
            foreach ($td in $tDirs) {
                $hasAapt2 = @(Get-ChildItem -LiteralPath $td.FullName -Recurse -Filter 'aapt2*' -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($hasAapt2.Count -gt 0) {
                    Remove-Item -LiteralPath $td.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "Cleared cached Gradle aapt2 transform ($($cv.Name)): $($td.Name)"
                }
            }
        }
    }
}

function Test-Elf16KbAlignment {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$EntryPath
    )

    if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 127 -or $Bytes[1] -ne 69 -or $Bytes[2] -ne 76 -or $Bytes[3] -ne 70 -or $Bytes[4] -ne 2 -or $Bytes[5] -ne 1) {
        throw "Not a little-endian ELF64 library in AAB: $EntryPath"
    }
    if ([BitConverter]::ToUInt16($Bytes, 18) -ne 183) {
        throw "Not an AArch64 (ARM64) ELF library in AAB: $EntryPath"
    }

    $phoff = [BitConverter]::ToUInt64($Bytes, 32)
    $phentsize = [BitConverter]::ToUInt16($Bytes, 54)
    $phnum = [BitConverter]::ToUInt16($Bytes, 56)
    if ($phentsize -lt 56) {
        throw "Invalid ELF64 program header entry size ($phentsize) in $EntryPath"
    }

    $loadSegments = 0
    for ($i = 0; $i -lt $phnum; $i++) {
        $offset = [int]($phoff + ([uint64]$i * [uint64]$phentsize))
        if ($offset + 56 -gt $Bytes.Length) {
            throw "Truncated ELF program header in $EntryPath"
        }
        $pType = [BitConverter]::ToUInt32($Bytes, $offset)
        if ($pType -ne 1) { continue }
        $loadSegments++
        $fileOffset = [BitConverter]::ToUInt64($Bytes, $offset + 8)
        $vaddr = [BitConverter]::ToUInt64($Bytes, $offset + 16)
        $align = [BitConverter]::ToUInt64($Bytes, $offset + 48)
        if ($align -lt 16384 -or ($fileOffset % 16384) -ne ($vaddr % 16384)) {
            throw "ELF 16 KB page alignment check failed for $EntryPath (align=$align, offset=$fileOffset, vaddr=$vaddr)"
        }
    }

    if ($loadSegments -eq 0) {
        throw "No PT_LOAD segments found in $EntryPath"
    }

    return $loadSegments
}

function Remove-AabSigningEntries([string]$AabPath) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($AabPath, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $signingEntries = @($archive.Entries | Where-Object {
            $_.FullName -match '^META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC)|SIG-[^/]+)$'
        })
        foreach ($entry in $signingEntries) {
            $entry.Delete()
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-AabCertificateSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$KeytoolExe,
        [Parameter(Mandatory = $true)][string]$AabPath
    )
    $res = Invoke-ExternalProcessChecked -FilePath $KeytoolExe -ArgumentList @('-J-Duser.language=en', '-J-Duser.country=US', '-printcert', '-jarfile', $AabPath) -TimeoutSeconds 60
    $combined = ($res.Stdout + "`n" + $res.Stderr)
    if ($combined -match 'SHA256:\s*([0-9A-Fa-f:\s]{64,120})') {
        $hex = ($Matches[1] -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        if ($hex.Length -ge 64) {
            return $hex.Substring(0, 64)
        }
    }
    throw "Failed to extract SHA-256 certificate fingerprint from AAB: $AabPath"
}

function Get-ConfigProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Wipe-FileSecurely([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        $fi = Get-Item -LiteralPath $Path
        if ($fi.Length -gt 0 -and $fi.Length -lt 64MB) {
            $zeros = New-Object byte[] ([int]$fi.Length)
            [IO.File]::WriteAllBytes($fi.FullName, $zeros)
        }
    } finally {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}
