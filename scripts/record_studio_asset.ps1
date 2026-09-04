[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RegistryPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('image', 'mesh', 'animation')]
    [string]$Kind,

    [string]$File,

    [string]$Sha256,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+$')]
    [string]$AssetId,

    [Parameter(Mandatory = $true)]
    [string]$CreatorId,

    [Parameter(Mandatory = $true)]
    [string]$UniverseId,

    [string]$PlaceId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('UPLOADED', 'STUDIO_VISIBLE', 'RUNTIME_FETCH_PASS', 'PERMISSION_BLOCKED', 'MODERATION_PENDING')]
    [string]$VerificationStatus
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Sha256) {
    if (-not $File -or -not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw '必须提供现有文件 -File，或直接提供 64 位 -Sha256。'
    }
    $Sha256 = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
}
$Sha256 = $Sha256.ToLowerInvariant()
if ($Sha256 -notmatch '^[0-9a-f]{64}$') { throw "无效 SHA-256：$Sha256" }

$resolvedRegistry = [System.IO.Path]::GetFullPath($RegistryPath)
$entries = New-Object System.Collections.Generic.List[object]
if (Test-Path -LiteralPath $resolvedRegistry -PathType Leaf) {
    $existing = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedRegistry | ConvertFrom-Json
    foreach ($entry in @($existing.entries)) { $entries.Add($entry) }
}

$sameKey = @($entries | Where-Object {
    [string]$_.kind -eq $Kind -and
    [string]$_.sha256 -eq $Sha256 -and
    [string]$_.asset_id -eq $AssetId -and
    [string]$_.creator_id -eq $CreatorId -and
    [string]$_.universe_id -eq $UniverseId
})
if ($sameKey.Count -gt 0) {
    $entry = $sameKey[0]
    $entry.verification_status = $VerificationStatus
    $entry.place_id = $PlaceId
    $entry.verified_at = [DateTimeOffset]::Now.ToString('o')
    if ($File) { $entry.file = [System.IO.Path]::GetFullPath($File) }
} else {
    $entries.Add([pscustomobject][ordered]@{
        kind = $Kind
        sha256 = $Sha256
        asset_id = $AssetId
        creator_id = $CreatorId
        universe_id = $UniverseId
        place_id = $PlaceId
        verification_status = $VerificationStatus
        file = if ($File) { [System.IO.Path]::GetFullPath($File) } else { $null }
        verified_at = [DateTimeOffset]::Now.ToString('o')
    })
}

$result = [ordered]@{
    schema_version = '1.0'
    entries = $entries.ToArray()
    note_zh = 'RUNTIME_FETCH_PASS 只对相同内容哈希、Creator 和 Universe 的组合提供复用证据。'
}
$parent = Split-Path -Parent $resolvedRegistry
if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$temporary = $resolvedRegistry + '.tmp'
$json = $result | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporary -Destination $resolvedRegistry -Force
$json
