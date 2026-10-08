#Requires -Version 7.2
[CmdletBinding()]
param([string]$KeepPackageDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ("foundry-cowork-test-" + [guid]::NewGuid())
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Output "PASS: $Message"
}

function Write-Fixture([System.Collections.IDictionary]$Values, [string]$Path) {
    @($Values.Keys | ForEach-Object { "$_=$($Values[$_])" }) |
        Set-Content -LiteralPath $Path -Encoding utf8
}

function Assert-Rejected([string]$Path, [string]$ExpectedMessage) {
    $message = $null
    try {
        & (Join-Path $root 'build.ps1') -EnvironmentFile $Path -OutputDirectory (Join-Path $temp 'rejected') | Out-Null
    } catch {
        $message = $_.Exception.Message
    }
    Assert-True ($null -ne $message -and $message.Contains($ExpectedMessage)) "Rejects $ExpectedMessage"
    Assert-True (-not (Test-Path (Join-Path $temp 'rejected'))) 'Invalid configuration produces no package'
}

try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    # Synthetic, nonfunctional registrations; never use this package to connect.
    $tenant = [guid]::NewGuid().ToString()
    $values = [ordered]@{
        TEAMS_APP_TENANT_ID = $tenant
        FOUNDRY_OAUTH_CLIENT_ID = [guid]::NewGuid().ToString()
        TEAMS_APP_ID = [guid]::NewGuid().ToString()
        FOUNDRY_OAUTH_REFERENCE_ID = [Convert]::ToBase64String(
            [Text.Encoding]::UTF8.GetBytes("$tenant##$([guid]::NewGuid())"))
        FOUNDRY_PROJECT_ENDPOINT = 'https://test-fixture.services.ai.azure.com/api/projects/test-fixture'
        APP_DISPLAY_NAME = 'Foundry "Test" Agents'
        DEVELOPER_NAME = 'Test \ Fixture'
        DEVELOPER_WEBSITE_URL = 'https://example.com'
        DEVELOPER_PRIVACY_URL = 'https://example.com/privacy'
        DEVELOPER_TERMS_URL = 'https://example.com/terms'
        SECRET_FOUNDRY_OAUTH_CLIENT_SECRET = 'TEST-ONLY-MUST-NOT-ENTER-ZIP'
    }
    $config = Join-Path $temp '.env.test'
    Write-Fixture $values $config

    # Build an isolated copy from an unrelated working directory: no parent dependencies.
    $isolated = Join-Path $temp 'isolated'
    New-Item -ItemType Directory -Path $isolated | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'build.ps1'), (Join-Path $root 'coworkPlugin') `
        -Destination $isolated -Recurse
    Push-Location ([IO.Path]::GetTempPath())
    try {
        & (Join-Path $isolated 'build.ps1') -EnvironmentFile $config | Out-Null
    } finally { Pop-Location }
    $packages = @(Get-ChildItem -LiteralPath (Join-Path $isolated 'dist') -Filter '*.zip')
    Assert-True ($packages.Count -eq 1) 'Standalone build writes exactly one ZIP under its own dist'
    $package = $packages[0].FullName
    $expanded = Join-Path $temp 'expanded'
    Expand-Archive -LiteralPath $package -DestinationPath $expanded
    $entries = @(Get-ChildItem -LiteralPath $expanded -File -Recurse |
        ForEach-Object { [IO.Path]::GetRelativePath($expanded, $_.FullName).Replace('\', '/') })
    $expected = @('manifest.json', 'foundry-agent-tools.json', 'color.png', 'outline.png',
        'skills/foundry-agent-router/SKILL.md')
    Assert-True (-not (Compare-Object $expected $entries)) 'ZIP contains exactly the five required files, no wrapper folder'
    $manifest = Get-Content (Join-Path $expanded 'manifest.json') -Raw | ConvertFrom-Json
    $tools = Get-Content (Join-Path $expanded 'foundry-agent-tools.json') -Raw | ConvertFrom-Json
    $skill = Get-Content (Join-Path $expanded 'skills\foundry-agent-router\SKILL.md') -Raw
    Assert-True ($manifest.id -eq $values.TEAMS_APP_ID) 'App ID is rendered from configuration'
    Assert-True ($manifest.name.short -eq $values.APP_DISPLAY_NAME -and
        $manifest.agentConnectors[0].displayName -eq $values.APP_DISPLAY_NAME) 'Display names survive JSON escaping'
    Assert-True ($manifest.developer.name -eq $values.DEVELOPER_NAME -and
        $manifest.developer.privacyUrl -eq $values.DEVELOPER_PRIVACY_URL) 'Publisher metadata is rendered safely'
    $remote = $manifest.agentConnectors[0].toolSource.remoteMcpServer
    Assert-True ($remote.authorization.referenceId -eq $values.FOUNDRY_OAUTH_REFERENCE_ID -and
        $remote.authorization.type -eq 'OAuthPluginVault') 'Full opaque OAuth reference is preserved'
    Assert-True ($remote.mcpServerUrl -eq 'https://mcp.ai.azure.com') 'Hosted MCP endpoint is unchanged'
    Assert-True (($tools.tools.name -join ',') -eq 'agent_get,agent_invoke') 'Only intended tool descriptions are packaged'
    foreach ($tool in $tools.tools) {
        $enum = @($tool.inputSchema.properties.projectEndpoint.enum)
        Assert-True ($enum.Count -eq 1 -and $enum[0] -eq $values.FOUNDRY_PROJECT_ENDPOINT) "$($tool.name) uses the configured project"
    }
    $invoke = $tools.tools[1].inputSchema
    Assert-True (($invoke.required -join ',') -eq 'projectEndpoint,agentName,inputText') 'Invocation required inputs are preserved'
    Assert-True (($invoke.properties.protocol.enum -join ',') -eq 'responses,invocations' -and
        $invoke.properties.conversationId.type -eq 'string' -and
        $invoke.properties.sessionId.type -eq 'string' -and
        $invoke.properties.stream.default -eq $false -and
        $invoke.properties.useEndpoint.default -eq $true) 'Protocol, state, and endpoint defaults are preserved'
    Assert-True ($skill.Contains($values.FOUNDRY_PROJECT_ENDPOINT)) 'Routing skill uses the same project'
    $text = @($manifest | ConvertTo-Json -Depth 40; $tools | ConvertTo-Json -Depth 40; $skill) -join "`n"
    Assert-True (-not $text.Contains('{{')) 'No unresolved template markers'
    Assert-True (-not $text.Contains($values.SECRET_FOUNDRY_OAUTH_CLIENT_SECRET) -and
        -not $text.Contains($values.FOUNDRY_OAUTH_CLIENT_ID)) 'No secret or client credential configuration packaged'
    foreach ($icon in @('color.png', 'outline.png')) {
        Assert-True ((Get-FileHash (Join-Path $expanded $icon)).Hash -eq
            (Get-FileHash (Join-Path $root "coworkPlugin\$icon")).Hash) "$icon is unchanged"
    }
    $sourceManifest = Get-Content (Join-Path $isolated 'coworkPlugin\manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($sourceManifest.id -eq '') 'Build leaves source template unconfigured'

    Assert-Rejected (Join-Path $temp 'missing.env') 'Environment file missing'
    Assert-Rejected (Join-Path $root 'env\.env.example') 'Missing required setting'
    $invalidCases = @(
        @{ Key = 'TEAMS_APP_ID'; Value = 'not-a-guid'; Message = 'Setting must be a nonempty GUID' },
        @{ Key = 'TEAMS_APP_TENANT_ID'; Value = [guid]::Empty.ToString(); Message = 'Setting must be a nonempty GUID' },
        @{ Key = 'FOUNDRY_PROJECT_ENDPOINT'; Value = 'https://example.com'; Message = 'FOUNDRY_PROJECT_ENDPOINT must' },
        @{ Key = 'FOUNDRY_PROJECT_ENDPOINT'; Value = "$($values.FOUNDRY_PROJECT_ENDPOINT)?x=1"; Message = 'FOUNDRY_PROJECT_ENDPOINT must' },
        @{ Key = 'DEVELOPER_WEBSITE_URL'; Value = 'http://example.com'; Message = 'Setting must be an absolute HTTPS URL' },
        @{ Key = 'DEVELOPER_WEBSITE_URL'; Value = 'https://user:pass@example.com'; Message = 'Setting must be an absolute HTTPS URL' },
        @{ Key = 'APP_DISPLAY_NAME'; Value = ('a' * 31); Message = 'APP_DISPLAY_NAME must be at most 30' },
        @{ Key = 'DEVELOPER_NAME'; Value = ('a' * 33); Message = 'DEVELOPER_NAME must be at most 32' },
        @{ Key = 'FOUNDRY_OAUTH_REFERENCE_ID'; Value = 'two words'; Message = 'FOUNDRY_OAUTH_REFERENCE_ID must' },
        @{ Key = 'FOUNDRY_OAUTH_REFERENCE_ID'; Value = '${{UNRESOLVED}}'; Message = 'Unresolved template' }
    )
    foreach ($case in $invalidCases) {
        $original = $values[$case.Key]
        $values[$case.Key] = $case.Value
        Write-Fixture $values $config
        Assert-Rejected $config $case.Message
        $values[$case.Key] = $original
    }
    Write-Fixture $values $config
    Add-Content -LiteralPath $config -Value "TEAMS_APP_ID=$($values.TEAMS_APP_ID)"
    Assert-Rejected $config 'Duplicate environment key'
    Set-Content -LiteralPath $config -Value 'malformed input'
    Assert-Rejected $config 'Invalid environment entry'
    if ($KeepPackageDirectory) {
        New-Item -ItemType Directory -Path $KeepPackageDirectory -Force | Out-Null
        Copy-Item -LiteralPath $package -Destination (Join-Path $KeepPackageDirectory 'test-fixture.zip') -Force
    }
    Write-Output "$passed checks passed. Test registrations are synthetic; no cloud changes or agent invocations."
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
