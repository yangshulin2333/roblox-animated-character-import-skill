[CmdletBinding(DefaultParameterSetName = 'Single')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Single')]
    [string]$InputPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Single')]
    [string]$OutputPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Bundle')]
    [string]$BundleDir,

    [string]$ReportPath,

    [ValidateRange(256, 4096)]
    [int]$MaxDimension = 4096,

    [string]$PythonPath,

    [string]$BlenderPath,

    [switch]$ReplaceOutput,

    [switch]$NoToolInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-PythonCommand {
    param([string]$Executable, [string[]]$PrefixArguments, [string]$ExtraPythonPath)
    $previousPythonPath = $env:PYTHONPATH
    try {
        if ($ExtraPythonPath) {
            $env:PYTHONPATH = if ($previousPythonPath) { "$ExtraPythonPath;$previousPythonPath" } else { $ExtraPythonPath }
        }
        & $Executable @PrefixArguments -c "import sys; print(sys.executable)" *> $null
        return $LASTEXITCODE -eq 0
    } finally {
        $env:PYTHONPATH = $previousPythonPath
    }
}

function Test-Pillow {
    param([string]$Executable, [string[]]$PrefixArguments, [string]$ExtraPythonPath)
    $previousPythonPath = $env:PYTHONPATH
    try {
        if ($ExtraPythonPath) {
            $env:PYTHONPATH = if ($previousPythonPath) { "$ExtraPythonPath;$previousPythonPath" } else { $ExtraPythonPath }
        }
        & $Executable @PrefixArguments -c "from PIL import Image; print(Image.__version__)" *> $null
        return $LASTEXITCODE -eq 0
    } finally {
        $env:PYTHONPATH = $previousPythonPath
    }
}

function Add-PythonCandidate {
    param($List, [string]$Executable, [string[]]$PrefixArguments = @())
    if (-not $Executable) { return }
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return }
    $key = $Executable.ToLowerInvariant() + '|' + ($PrefixArguments -join ' ')
    if (@($List | Where-Object { $_.key -eq $key }).Count -eq 0) {
        $List.Add([pscustomobject]@{ key = $key; executable = $Executable; prefix = @($PrefixArguments) })
    }
}

$candidates = [Collections.Generic.List[object]]::new()
if ($PythonPath) {
    Add-PythonCandidate -List $candidates -Executable ([IO.Path]::GetFullPath($PythonPath))
}
$py = Get-Command py -ErrorAction SilentlyContinue
if ($py) { Add-PythonCandidate -List $candidates -Executable $py.Source -PrefixArguments @('-3') }
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) { Add-PythonCandidate -List $candidates -Executable $python.Source }

if ($BlenderPath -and (Test-Path -LiteralPath $BlenderPath -PathType Leaf)) {
    $blenderRoot = Split-Path -Parent ([IO.Path]::GetFullPath($BlenderPath))
    $bundled = Get-ChildItem -LiteralPath $blenderRoot -Filter python.exe -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '[\\/]python[\\/]bin[\\/]python\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($bundled) { Add-PythonCandidate -List $candidates -Executable $bundled.FullName }
}

$candidate = $null
foreach ($item in $candidates) {
    if (Test-PythonCommand -Executable $item.executable -PrefixArguments $item.prefix -ExtraPythonPath '') {
        $candidate = $item
        if (Test-Pillow -Executable $item.executable -PrefixArguments $item.prefix -ExtraPythonPath '') { break }
    }
}
if (-not $candidate) {
    throw 'TEXTURE_TOOL_REQUIRED: 找不到可运行的 Python 3。请安装 Python，或把 BlenderPath 传给脚本。'
}

$toolModules = Join-Path $env:LOCALAPPDATA 'CodexTools\roblox-animated-character-import\python-packages'
$extraPythonPath = ''
if (-not (Test-Pillow -Executable $candidate.executable -PrefixArguments $candidate.prefix -ExtraPythonPath '')) {
    if (Test-Pillow -Executable $candidate.executable -PrefixArguments $candidate.prefix -ExtraPythonPath $toolModules) {
        $extraPythonPath = $toolModules
    } else {
        if ($NoToolInstall) {
            throw 'TEXTURE_TOOL_REQUIRED: 当前 Python 缺少 Pillow，且已禁用自动安装。'
        }
        New-Item -ItemType Directory -Force -Path $toolModules | Out-Null
        & $candidate.executable @($candidate.prefix) -m pip install `
            --disable-pip-version-check --no-warn-script-location --only-binary=:all: `
            --target $toolModules 'Pillow==12.2.0'
        if ($LASTEXITCODE -ne 0) {
            throw 'TEXTURE_TOOL_REQUIRED: Pillow 自动安装失败。请检查网络后重试。'
        }
        if (-not (Test-Pillow -Executable $candidate.executable -PrefixArguments $candidate.prefix -ExtraPythonPath $toolModules)) {
            throw 'TEXTURE_TOOL_REQUIRED: Pillow 已下载但无法加载。'
        }
        $extraPythonPath = $toolModules
    }
}

$normalizer = Join-Path $PSScriptRoot 'normalize_roblox_textures.py'
$arguments = @($normalizer, '--max-dimension', [string]$MaxDimension)
if ($PSCmdlet.ParameterSetName -eq 'Bundle') {
    if (-not (Test-Path -LiteralPath $BundleDir -PathType Container)) { throw "找不到交付包：$BundleDir" }
    $arguments += @('--bundle', (Resolve-Path -LiteralPath $BundleDir).Path)
} else {
    if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) { throw "找不到贴图：$InputPath" }
    $arguments += @('--input', (Resolve-Path -LiteralPath $InputPath).Path, '--output', [IO.Path]::GetFullPath($OutputPath))
    if ($ReplaceOutput) { $arguments += '--replace-output' }
}
if ($ReportPath) { $arguments += @('--report', [IO.Path]::GetFullPath($ReportPath)) }

$previousPythonPath = $env:PYTHONPATH
try {
    if ($extraPythonPath) {
        $env:PYTHONPATH = if ($previousPythonPath) { "$extraPythonPath;$previousPythonPath" } else { $extraPythonPath }
    }
    & $candidate.executable @($candidate.prefix) @arguments
    if ($LASTEXITCODE -ne 0) { throw "贴图标准化失败，退出码：$LASTEXITCODE" }
} finally {
    $env:PYTHONPATH = $previousPythonPath
}
