[CmdletBinding()]
param(
    [ValidateSet('', 'build', 'setup', 'keygen', 'certinfo', 'verify', 'checkenv')][string]$Action = '',
    [string]$ConfigPath = '',
    [string]$ProjectPath = '',
    [string]$AabPath = '',
    [string]$KeystorePath = '',
    [string]$KeyAlias = '',
    [string]$Repo = '',
    [switch]$QaSigning,
    [switch]$PrepareOnly,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'tools\Common.ps1')

function Select-ProjectPath([string]$PromptTitle) {
    Write-Host ''
    Write-Host "=== $PromptTitle ==="
    $chosen = Prompt-DirectoryOrBrowse `
        -PromptText '请输入 Unity 工程根目录路径（直接回车打开文件夹选择框）' `
        -DialogDescription '选择 Unity 工程根目录（包含 Assets 和 ProjectSettings）'
    if ([string]::IsNullOrWhiteSpace($chosen)) { return $null }
    $matchedCfg = Find-LocalConfigForProject -ToolRoot $PSScriptRoot -ProjectPath $chosen
    return [PSCustomObject]@{
        ConfigPath  = $matchedCfg
        ProjectPath = $chosen
    }
}

function Select-AabFile([string]$Title) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = $Title
    $dlg.Filter = 'Android App Bundle (*.aab)|*.aab|All files (*.*)|*.*'
    try {
        if ($dlg.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return '' }
        return $dlg.FileName
    } finally {
        $dlg.Dispose()
    }
}

function Invoke-Action([string]$SelectedAction) {
    switch ($SelectedAction) {
        'build' {
            $params = @{}
            if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $params['ConfigPath'] = $ConfigPath }
            if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) { $params['ProjectPath'] = $ProjectPath }
            if ($QaSigning) { $params['QaSigning'] = $true }
            if ($PrepareOnly) { $params['PrepareOnly'] = $true }

            if ([string]::IsNullOrWhiteSpace($ConfigPath) -and [string]::IsNullOrWhiteSpace($ProjectPath)) {
                $target = Select-ProjectPath '选择要出包的 Unity 工程'
                if ($null -eq $target) { return }
                if ($target.ConfigPath) { $params['ConfigPath'] = $target.ConfigPath }
                $params['ProjectPath'] = $target.ProjectPath

                if (-not $QaSigning -and -not $PrepareOnly) {
                    Write-Host ''
                    Write-Host '选择构建模式:'
                    Write-Host '  [1] 正式上传密钥签名并验包 (需要上传 .p12 与密码)'
                    Write-Host '  [2] 本地 QA 临时签名并验包 (-QaSigning，用于测试结构与 16KB ELF)'
                    Write-Host '  [3] 仅导出未签名包并验结构 (-PrepareOnly)'
                    $mode = (Read-Host '请选择 [1/2/3]').Trim()
                    if ($mode -eq '2') { $params['QaSigning'] = $true }
                    elseif ($mode -eq '3') { $params['PrepareOnly'] = $true }
                }
            }
            & (Join-Path $PSScriptRoot 'Build-Unity-Aab.ps1') @params
        }
        'setup' {
            $params = @{}
            if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $params['ConfigPath'] = $ConfigPath }
            if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) { $params['ProjectPath'] = $ProjectPath }
            if (-not [string]::IsNullOrWhiteSpace($Repo)) { $params['Repo'] = $Repo }
            if (-not [string]::IsNullOrWhiteSpace($KeystorePath)) { $params['KeystorePath'] = $KeystorePath }
            if (-not [string]::IsNullOrWhiteSpace($KeyAlias)) { $params['KeyAlias'] = $KeyAlias }
            if ($NonInteractive) { $params['NonInteractive'] = $true }
            & (Join-Path $PSScriptRoot 'Setup-GitHub-Runner.ps1') @params
        }
        'keygen' {
            $ks = $KeystorePath
            $alias = $KeyAlias
            if ([string]::IsNullOrWhiteSpace($ks)) {
                $defaultKs = Join-Path $env:USERPROFILE '.unity-aab-keys\app-upload.p12'
                $inKs = (Read-Host "请输入新密钥库保存路径 (回车默认: $defaultKs)").Trim()
                $ks = if ([string]::IsNullOrWhiteSpace($inKs)) { $defaultKs } else { $inKs }
            }
            if ([string]::IsNullOrWhiteSpace($alias)) {
                $inAlias = (Read-Host '请输入 Key Alias (回车默认: upload-key)').Trim()
                $alias = if ([string]::IsNullOrWhiteSpace($inAlias)) { 'upload-key' } else { $inAlias }
            }
            & (Join-Path $PSScriptRoot 'Sign-Aab.ps1') -GenerateKeystore -KeystorePath $ks -KeyAlias $alias
        }
        'certinfo' {
            $ks = $KeystorePath
            $alias = $KeyAlias
            if ([string]::IsNullOrWhiteSpace($ks)) {
                $ks = (Read-Host '请输入现有 .p12 / .keystore 路径').Trim()
            }
            if ([string]::IsNullOrWhiteSpace($alias)) {
                $alias = (Read-Host '请输入 Key Alias').Trim()
            }
            & (Join-Path $PSScriptRoot 'Sign-Aab.ps1') -ExportCertInfo -KeystorePath $ks -KeyAlias $alias
        }
        'verify' {
            $aab = $AabPath
            if ([string]::IsNullOrWhiteSpace($aab)) {
                $aab = Select-AabFile '选择要检验的 .aab 文件'
                if ([string]::IsNullOrWhiteSpace($aab)) { return }
            }
            $params = @{ AabPath = $aab }
            if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $params['ConfigPath'] = $ConfigPath }
            $shaCandidate = "$aab.sha256"
            if (Test-Path -LiteralPath $shaCandidate -PathType Leaf) { $params['Sha256File'] = $shaCandidate }
            & (Join-Path $PSScriptRoot 'Verify-Aab.ps1') @params
        }
        'checkenv' {
            $params = @{ CheckEnv = $true }
            if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $params['ConfigPath'] = $ConfigPath }
            if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) { $params['ProjectPath'] = $ProjectPath }
            if ([string]::IsNullOrWhiteSpace($ConfigPath) -and [string]::IsNullOrWhiteSpace($ProjectPath)) {
                $target = Select-ProjectPath '选择要自检的 Unity 工程'
                if ($null -eq $target) { return }
                if ($target.ConfigPath) { $params['ConfigPath'] = $target.ConfigPath }
                $params['ProjectPath'] = $target.ProjectPath
            }
            & (Join-Path $PSScriptRoot 'Build-Unity-Aab.ps1') @params
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($Action)) {
    Invoke-Action $Action
    return
}

if ($NonInteractive) {
    throw 'Specify -Action when running with -NonInteractive.'
}

function Invoke-OneClickLocalAabBuild {
    Write-Host ''
    Write-Host '================================================='
    Write-Host '      Unity Android AAB 一键打包 (本地直接出包)'
    Write-Host '================================================='

    $target = Select-ProjectPath '选择 Unity 工程目录'
    if ($null -eq $target) { return }

    $meta = Read-UnityProjectMetadata -ProjectPath $target.ProjectPath
    $editorPath = Find-UnityEditor -EditorVersion $meta.EditorVersion
    if ([string]::IsNullOrWhiteSpace($editorPath)) {
        throw "未找到匹配 Unity $($meta.EditorVersion) 的编辑器，请确认 Unity Hub 已安装对应版本及 Android Build Support。"
    }
    $null = Find-AndroidPlayerTools -UnityEditorPath $editorPath -EditorVersion $meta.EditorVersion

    Write-Host ("[工程就绪] {0} | 包名: {1} | 版本: {2} (code {3}) | Unity {4}" -f `
        $meta.ProjectName, $meta.PackageName, $meta.VersionName, $meta.VersionCode, $meta.EditorVersion)

    $slug = ($meta.ProjectName -replace '[^A-Za-z0-9._-]+', '-').Trim('-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'app' }

    $defaultKs = Join-Path $env:USERPROFILE ".unity-aab-keys\$slug-upload.p12"
    $defaultAlias = "$slug-upload"
    $cfgKs = ''
    $cfgAlias = ''
    $cfgSha = ''
    if (-not [string]::IsNullOrWhiteSpace($target.ConfigPath) -and (Test-Path -LiteralPath $target.ConfigPath -PathType Leaf)) {
        $cfgObj = Get-Content -LiteralPath $target.ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $signCfg = Get-ConfigProperty -Object $cfgObj -Name 'signing' -Default $null
        $cfgKs = [string](Get-ConfigProperty -Object $signCfg -Name 'keystorePath' -Default '')
        $cfgAlias = [string](Get-ConfigProperty -Object $signCfg -Name 'keyAlias' -Default '')
        $cfgSha = [string](Get-ConfigProperty -Object $signCfg -Name 'expectedCertificateSha256' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($cfgKs)) { $defaultKs = $cfgKs }
        if (-not [string]::IsNullOrWhiteSpace($cfgAlias)) { $defaultAlias = $cfgAlias }
    }

    $resolvedKs = $KeystorePath
    if ([string]::IsNullOrWhiteSpace($resolvedKs)) {
        $inKs = (Read-Host "签名密钥路径 .p12（直接回车使用默认: $defaultKs）").Trim().Trim('"', "'")
        $resolvedKs = if ([string]::IsNullOrWhiteSpace($inKs)) { $defaultKs } else { $inKs }
    }

    $resolvedAlias = $KeyAlias
    if ([string]::IsNullOrWhiteSpace($resolvedAlias)) {
        if (-not [string]::IsNullOrWhiteSpace($cfgAlias) -and [string]::Equals($resolvedKs, $cfgKs, [StringComparison]::OrdinalIgnoreCase)) {
            $resolvedAlias = $cfgAlias
        } else {
            $inAlias = (Read-Host "Key Alias（直接回车使用默认: $defaultAlias）").Trim()
            $resolvedAlias = if ([string]::IsNullOrWhiteSpace($inAlias)) { $defaultAlias } else { $inAlias }
        }
    }

    $expectedCert = ''
    if (-not [string]::IsNullOrWhiteSpace($cfgSha) -and [string]::Equals($resolvedKs, $cfgKs, [StringComparison]::OrdinalIgnoreCase)) {
        $expectedCert = $cfgSha
    }

    $origStorePw = [Environment]::GetEnvironmentVariable('UNITY_AAB_STORE_PASSWORD')
    $hadStorePw = -not [string]::IsNullOrEmpty($origStorePw)

    try {
        if (-not $hadStorePw) {
            $creatingNew = -not (Test-Path -LiteralPath $resolvedKs -PathType Leaf)
            $promptMsg = if ($creatingNew) {
                '首次使用将自动生成上传密钥库，请设置密码（至少 6 位）'
            } else {
                "请输入签名密钥密码 ($resolvedAlias)"
            }
            $sec = Read-Host $promptMsg -AsSecureString
            $plain = ([Net.NetworkCredential]::new('', $sec)).Password
            $sec.Dispose()
            if ([string]::IsNullOrEmpty($plain)) {
                throw '密钥密码不能为空。'
            }
            if ($creatingNew) {
                if ($plain.Length -lt 6) {
                    throw '新密钥库密码长度至少需要 6 位。'
                }
                $sec2 = Read-Host '请再次输入密码确认' -AsSecureString
                $plain2 = ([Net.NetworkCredential]::new('', $sec2)).Password
                $sec2.Dispose()
                if ($plain -cne $plain2) {
                    $plain2 = $null
                    throw '两次输入的密码不一致。'
                }
                $plain2 = $null
            }
            [Environment]::SetEnvironmentVariable('UNITY_AAB_STORE_PASSWORD', $plain)
            $plain = $null
        }

        if (-not (Test-Path -LiteralPath $resolvedKs -PathType Leaf)) {
            Write-Host ''
            Write-Host "[密钥] 未找到密钥库，正在自动生成上传密钥库: $resolvedKs ..."
            $genRes = & (Join-Path $PSScriptRoot 'Sign-Aab.ps1') -GenerateKeystore -KeystorePath $resolvedKs -KeyAlias $resolvedAlias
            $expectedCert = [string]$genRes.CertificateSha256
        }

        $buildParams = @{
            ProjectPath  = $target.ProjectPath
            KeystorePath = $resolvedKs
            KeyAlias     = $resolvedAlias
        }
        if (-not [string]::IsNullOrWhiteSpace($target.ConfigPath) -and (
                [string]::IsNullOrWhiteSpace($cfgKs) -or [string]::Equals($resolvedKs, $cfgKs, [StringComparison]::OrdinalIgnoreCase)
            )) {
            $buildParams['ConfigPath'] = $target.ConfigPath
        }
        if (-not [string]::IsNullOrWhiteSpace($expectedCert)) {
            $buildParams['ExpectedCertificateSha256'] = $expectedCert
        }
        if ($QaSigning) { $buildParams['QaSigning'] = $true }
        if ($PrepareOnly) { $buildParams['PrepareOnly'] = $true }

        Write-Host ''
        Write-Host '[开始出包] 正在构建、签名并校验 AAB，请稍候...'
        $res = & (Join-Path $PSScriptRoot 'Build-Unity-Aab.ps1') @buildParams

        Write-Host ''
        Write-Host '================================================='
        Write-Host '  AAB 出包完成！'
        Write-Host ("  文件路径 : {0}" -f $res.AabPath)
        Write-Host ("  SHA-256  : {0}" -f $res.AabSha256)
        Write-Host '================================================='

        try {
            Start-Process explorer.exe -ArgumentList "/select,`"$($res.AabPath)`"" | Out-Null
        } catch {}

        Write-Host ''
        $setupAnswer = (Read-Host '是否顺便为该工程自动配置 GitHub Secrets 与本机 Runner？[y/N]').Trim().ToLowerInvariant()
        if ($setupAnswer -eq 'y' -or $setupAnswer -eq 'yes') {
            $setupParams = @{
                ProjectPath  = $target.ProjectPath
                KeystorePath = $resolvedKs
                KeyAlias     = $resolvedAlias
            }
            if (-not [string]::IsNullOrWhiteSpace($res.CertificateSha256)) {
                $setupParams['ExpectedCertificateSha256'] = $res.CertificateSha256
            } elseif (-not [string]::IsNullOrWhiteSpace($expectedCert)) {
                $setupParams['ExpectedCertificateSha256'] = $expectedCert
            }
            & (Join-Path $PSScriptRoot 'Setup-GitHub-Runner.ps1') @setupParams
        }
    } finally {
        if ($hadStorePw) {
            [Environment]::SetEnvironmentVariable('UNITY_AAB_STORE_PASSWORD', $origStorePw)
        } else {
            [Environment]::SetEnvironmentVariable('UNITY_AAB_STORE_PASSWORD', $null)
        }
    }
}

Invoke-OneClickLocalAabBuild
