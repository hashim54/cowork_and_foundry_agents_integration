#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot 'env\.env.dev'),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $EnvironmentFile -PathType Leaf)) {
    throw 'Environment file missing. Copy env\.env.example to env\.env.dev and fill in your values.'
}
$settings = @{}
foreach ($line in Get-Content -LiteralPath $EnvironmentFile) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
    if ($line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') {
        throw 'Invalid environment entry. Use unquoted KEY=value lines.'
    }
    $key = $Matches[1]
    $value = $Matches[2].Trim()
    if ($settings.ContainsKey($key)) { throw "Duplicate environment key: $key" }
    $settings[$key] = $value
}
$required = @(
    'TEAMS_APP_TENANT_ID', 'FOUNDRY_OAUTH_CLIENT_ID', 'TEAMS_APP_ID',
    'FOUNDRY_OAUTH_REFERENCE_ID', 'FOUNDRY_PROJECT_ENDPOINT', 'APP_DISPLAY_NAME',
    'DEVELOPER_NAME', 'DEVELOPER_WEBSITE_URL', 'DEVELOPER_PRIVACY_URL', 'DEVELOPER_TERMS_URL'
)
foreach ($key in $required) {
    if ([string]::IsNullOrWhiteSpace($settings[$key])) { throw "Missing required setting: $key" }
    if ($settings[$key].Contains('{{') -or $settings[$key] -match '[\x00-\x1f]') {
        throw "Unresolved template or control character in setting: $key"
    }
}
foreach ($key in @('TEAMS_APP_TENANT_ID', 'FOUNDRY_OAUTH_CLIENT_ID', 'TEAMS_APP_ID')) {
    $id = [guid]::Empty
    if (-not [guid]::TryParse($settings[$key], [ref]$id) -or $id -eq [guid]::Empty) {
        throw "Setting must be a nonempty GUID: $key"
    }
}
foreach ($key in @('DEVELOPER_WEBSITE_URL', 'DEVELOPER_PRIVACY_URL', 'DEVELOPER_TERMS_URL')) {
    $uri = $null
    if (-not [uri]::TryCreate($settings[$key], [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo) {
        throw "Setting must be an absolute HTTPS URL without credentials: $key"
    }
}
$endpoint = $settings.FOUNDRY_PROJECT_ENDPOINT
if ($endpoint -cnotmatch '^https://[a-z0-9-]+\.services\.ai\.azure\.com/api/projects/[A-Za-z0-9._-]+$') {
    throw 'FOUNDRY_PROJECT_ENDPOINT must be an Azure public-cloud project URL without query, fragment, or trailing slash.'
}
if ($settings.APP_DISPLAY_NAME.Length -gt 30) {
    throw 'APP_DISPLAY_NAME must be at most 30 characters.'
}
if ($settings.DEVELOPER_NAME.Length -gt 32) {
    throw 'DEVELOPER_NAME must be at most 32 characters.'
}
if ($settings.FOUNDRY_OAUTH_REFERENCE_ID -match '\s') {
    throw 'FOUNDRY_OAUTH_REFERENCE_ID must be the full registration ID without whitespace.'
}

$source = Join-Path $PSScriptRoot 'coworkPlugin'
$manifest = Get-Content (Join-Path $source 'manifest.json') -Raw | ConvertFrom-Json
$tools = Get-Content (Join-Path $source 'foundry-agent-tools.json') -Raw | ConvertFrom-Json
$skill = Get-Content (Join-Path $source 'skills\foundry-agent-router\SKILL.md') -Raw
if ($manifest.version -notmatch '^[1-9][0-9]*\.[0-9]+\.[0-9]+$') {
    throw 'Manifest version must use a nonzero major version and numeric major.minor.patch.'
}
if (@($manifest.agentConnectors).Count -ne 1 -or
    $manifest.agentConnectors[0].toolSource.remoteMcpServer.mcpServerUrl -ne 'https://mcp.ai.azure.com') {
    throw 'Expected exactly one connector targeting the Foundry MCP server.'
}
if (@($tools.tools).Count -ne 2 -or
    (@($tools.tools.name | Sort-Object) -join ',') -ne 'agent_get,agent_invoke') {
    throw 'The static description must contain only agent_get and agent_invoke.'
}
if (-not $skill.Contains('{{FOUNDRY_PROJECT_ENDPOINT}}')) {
    throw 'Routing skill is missing its project-endpoint template marker.'
}

$manifest.id = $settings.TEAMS_APP_ID
$manifest.name.short = $settings.APP_DISPLAY_NAME
$manifest.name.full = $settings.APP_DISPLAY_NAME
$manifest.developer.name = $settings.DEVELOPER_NAME
$manifest.developer.websiteUrl = $settings.DEVELOPER_WEBSITE_URL
$manifest.developer.privacyUrl = $settings.DEVELOPER_PRIVACY_URL
$manifest.developer.termsOfUseUrl = $settings.DEVELOPER_TERMS_URL
$manifest.agentConnectors[0].displayName = $settings.APP_DISPLAY_NAME
$manifest.agentConnectors[0].toolSource.remoteMcpServer.authorization.referenceId = $settings.FOUNDRY_OAUTH_REFERENCE_ID
foreach ($tool in $tools.tools) {
    $tool.inputSchema.properties.projectEndpoint.enum = @($endpoint)
}
$skill = $skill.Replace('{{FOUNDRY_PROJECT_ENDPOINT}}', $endpoint)

# A unique staging directory prevents unrelated local files from entering the ZIP.
$stage = Join-Path ([IO.Path]::GetTempPath()) ("foundry-cowork-build-" + [guid]::NewGuid())
try {
    $skillDirectory = Join-Path $stage 'skills\foundry-agent-router'
    New-Item -ItemType Directory -Path $skillDirectory -Force | Out-Null
    $manifest | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $stage 'manifest.json') -Encoding utf8
    $tools | ConvertTo-Json -Depth 40 | Set-Content (Join-Path $stage 'foundry-agent-tools.json') -Encoding utf8
    Set-Content (Join-Path $skillDirectory 'SKILL.md') -Value $skill -Encoding utf8
    Copy-Item -LiteralPath (Join-Path $source 'color.png'), (Join-Path $source 'outline.png') -Destination $stage
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $target = Join-Path $OutputDirectory "Foundry-Agents-Cowork-v$($manifest.version).zip"
    $files = @('manifest.json', 'foundry-agent-tools.json', 'color.png', 'outline.png', 'skills')
    Compress-Archive -LiteralPath @($files | ForEach-Object { Join-Path $stage $_ }) `
        -DestinationPath $target -CompressionLevel Optimal -Force
    $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($target))
    try {
        $expected = @('manifest.json', 'foundry-agent-tools.json', 'color.png', 'outline.png',
            'skills/foundry-agent-router/SKILL.md')
        $actual = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        if (Compare-Object $expected $actual) { throw 'Unexpected ZIP entries.' }
    } finally {
        $zip.Dispose()
    }
    Get-Item -LiteralPath $target | Select-Object FullName, Length
    Get-FileHash -LiteralPath $target -Algorithm SHA256
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
