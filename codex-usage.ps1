# Codex (ChatGPT plan) usage for the AI Limits plugin, printed as an
# `omp usage --json` document. The token is the one the Codex CLI keeps in
# ~/.codex/auth.json (or $CODEX_HOME); it is read, never refreshed or written,
# and only goes to chatgpt.com. When it has expired, Codex renews it the next
# time it runs.
$ErrorActionPreference = 'Stop'

function Out-Doc($reports, $disabled) {
	$doc = @{ reports = @($reports); disabledCredentials = @($disabled); generatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
	[Console]::Out.Write(($doc | ConvertTo-Json -Depth 10 -Compress))
}

function Out-Problem([string]$cause, $email) {
	Out-Doc @() @(@{ provider = 'openai-codex'; email = $email; cause = $cause })
	exit 0
}

function Claims([string]$jwt) {
	$parts = $jwt.Split('.')
	if ($parts.Count -lt 2) { return $null }
	$p = $parts[1].Replace('-', '+').Replace('_', '/')
	switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
	return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
}

$home_dir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$auth = Join-Path $home_dir 'auth.json'
if (-not (Test-Path -LiteralPath $auth)) {
	Out-Doc @() @()
	exit 0
}
$t = (Get-Content -LiteralPath $auth -Raw | ConvertFrom-Json).tokens
if (-not $t -or -not $t.access_token) {
	Out-Doc @() @()
	exit 0
}

$email = $null
$plan = $null
if ($t.id_token) {
	$id = Claims $t.id_token
	$email = $id.email
	$plan = $id.'https://api.openai.com/auth'.chatgpt_plan_type
}
$access = Claims $t.access_token
$expired = 'login do Codex expirado: abra o codex para renovar'
if ($access -and $access.exp -and [long]$access.exp -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60) {
	Out-Problem $expired $email
}

try {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	$headers = @{ Authorization = "Bearer $($t.access_token)"; Accept = 'application/json'; 'User-Agent' = 'codex-cli' }
	if ($t.account_id) { $headers['ChatGPT-Account-Id'] = $t.account_id }
	$u = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' -TimeoutSec 15 -UseBasicParsing -Headers $headers
} catch {
	$code = $null
	if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
	if ($code -eq 401 -or $code -eq 403) { Out-Problem $expired $email }
	Out-Problem "chatgpt.com não respondeu ($code)" $email
}

# Window words the plugin knows, so the label alone names no family.
function Label([long]$seconds, [string]$prefix) {
	$word = switch ($seconds) { 18000 { '5 Hour' } 86400 { 'Daily' } 604800 { 'Weekly' } default { 'Plan Period' } }
	if ($prefix) { return "$prefix $word" }
	return $word
}

# A List, not an array: PowerShell unrolls arrays a function returns.
$limits = New-Object System.Collections.Generic.List[object]

function Add-Window($w, [string]$prefix, [string]$id) {
	if ($null -eq $w -or $null -eq $w.used_percent) { return }
	$window = @{ id = $id }
	if ($w.limit_window_seconds) { $window.durationMs = [long]$w.limit_window_seconds * 1000 }
	if ($w.reset_at) { $window.resetsAt = [long]$w.reset_at * 1000 }
	$limits.Add(@{
		label = (Label ([long]$w.limit_window_seconds) $prefix)
		window = $window
		amount = @{ usedFraction = [Math]::Max(0.0, [Math]::Min(1.0, [double]$w.used_percent / 100)); unit = 'percent' }
	})
}

Add-Window $u.rate_limit.primary_window '' 'primary'
Add-Window $u.rate_limit.secondary_window '' 'secondary'
foreach ($extra in @($u.additional_rate_limits)) {
	if (-not $extra) { continue }
	$name = if ($extra.limit_name) { $extra.limit_name } else { $extra.metered_feature }
	Add-Window $extra.rate_limit.primary_window $name "$name-primary"
	Add-Window $extra.rate_limit.secondary_window $name "$name-secondary"
}
if ($limits.Count -eq 0) { Out-Problem 'o Codex não informou o uso' $email }
if ($u.plan_type) { $plan = $u.plan_type }

Out-Doc @(@{ provider = 'openai-codex'; metadata = @{ email = $email; accountId = $t.account_id; planType = $plan }; limits = $limits.ToArray() }) @()
