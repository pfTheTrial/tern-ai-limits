# Grok usage for the AI Limits plugin, printed as an `omp usage --json`
# document. The token is the one `grok login` keeps in ~/.grok/auth.json; it
# only goes to xAI's Grok CLI billing endpoint.
$ErrorActionPreference = 'Stop'

function Out-Doc($reports, $disabled) {
	$doc = @{ reports = @($reports); disabledCredentials = @($disabled); generatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
	[Console]::Out.Write(($doc | ConvertTo-Json -Depth 10 -Compress))
}

function Out-Problem([string]$cause, $email) {
	Out-Doc @() @(@{ provider = 'grok'; email = $email; cause = $cause })
	exit 0
}

$home_dir = if ($env:GROK_HOME) { $env:GROK_HOME } else { Join-Path $env:USERPROFILE '.grok' }
$auth = Join-Path $home_dir 'auth.json'
if (-not (Test-Path -LiteralPath $auth)) {
	Out-Doc @() @()
	exit 0
}

# auth.json maps scope URLs to entries; prefer the OIDC (SuperGrok) scope.
$root = Get-Content -LiteralPath $auth -Raw | ConvertFrom-Json
$entry = $null
foreach ($prop in $root.PSObject.Properties) {
	$e = $prop.Value
	if (-not $e -or -not $e.key) { continue }
	if ($prop.Name.StartsWith('https://auth.x.ai::')) { $entry = $e; break }
	if (-not $entry -and $prop.Name -like '*/sign-in*') { $entry = $e }
}
if (-not $entry) { Out-Problem 'Grok sem login: rode grok login' $null }
$email = $entry.email
if ($entry.expires_at) {
	try {
		if ([DateTimeOffset]::Parse($entry.expires_at) -le [DateTimeOffset]::UtcNow) {
			Out-Problem 'login do Grok expirado: rode grok login' $email
		}
	} catch {}
}

try {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	$r = Invoke-RestMethod -Uri 'https://cli-chat-proxy.grok.com/v1/billing?format=credits' -TimeoutSec 15 -UseBasicParsing `
		-Headers @{ Authorization = "Bearer $($entry.key)"; 'x-xai-token-auth' = 'xai-grok-cli'; Accept = 'application/json' }
} catch {
	$code = $null
	if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
	if ($code -eq 401 -or $code -eq 403) { Out-Problem 'xAI recusou o login: rode grok login' $email }
	Out-Problem "xAI não respondeu ($code)" $email
}

$c = $r.config
if (-not $c) { Out-Problem 'resposta de billing do Grok sem dados' $email }

function Ms([string]$iso) {
	if (-not $iso) { return $null }
	try { return ([DateTimeOffset]::Parse($iso)).ToUnixTimeMilliseconds() } catch { return $null }
}

$end = Ms $c.currentPeriod.end
$start = Ms $c.currentPeriod.start
if (-not $end) {
	$end = Ms $c.billingPeriodEnd
	$start = Ms $c.billingPeriodStart
}
$pct = $c.creditUsagePercent
if ($null -eq $pct -and $c.onDemandCap.val -gt 0) { $pct = [double]$c.onDemandUsed.val / $c.onDemandCap.val * 100 }
# The endpoint speaks proto3 JSON, which leaves zero values out: a current
# period without a percentage is a period with nothing used yet.
if ($null -eq $pct -and $c.currentPeriod.end) { $pct = 0 }

$limits = @()
if ($null -ne $pct) {
	$window = @{ id = 'period'; label = 'Plan Period'; resetsAt = $end }
	# A weekly period reads as "7d"; any other length is the plan period.
	if ($start -and $end -and ($end - $start) -eq 604800000) { $window.durationMs = 604800000 }
	$limits += @{ label = 'Credits'; window = $window; amount = @{ usedFraction = [Math]::Max(0.0, [Math]::Min(1.0, [double]$pct / 100)); unit = 'percent' } }
}
$tier = $c.subscriptionTier
if (-not $tier) { $tier = $r.subscriptionTier }
$report = @{ provider = 'grok'; metadata = @{ email = $email; accountId = $entry.user_id; planType = $tier }; limits = $limits }
if ($limits.Count -eq 0) {
	Out-Doc @() @(@{ provider = 'grok'; email = $email; cause = 'o Grok não informou o uso deste período' })
	exit 0
}
Out-Doc @($report) @()
