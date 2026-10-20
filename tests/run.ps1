# Runs tests/cases.luau against model.luau and prefs.luau with the Luau CLI
# (https://github.com/luau-lang/luau/releases). Pass its path, or put luau.exe
# on PATH:  powershell -File tests\run.ps1 [-Luau C:\path\luau.exe]
param([string]$Luau = 'luau')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Body([string]$file) {
	(Get-Content -LiteralPath (Join-Path $root $file) -Raw) -replace '(?m)^--!strict\s*$', '' -replace 'require\("\./model"\)', 'model'
}
$bundle = @"
local store: { [string]: any } = {}
local tern = {
	json = { array = function(t) return t end, encode = function(_v) return "{}" end, decode = function(_s) return {} end },
	kv = {
		get = function(key: string) return store[key] end,
		set = function(key: string, value: any) store[key] = value end,
	},
	plugin = { data = "memory" },
	fs = {
		exists = function(_p) return false end,
		read = function(_p, _n) return "{}" end,
		write = function(_p, _text) end,
		mkdir = function(_p) end,
	},
	log = { warn = function(...) end },
}
local model = (function()
$(Body 'model.luau')
end)()
local prefs = (function()
$(Body 'prefs.luau')
end)()
local history = (function()
$(Body 'history.luau')
end)()
$(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'cases.luau') -Raw)
"@
$out = Join-Path $env:TEMP 'ai-limits-tests.luau'
# UTF-8 without a BOM: Luau rejects one.
[IO.File]::WriteAllText($out, $bundle, (New-Object Text.UTF8Encoding $false))
& $Luau $out
exit $LASTEXITCODE
