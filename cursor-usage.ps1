# Cursor usage for the AI Limits plugin, printed as an `omp usage --json`
# document so the plugin's model reads it like omp's reports. The session is
# read, never written, and the token only goes to Cursor's own API.
$ErrorActionPreference = 'Stop'

function Out-Doc($reports, $disabled) {
	$doc = @{ reports = @($reports); disabledCredentials = @($disabled); generatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
	[Console]::Out.Write(($doc | ConvertTo-Json -Depth 10 -Compress))
}

function Out-Problem([string]$cause, $email) {
	Out-Doc @() @(@{ provider = 'cursor'; email = $email; cause = $cause })
	exit 0
}

# Two places hold a session: the Cursor app's state database, and the file
# `cursor-agent login` (the CLI) writes. Either one is enough.
$db = Join-Path $env:APPDATA 'Cursor\User\globalStorage\state.vscdb'
$cliAuth = Join-Path $env:APPDATA 'Cursor\auth.json'
$token = $null
$email = $null
$membership = $null

if (Test-Path -LiteralPath $db) {
	Add-Type -Namespace AiLimits -Name Sqlite -MemberDefinition @'
[DllImport("winsqlite3.dll")]
public static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
[DllImport("winsqlite3.dll")]
public static extern int sqlite3_close(IntPtr db);
[DllImport("winsqlite3.dll")]
public static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
[DllImport("winsqlite3.dll")]
public static extern int sqlite3_bind_text(IntPtr stmt, int i, byte[] text, int n, IntPtr destructor);
[DllImport("winsqlite3.dll")]
public static extern int sqlite3_step(IntPtr stmt);
[DllImport("winsqlite3.dll")]
public static extern IntPtr sqlite3_column_blob(IntPtr stmt, int col);
[DllImport("winsqlite3.dll")]
public static extern int sqlite3_column_bytes(IntPtr stmt, int col);
[DllImport("winsqlite3.dll")]
public static extern int sqlite3_finalize(IntPtr stmt);
'@

	function Utf8z([string]$s) { [Text.Encoding]::UTF8.GetBytes($s + [char]0) }

	$uri = 'file:' + ($db -replace '\\', '/') + '?mode=ro'
	$h = [IntPtr]::Zero
	# SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
	if ([AiLimits.Sqlite]::sqlite3_open_v2((Utf8z $uri), [ref]$h, 0x41, [IntPtr]::Zero) -eq 0) {
		function Read-Value([string]$key) {
			$stmt = [IntPtr]::Zero
			if ([AiLimits.Sqlite]::sqlite3_prepare_v2($h, (Utf8z 'SELECT value FROM ItemTable WHERE key = ?1'), -1, [ref]$stmt, [IntPtr]::Zero) -ne 0) {
				return $null
			}
			try {
				$k = [Text.Encoding]::UTF8.GetBytes($key)
				# SQLITE_TRANSIENT (-1): SQLite copies the key.
				[AiLimits.Sqlite]::sqlite3_bind_text($stmt, 1, $k, $k.Length, [IntPtr](-1)) | Out-Null
				if ([AiLimits.Sqlite]::sqlite3_step($stmt) -ne 100) { return $null }
				$n = [AiLimits.Sqlite]::sqlite3_column_bytes($stmt, 0)
				if ($n -le 0) { return $null }
				$buf = New-Object byte[] $n
				[Runtime.InteropServices.Marshal]::Copy([AiLimits.Sqlite]::sqlite3_column_blob($stmt, 0), $buf, 0, $n)
				# Values are UTF-8, but some builds store UTF-16LE.
				if ($n -ge 2 -and $buf[1] -eq 0) { return [Text.Encoding]::Unicode.GetString($buf) }
				return [Text.Encoding]::UTF8.GetString($buf)
			} finally {
				[AiLimits.Sqlite]::sqlite3_finalize($stmt) | Out-Null
			}
		}
		try {
			$token = Read-Value 'cursorAuth/accessToken'
			$email = Read-Value 'cursorAuth/cachedEmail'
			$membership = Read-Value 'cursorAuth/stripeMembershipType'
		} finally {
			[AiLimits.Sqlite]::sqlite3_close($h) | Out-Null
		}
	}
}

if (-not $token -and (Test-Path -LiteralPath $cliAuth)) {
	$token = (Get-Content -LiteralPath $cliAuth -Raw | ConvertFrom-Json).accessToken
	$config = Join-Path $env:USERPROFILE '.cursor\cli-config.json'
	if (-not $email -and (Test-Path -LiteralPath $config)) {
		$email = (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).authInfo.email
	}
}

if (-not (Test-Path -LiteralPath $db) -and -not (Test-Path -LiteralPath $cliAuth)) {
	Out-Doc @() @()
	exit 0
}
if ($email) { $email = $email.Trim().Trim('"') }
if ($membership) { $membership = $membership.Trim().Trim('"') }
if (-not $token) { Out-Problem 'Cursor sem login: entre no app ou rode cursor-agent login' $email }
$token = $token.Trim().Trim('"')

$parts = $token.Split('.')
if ($parts.Count -lt 2) { Out-Problem 'login do Cursor ilegível' $email }
$p = $parts[1].Replace('-', '+').Replace('_', '/')
switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
if ($claims.exp -and [long]$claims.exp -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60) {
	Out-Problem 'login do Cursor expirado: abra o app ou rode cursor-agent login' $email
}
$user = ([string]$claims.sub).Split('|')[-1]

# The dashboard service the Cursor app and CLI themselves call; it takes the
# session as a bearer token (cursor.com's web API only takes the app's cookie).
function Call([string]$method) {
	Invoke-RestMethod -Method Post -Uri "https://api2.cursor.sh/aiserver.v1.DashboardService/$method" -Body '{}' `
		-ContentType 'application/json' -TimeoutSec 20 -UseBasicParsing `
		-Headers @{ Authorization = "Bearer $token"; 'Connect-Protocol-Version' = '1' }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
	$u = Call 'GetCurrentPeriodUsage'
} catch {
	$code = $null
	if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
	if ($code -eq 401 -or $code -eq 403) { Out-Problem 'o Cursor recusou o login: abra o app ou rode cursor-agent login' $email }
	Out-Problem "o Cursor não respondeu ($code)" $email
}
try { $planName = (Call 'GetPlanInfo').planInfo.planName } catch { $planName = $null }
if (-not $planName) { $planName = $membership }

# Percent fields are already percentages (0.36 means 0.36%).
function Fraction($pct) {
	if ($null -eq $pct) { return $null }
	return [Math]::Max(0.0, [Math]::Min(1.0, [double]$pct / 100))
}

# No durationMs: billing months vary, and the plugin names this window "plano".
$window = @{ id = 'cycle'; label = 'Plan Period' }
if ($u.billingCycleEnd) { $window.resetsAt = [long]$u.billingCycleEnd }

$limits = @()
$plan = $u.planUsage
foreach ($pair in @(@('Total', $plan.totalPercentUsed), @('Auto', $plan.autoPercentUsed), @('API', $plan.apiPercentUsed))) {
	$f = Fraction $pair[1]
	if ($null -ne $f) {
		$limits += @{ label = $pair[0]; window = $window; amount = @{ usedFraction = $f; unit = 'percent' } }
	}
}
$spend = $u.spendLimitUsage
if ($spend -and $spend.individualLimit -gt 0 -and $null -ne $spend.individualUsed) {
	$limits += @{ label = 'On-demand (US$)'; window = $window; amount = @{ used = [Math]::Round([double]$spend.individualUsed / 100, 2); limit = [Math]::Round([double]$spend.individualLimit / 100, 2) } }
}
if ($limits.Count -eq 0) { Out-Problem 'o Cursor não informou o uso deste ciclo' $email }

Out-Doc @(@{ provider = 'cursor'; metadata = @{ email = $email; accountId = $user; planType = $planName }; limits = $limits }) @()
