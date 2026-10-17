# Usage for providers that work with an API key, for the AI Limits plugin,
# printed as one `omp usage --json` document. Keys come from what the user saved
# with "Limites de IA: chaves de API" (the plugin's Windows Credential Manager
# entries) or from each provider's own environment variable; they only go to
# that provider's API.
$ErrorActionPreference = 'Stop'
# Messages follow the plugin's language (AI_LIMITS_LANG, set by the host).
function T([string]$en, [string]$pt) { if ($env:AI_LIMITS_LANG -eq 'pt') { $pt } else { $en } }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$reports = New-Object System.Collections.Generic.List[object]
$disabled = New-Object System.Collections.Generic.List[object]

Add-Type -Namespace AiLimits -Name Cred -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
	public int Flags; public int Type; public string TargetName; public string Comment;
	public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
	public int Persist; public int AttributeCount; public IntPtr Attributes;
	public string TargetAlias; public string UserName;
}
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
[DllImport("advapi32.dll")]
public static extern void CredFree(IntPtr cred);
'@

# tern.secrets keeps each one as the generic credential
# so.stencil.tern/plugin.ai-limits.<name>, its bytes as given.
function Saved([string]$name) {
	$p = [IntPtr]::Zero
	if (-not [AiLimits.Cred]::CredRead("so.stencil.tern/plugin.ai-limits.$name", 1, 0, [ref]$p)) { return $null }
	try {
		$c = [Runtime.InteropServices.Marshal]::PtrToStructure($p, [type][AiLimits.Cred+CREDENTIAL])
		if ($c.CredentialBlobSize -le 0) { return $null }
		$buf = New-Object byte[] $c.CredentialBlobSize
		[Runtime.InteropServices.Marshal]::Copy($c.CredentialBlob, $buf, 0, $buf.Length)
		return [Text.Encoding]::UTF8.GetString($buf).Trim()
	} finally {
		[AiLimits.Cred]::CredFree($p)
	}
}

function Env([string[]]$names) {
	foreach ($n in $names) {
		$v = [Environment]::GetEnvironmentVariable($n, 'Process')
		if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'User') }
		if ($v) { return $v.Trim() }
	}
	return $null
}

function Problem([string]$provider, [string]$cause) {
	$disabled.Add(@{ provider = $provider; email = $null; cause = $cause })
}

function Status($err) {
	if ($err.Exception.Response) { return [int]$err.Exception.Response.StatusCode }
	return $null
}

function Fraction($pct) {
	return [Math]::Max(0.0, [Math]::Min(1.0, [double]$pct / 100))
}

function Ms($v) {
	if ($null -eq $v -or $v -eq '') { return $null }
	$n = 0.0
	if ([double]::TryParse([string]$v, [ref]$n)) {
		if ($n -gt 1e12) { return [long]$n }
		return [long]($n * 1000)
	}
	try { return ([DateTimeOffset]::Parse([string]$v)).ToUnixTimeMilliseconds() } catch { return $null }
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# Factory (Droid): an API key from app.factory.ai, FACTORY_API_KEY or ~/.factory/.env.
$factory = Saved 'factory'
if (-not $factory) { $factory = Env @('FACTORY_API_KEY') }
if (-not $factory) {
	$envFile = Join-Path $env:USERPROFILE '.factory\.env'
	if (Test-Path -LiteralPath $envFile) {
		$m = Select-String -LiteralPath $envFile -Pattern '^\s*(export\s+)?FACTORY_API_KEY\s*=\s*"?([^"\s]+)"?' | Select-Object -First 1
		if ($m) { $factory = $m.Matches[0].Groups[2].Value }
	}
}
if ($factory) {
	try {
		$r = Invoke-RestMethod -Uri 'https://api.factory.ai/api/billing/limits' -TimeoutSec 15 -UseBasicParsing `
			-Headers @{ Authorization = "Bearer $factory"; Accept = 'application/json'; 'x-factory-client' = 'web-app' }
		$limits = New-Object System.Collections.Generic.List[object]
		foreach ($pool in @(@('standard', 'Standard credits'), @('core', 'Droid Core'))) {
			$p = $r.limits.($pool[0])
			if (-not $p) { continue }
			foreach ($w in @(@('fiveHour', '5 Hour', 18000000), @('weekly', 'Weekly', 604800000), @('monthly', 'Monthly', 2592000000))) {
				$win = $p.($w[0])
				if ($null -eq $win -or $null -eq $win.usedPercent) { continue }
				$reset = if ($win.secondsRemaining -gt 0) { $now + [long]($win.secondsRemaining * 1000) } else { Ms $win.windowEnd }
				$used = Fraction $win.usedPercent
				# A short window can keep its old value after it ends; Factory's own page reads that as reset.
				if ($win.windowEnd -and -not $win.secondsRemaining -and ($null -eq $reset -or $reset -le $now)) { $used = 0.0; $reset = $null }
				$limits.Add(@{ label = "$($pool[1]) $($w[1])"; window = @{ durationMs = $w[2]; resetsAt = $reset }; amount = @{ usedFraction = $used; unit = 'percent' } })
			}
		}
		if ($limits.Count -gt 0) {
			$reports.Add(@{ provider = 'factory-droid'; metadata = @{ accountId = 'api-key' }; limits = $limits.ToArray() })
		} else {
			Problem 'factory-droid' (T 'this Factory account has no window limits' 'a conta da Factory não usa limites por janela')
		}
	} catch {
		$c = Status $_
		Problem 'factory-droid' $(if ($c -eq 401 -or $c -eq 403) { (T 'Factory rejected the API key' 'a Factory recusou a chave de API') } else { (T "Factory did not answer ($c)" "a Factory não respondeu ($c)") })
	}
}

# OpenCode Go: OPENCODE_API_KEY or the saved key.
$opencode = Saved 'opencode-go'
if (-not $opencode) { $opencode = Env @('OPENCODE_API_KEY') }
if ($opencode) {
	try {
		$r = Invoke-RestMethod -Uri 'https://opencode.ai/zen/go/v1/usage' -TimeoutSec 15 -UseBasicParsing `
			-Headers @{ Authorization = "Bearer $opencode"; Accept = 'application/json' }
		$limits = New-Object System.Collections.Generic.List[object]
		foreach ($w in @(@('rolling', '5 Hour', 18000000), @('weekly', 'Weekly', 604800000), @('monthly', 'Monthly', 2592000000))) {
			$win = $r.usage.($w[0])
			if ($null -eq $win) { continue }
			# The API speaks percentage units: 1 means 1%.
			$pct = if ($null -ne $win.percent) { $win.percent } elseif ($null -ne $win.usagePercent) { $win.usagePercent } else { $null }
			if ($null -eq $pct) { continue }
			$reset = if ($win.resetInSec) { $now + [long]$win.resetInSec * 1000 } else { Ms $win.resetsAt }
			$limits.Add(@{ label = $w[1]; window = @{ durationMs = $w[2]; resetsAt = $reset }; amount = @{ usedFraction = (Fraction $pct); unit = 'percent' } })
		}
		if ($limits.Count -gt 0) {
			$reports.Add(@{ provider = 'opencode-go'; metadata = @{ accountId = 'api-key' }; limits = $limits.ToArray() })
		} else {
			Problem 'opencode-go' (T 'OpenCode Go did not report usage' 'o OpenCode Go não informou o uso')
		}
	} catch {
		$c = Status $_
		Problem 'opencode-go' $(if ($c -eq 401 -or $c -eq 403) { (T 'OpenCode rejected the API key' 'o OpenCode recusou a chave de API') } else { (T "OpenCode did not answer ($c)" "o OpenCode não respondeu ($c)") })
	}
}

# Command Code: COMMANDCODE_API_KEY or the saved key.
$cmdcode = Saved 'commandcode'
if (-not $cmdcode) { $cmdcode = Env @('COMMANDCODE_API_KEY', 'COMMAND_CODE_API_KEY') }
if ($cmdcode) {
	try {
		$r = Invoke-RestMethod -Uri 'https://api.commandcode.ai/alpha/billing/credits' -TimeoutSec 15 -UseBasicParsing `
			-Headers @{ Authorization = "Bearer $cmdcode"; Accept = 'application/json' }
		$limits = New-Object System.Collections.Generic.List[object]
		$windows = if ($r.windowLimits) { $r.windowLimits } else { $r.credits.windowLimits }
		foreach ($w in @(@('fiveHour', '5 Hour', 18000000), @('weekly', 'Weekly', 604800000))) {
			$win = $windows.($w[0])
			if ($null -eq $win -or -not ($win.cap -gt 0)) { continue }
			$limits.Add(@{ label = $w[1]; window = @{ durationMs = $w[2]; resetsAt = (Ms $win.resetAt) }; amount = @{ used = [double]$win.used; limit = [double]$win.cap } })
		}
		# monthlyCredits is what is left of the plan's grant.
		$granted = $r.credits.monthlyCreditsGranted
		if ($granted -gt 0 -and $null -ne $r.credits.monthlyCredits) {
			$left = [double]$r.credits.monthlyCredits
			$limits.Add(@{ label = 'Credits Plan Period'; window = @{ id = 'plan' }; amount = @{ usedFraction = [Math]::Max(0.0, [Math]::Min(1.0, 1 - $left / $granted)); unit = 'percent' } })
		}
		if ($limits.Count -gt 0) {
			$reports.Add(@{ provider = 'commandcode'; metadata = @{ accountId = 'api-key' }; limits = $limits.ToArray() })
		} else {
			Problem 'commandcode' (T 'Command Code did not report limits' 'o Command Code não informou limites')
		}
	} catch {
		$c = Status $_
		Problem 'commandcode' $(if ($c -eq 401 -or $c -eq 403) { (T 'Command Code rejected the API key' 'o Command Code recusou a chave de API') } else { (T "Command Code did not answer ($c)" "o Command Code não respondeu ($c)") })
	}
}

$doc = @{ reports = $reports.ToArray(); disabledCredentials = $disabled.ToArray(); generatedAt = $now }
[Console]::Out.Write(($doc | ConvertTo-Json -Depth 10 -Compress))
