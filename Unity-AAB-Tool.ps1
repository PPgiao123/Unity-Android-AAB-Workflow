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

function Get-PresetConfigs {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($dirName in @('local-config', 'config')) {
        $dir = Join-Path $PSScriptRoot $dirName
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'project.example.json' } |
            Sort-Object Name)
        foreach ($f in $files) {
            try {
                $obj = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $items.Add([PSCustomObject]@{
                    Path        = $f.FullName
                    ProjectName = [string](Get-ConfigProperty -Object $obj -Name 'projectName' -Default $f.BaseName)
                    ProjectPath = [string](Get-ConfigProperty -Object $obj -Name 'projectPath' -Default '')
                    Repo        = [string](Get-ConfigProperty -Object (Get-ConfigProperty -Object $obj -Name 'release') -Name 'githubRepo' -Default '')
                })
            } catch {}
        }
    }
    return $items.ToArray()
}

function Select-ProjectOrConfig([string]$PromptTitle) {
    $presets = @(Get-PresetConfigs)
    if ($presets.Count -gt 0) {
        Write-Host ''
        Write-Host "=== $PromptTitle ==="
        for ($i = 0; $i -lt $presets.Count; $i++) {
            Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $presets[$i].ProjectName, $presets[$i].ProjectPath)
        }
        Write-Host '  [0] 选择其他 Unity 工程文件夹 (Browse Folder)'
        $sel = (Read-Host '请输入编号').Trim()
        if ($sel -match '^\d+$') {
            $idx = [int]$sel
            if ($idx -ge 1 -and $idx -le $presets.Count) {
                return [PSCustomObject]@{ ConfigPath = $presets[$idx - 1].Path; ProjectPath = '' }
            }
        }
    }
    Add-Type -AssemblyName System.Windows.Forms
    $picker = New-Object System.Windows.Forms.FolderBrowserDialog
    $picker.Description = '选择 Unity 工程根目录（包含 Assets 和 ProjectSettings）'
    try {
        if ($picker.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $null }
        return [PSCustomObject]@{ ConfigPath = ''; ProjectPath = $picker.SelectedPath }
    } finally {
        $picker.Dispose()
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
                $target = Select-ProjectOrConfig '选择要出包的 Unity 工程'
                if ($null -eq $target) { return }
                if ($target.ConfigPath) { $params['ConfigPath'] = $target.ConfigPath }
                if ($target.ProjectPath) { $params['ProjectPath'] = $target.ProjectPath }

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
                $target = Select-ProjectOrConfig '选择要自检的 Unity 工程'
                if ($null -eq $target) { return }
                if ($target.ConfigPath) { $params['ConfigPath'] = $target.ConfigPath }
                if ($target.ProjectPath) { $params['ProjectPath'] = $target.ProjectPath }
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

while ($true) {
    Write-Host ''
    Write-Host '================================================='
    Write-Host '         Unity Android AAB 一键工具箱'
    Write-Host '================================================='
    Write-Host '  [1] 本地一键出包并验包 (Build + Sign + Verify)'
    Write-Host '  [2] 一键配置 GitHub Secrets 与本机 Runner (自动装 gh)'
    Write-Host '  [3] 生成新上传密钥库 (.p12) 或查看证书指纹'
    Write-Host '  [4] 单独验包现有 .aab (bundletool / 16KB ELF / 验签)'
    Write-Host '  [5] 检测本机 Unity / Android / bundletool 环境'
    Write-Host '  [0] 退出'
    Write-Host '================================================='
    $choice = (Read-Host '请选择操作 [0-5]').Trim()
    switch ($choice) {
        '1' { Invoke-Action 'build' }
        '2' { Invoke-Action 'setup' }
        '3' {
            Write-Host '  [a] 生成新上传密钥库 (.p12)'
            Write-Host '  [b] 查看现有密钥库公钥 SHA-256'
            $sub = (Read-Host '请选择 [a/b]').Trim().ToLowerInvariant()
            if ($sub -eq 'b') { Invoke-Action 'certinfo' } else { Invoke-Action 'keygen' }
        }
        '4' { Invoke-Action 'verify' }
        '5' { Invoke-Action 'checkenv' }
        '0' { return }
        default { Write-Host "无效选项: $choice" }
    }
}
