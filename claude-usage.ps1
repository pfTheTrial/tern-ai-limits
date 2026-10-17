# Claude (Claude Code subscription) usage for the AI Limits plugin, printed as
# an `omp usage --json` document. The token is the one Claude Code keeps in
# ~/.claude/.credentials.json; it is read, never refreshed or written, and only
# goes to api.anthropic.com. When it has expired, Claude Code renews it the next
# time it runs.
$ErrorActionPreference = 'Stop'

function Out-Doc($reports, $disabled) {
	$doc = @{ reports = @($reports); disabledCredentials = @($disabled); generatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
	[Console]::Out.Write(($doc | ConvertTo-Json -Depth 10 -Compress))
}

function Out-Problem([string]$cause, $email) {
	Out-Doc @() @(@{ provider = 'anthropic'; email = $email; cause = $cause })
	exit 0
}

$dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$creds = Join-Path $dir '.credentials.json'
if (-not (Test-Path -LiteralPath $creds)) {
	Out-Doc @() @()
	exit 0
}
$oauth = (Get-Content -LiteralPath $creds -Raw | ConvertFrom-Json).claudeAiOauth
if (-not $oauth -or -not $oauth.accessToken) {
	Out-Doc @() @()
	exit 0
}

$email = $null
$accountId = $null
$profileFile = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path -LiteralPath $profileFile) {
	$acct = (Get-Content -LiteralPath $profileFile -Raw | ConvertFrom-Json).oauthAccount
	if ($acct) {
		$email = $acct.emailAddress
		$accountId = $acct.accountUuid
	}
}

$expired = 'login do Claude Code expirado: abra o claude para renovar'
if ($oauth.expiresAt -gt 0 -and [long]$oauth.expiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 60000) {
	Out-Problem $expired $email
}

try {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	$u = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 -UseBasicParsing `
		-Headers @{ Authorization = "Bearer $($oauth.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20'; Accept = 'application/json' }
} catch {
	$code = $null
	if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
	if ($code -eq 401 -or $code -eq 403) { Out-Problem $expired $email }
	Out-Problem "api.anthropic.com não respondeu ($code)" $email
}

function Ms([string]$iso) {
	if (-not $iso) { return $null }
	try { return ([DateTimeOffset]::Parse($iso)).ToUnixTimeMilliseconds() } catch { return $null }
}

# utilization is a percentage (0..100). Labels end in omp's window words, so
# the plugin groups them into families the way it does omp's reports.
$limits = @()
foreach ($w in @(
	@('five_hour', '5 Hour', 18000000),
	@('seven_day', 'Weekly', 604800000),
	@('seven_day_sonnet', 'Sonnet Weekly', 604800000),
	@('seven_day_opus', 'Opus Weekly', 604800000)
)) {
	$win = $u.($w[0])
	if ($null -eq $win -or $null -eq $win.utilization) { continue }
	$limits += @{
		label = $w[1]
		window = @{ id = $w[0]; durationMs = $w[2]; resetsAt = (Ms $win.resets_at) }
		amount = @{ usedFraction = [Math]::Max(0.0, [Math]::Min(1.0, [double]$win.utilization / 100)); unit = 'percent' }
	}
}
if ($limits.Count -eq 0) { Out-Problem 'o Claude não informou o uso' $email }

Out-Doc @(@{ provider = 'anthropic'; metadata = @{ email = $email; accountId = $accountId; planType = $oauth.subscriptionType }; limits = $limits }) @()
