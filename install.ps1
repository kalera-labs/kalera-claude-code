# Kalera Claude Code — Windows Installer (PowerShell)
# Installs kalera-claude-code + Munin memory system into Claude Code on Windows
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Components "languages/typescript,security"
#
# Flags:
#   -Components  Comma-separated groups (security,codereview,tdd,languages/typescript)
#   -Select      Interactive TUI menu
#   -Yes         Skip all prompts, apply all auto-fix actions
#   -DryRun      Show what would be done without making changes
#   -Verbose     Print every command as it runs

#Requires -Version 5.1

param(
    [string]$Components,
    [switch]$Select,
    [switch]$Yes,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ─── Constants ──────────────────────────────────────────────────────
# SHA256 is computed over the file with the INSTALL_PS1_PIN line normalized,
# so the pin can include itself without a chicken-and-egg problem.
#
# WORKFLOW TO UPDATE PIN (after any change to this script):
#   1. Edit install.ps1 locally.
#   2. PowerShell: $h = (Get-Content install.ps1 -Raw) -replace '\$INSTALL_PS1_PIN\s*=\s*".*"','$INSTALL_PS1_PIN = "PINNED"'
#                  [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($h))).Replace("-","").ToLower()
#      Bash:       sed 's|^\$INSTALL_PS1_PIN.*|$INSTALL_PS1_PIN = "PINNED"|' install.ps1 | sha256sum | cut -d' ' -f1
#   3. Paste the result into INSTALL_PS1_PIN below.
#   4. git commit + git push.
$INSTALL_PS1_PIN = "93f26d2782732f28aa6781c13996547ad6865ce39c7ae000a76a52a28c413418"
$REPO_URL        = "https://github.com/kalera-labs/kalera-claude-code.git"
$GITHUB_RAW      = "https://raw.githubusercontent.com/kalera-labs/kalera-claude-code/main/install.ps1"

# ─── Helpers ───────────────────────────────────────────────────────
function Get-NormalizedHash {
    param([string]$Path)
    $content = Get-Content $Path -Raw
    $normalized = $content -replace '(?m)^\$INSTALL_PS1_PIN\s*=\s*".*"', '$INSTALL_PS1_PIN = "PINNED"'
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $sha   = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($sha) -replace '-', '').ToLower()
}

function Get-ScriptHash {
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($GITHUB_RAW, $tmp)
        $hash = Get-NormalizedHash -Path $tmp
        return @{ Hash = $hash; Path = $tmp }
    }
    catch {
        Remove-Item $tmp -Force -EA SilentlyContinue
        throw "Failed to download install.ps1 for verification: $_"
    }
}

function Write-Fail($msg) {
    Write-Host "❌ $msg" -ForegroundColor Red
}

function Write-Info($msg) {
    Write-Host "   $msg"
}

function Write-Step($msg) {
    Write-Host "$msg"
}

# ─── Integrity check ───────────────────────────────────────────────
if (-not $DryRun) {
    Write-Verbose "Verifying script integrity..."
    $result = Get-ScriptHash
    if ($result.Hash -ne $INSTALL_PS1_PIN) {
        Write-Fail "Script integrity check FAILED (SHA256 mismatch)"
        Write-Host "   Expected: $INSTALL_PS1_PIN" -ForegroundColor Red
        Write-Host "   Got:      $($result.Hash)" -ForegroundColor Red
        Write-Host "   The script may have been tampered with. Aborting." -ForegroundColor Red
        Remove-Item $result.Path -Force -EA SilentlyContinue
        exit 1
    }
    Remove-Item $result.Path -Force -EA SilentlyContinue
    Write-Verbose "Integrity check passed."
}

# ─── Detect if running from curl / web ──────────────────────────────
$runningFromWeb = $PSCommandPath -eq '' -or $PSCommandPath -match 'Microsoft.PowerShell'

# ─── Resolve repo / install directory ───────────────────────────────
$scriptRoot = if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
    Split-Path $PSCommandPath -Parent
} else {
    Get-Location
}

$pluginMetaPath = Join-Path $scriptRoot '.claude-plugin'

$installTemp = $null
if (-not (Test-Path $pluginMetaPath)) {
    $installTemp = Join-Path ([System.IO.Path]::GetTempPath()) "kalera-claude-code-$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -ItemType Directory -Path $installTemp -Force | Out-Null
    Write-Step "Cloning kalera-claude-code to temp directory..."
    if (-not $DryRun) {
        git clone --depth 1 $REPO_URL $installTemp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Git clone failed — check network and try again"
            Remove-Item $installTemp -Recurse -Force -EA SilentlyContinue
            exit 1
        }
    }
    $scriptRoot = $installTemp
}

# ─── Detect Claude CLI ─────────────────────────────────────────────
$claudeCmd = Get-Command claude -EA SilentlyContinue
if (-not $claudeCmd) {
    Write-Fail "Claude Code CLI not found."
    Write-Host "   Install from: https://claude.ai/code" -ForegroundColor Cyan
    if ($installTemp) { Remove-Item $installTemp -Recurse -Force -EA SilentlyContinue }
    exit 1
}
Write-Verbose "Found Claude CLI at: $($claudeCmd.Source)"

# ─── Detect Git ───────────────────────────────────────────────────
$gitCmd = Get-Command git -EA SilentlyContinue
if (-not $gitCmd) {
    Write-Fail "Git not found. Please install Git for Windows: https://git-scm.com/download/win"
    if ($installTemp) { Remove-Item $installTemp -Recurse -Force -EA SilentlyContinue }
    exit 1
}
Write-Verbose "Found Git at: $($gitCmd.Source)"

# ─── Resolve paths ─────────────────────────────────────────────────
$claudeConfigDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:APPDATA 'Claude' }
$settingsFile    = Join-Path $claudeConfigDir 'settings.json'
$rulesDest       = Join-Path $claudeConfigDir 'rules'

# ─── Parse component flags ─────────────────────────────────────────
$selectedLang    = @()
$selectedGroups  = @{}
$hasComponents  = [bool]$Components -or $Select

$allLanguages = @('typescript','python','golang','java','kotlin','cpp','rust','swift','php','dart')

function Parse-Components($input) {
    if (-not $input) { return }

    $tokens = $input -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    foreach ($tok in $tokens) {
        if ($tok -eq 'all') {
            $script:selectedLang = @()
            $script:hasComponents = $false
            return
        }

        if ($tok -like 'languages/*') {
            $lang = ($tok -replace '^languages/', '').Trim()
            if ($lang -and $script:allLanguages -contains $lang) {
                if ($script:selectedLang -notcontains $lang) {
                    $script:selectedLang += $lang
                }
            }
        }
        else {
            $script:selectedGroups[$tok] = $true
        }
    }

    # if only groups specified (no languages/*), default to all langs
    $langTokens = $tokens | Where-Object { $_ -like 'languages/*' }
    if (-not $langTokens -and $script:selectedLang.Count -eq 0) {
        $script:selectedLang = $script:allLanguages.Clone()
    }
    $script:hasComponents = $true
}

function Add-Language($lang) {
    if ($script:selectedLang -notcontains $lang) {
        $script:selectedLang += $lang
    }
}

# ─── Interactive select menu ───────────────────────────────────────
function Select-Components {
    Write-Host ""
    Write-Host "🧩 Component Selection" -ForegroundColor Cyan
    Write-Host ("─" * 20)
    Write-Host "  [a] All (install everything)"
    Write-Host "  [s] Security       — agents + rules for security scanning"
    Write-Host "  [c] Code Review    — review agents for all languages"
    Write-Host "  [t] TDD            — test-driven development workflow"
    Write-Host "  [p] Performance    — optimization and profiling agents"
    Write-Host "  [d] Database       — SQL patterns, migrations, JPA"
    Write-Host "  [o] DevOps        — Docker, deployment, CI/CD"
    Write-Host "  [w] Documentation — doc generation, README helpers"
    Write-Host "  [k] Workflow      — PR workflow, autonomous loops"
    Write-Host ""
    Write-Host "  [m] Languages     — pick specific language rulesets"
    Write-Host ""

    while ($true) {
        $resp = Read-Host "Select components (e.g. s,c,t or a for all)"
        $resp = $resp.Trim()

        if (-not $resp) { continue }

        if ($resp -eq 'a') {
            $script:selectedLang = @()
            $script:hasComponents = $false
            return
        }

        foreach ($c in $resp.ToCharArray()) {
            switch ($c) {
                's' { $script:selectedGroups['security']    = $true }
                'c' { $script:selectedGroups['codereview']  = $true }
                't' { $script:selectedGroups['tdd']         = $true }
                'p' { $script:selectedGroups['performance']= $true }
                'd' { $script:selectedGroups['database']    = $true }
                'o' { $script:selectedGroups['devops']      = $true }
                'w' { $script:selectedGroups['documentation']=$true }
                'k' { $script:selectedGroups['workflow']   = $true }
                'm' { Select-Languages }
            }
        }
        $script:hasComponents = $true
        return
    }
}

function Select-Languages {
    Write-Host ""
    Write-Host "🌐 Language Rulesets" -ForegroundColor Cyan
    Write-Host ("─" * 20)
    for ($i = 0; $i -lt $allLanguages.Count; $i++) {
        Write-Host ("  [{1,2}] {0}" -f $allLanguages[$i], ($i + 1))
    }
    Write-Host ""
    $resp = Read-Host "Select languages (e.g. 1,3,5 or 0 for all)"
    $resp = $resp.Trim()

    if ($resp -eq '0' -or -not $resp) {
        $script:selectedLang = $allLanguages.Clone()
        return
    }

    foreach ($tok in ($resp -split ',')) {
        $idx = [int]$tok.Trim() - 1
        if ($idx -ge 0 -and $idx -lt $allLanguages.Count) {
            Add-Language $allLanguages[$idx]
        }
    }
}

# ─── Process flags ────────────────────────────────────────────────
if ($Select) {
    Select-Components
}
elseif ($Components) {
    Parse-Components $Components
}

# Fallback: if no language selected yet, use all
if ($selectedLang.Count -eq 0) {
    $selectedLang = $allLanguages.Clone()
}

# ─── Print selected summary ───────────────────────────────────────
if ($hasComponents -and $selectedLang.Count -gt 0) {
    Write-Host "📦 Selected languages: $($selectedLang -join ', ')"
}
if ($hasComponents -and $selectedGroups.Count -gt 0) {
    Write-Host "📦 Selected groups: $($selectedGroups.Keys -join ', ')"
}

# ─── Header ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "🚀 Kalera Claude Code — Installer (Windows)" -ForegroundColor Green
Write-Host ("=" * 34)
Write-Host ""

# ─── Detect existing plugins ───────────────────────────────────────
Write-Step "Checking existing installations..."

$pluginList = if ($claudeCmd) {
    claude plugin list 2>$null | Out-String
} else { '' }

$hasOldECC   = $pluginList -match 'everything-claude-code.*affaan-m'
$hasOldMunin = $pluginList -match 'munin-claude-code.*munin-ecosystem'
$hasContext7 = if (Test-Path $settingsFile) {
    (Get-Content $settingsFile -Raw) -match 'context7'
} else { $false }
$hasPlaywright = if (Test-Path $settingsFile) {
    (Get-Content $settingsFile -Raw) -match '"playwright"'
} else { $false }

# ─── Handle conflicts ─────────────────────────────────────────────
if ($hasOldECC) {
    Write-Host "⚠️  CONFLICT: Everything Claude Code detected from upstream" -ForegroundColor Yellow
    Write-Host "   Source: affaan-m/everything-claude-code"
    Write-Host "   → kalera-claude-code is a fork that replaces this."
    Write-Host ""

    if ($Yes) {
        if ($DryRun) {
            Write-Host "   [dry-run] would: claude plugin uninstall everything-claude-code@affaan-m/everything-claude-code"
        }
        else {
            Write-Step "  → Uninstalling old version..."
            claude plugin uninstall everything-claude-code@affaan-m/everything-claude-code 2>&1 | Out-Null
            Write-Host "   ✅ Old ECC removed." -ForegroundColor Green
        }
    }
    else {
        Write-Host "   ⏭  Skipped — old ECC kept."
    }
    Write-Host ""
}

if ($hasOldMunin) {
    Write-Host "⚠️  CONFLICT: Munin detected from old source" -ForegroundColor Yellow
    Write-Host "   Source: munin-ecosystem (kalera-labs/munin-for-agents)"
    Write-Host "   → kalera-claude-code includes the latest Munin plugin."
    Write-Host ""

    if ($Yes) {
        if ($DryRun) {
            Write-Host "   [dry-run] would: claude plugin uninstall munin-claude-code@munin-ecosystem"
        }
        else {
            Write-Step "  → Uninstalling old version..."
            claude plugin uninstall munin-claude-code@munin-ecosystem 2>&1 | Out-Null
            Write-Host "   ✅ Old Munin removed." -ForegroundColor Green
        }
    }
    else {
        Write-Host "   ⏭  Skipped — old Munin kept."
    }
    Write-Host ""
}

if ($hasContext7) {
    Write-Host "⚠️  NOTE: Context7 MCP found in settings.json" -ForegroundColor Yellow
    Write-Host "   → kalera-claude-code skips its own copy (you already have it)."
    Write-Host "   ⏭  Context7 in settings.json untouched."
    Write-Host ""
}

if ($hasPlaywright) {
    Write-Host "⚠️  NOTE: Playwright MCP found in settings.json" -ForegroundColor Yellow
    Write-Host "   → kalera-claude-code skips its own copy (you already have it)."
    Write-Host "   ⏭  Playwright in settings.json untouched."
    Write-Host ""
}

Write-Host "✅ Conflict check complete."
Write-Host ""

# ─── Add marketplace ───────────────────────────────────────────────
Write-Step "📦 Adding Kalera marketplace..."
if ($DryRun) {
    Write-Info "[dry-run] would: claude plugin marketplace add kalera-labs/kalera-claude-code"
}
else {
    $mktResult = claude plugin marketplace add kalera-labs/kalera-claude-code 2>&1
    $mktRc     = $LASTEXITCODE
    if ($mktRc -ne 0) {
        Write-Info "Marketplace add failed (rc=$mktRc): $mktResult"
        Write-Info "Will attempt direct plugin install anyway..."
    }
}

# ─── Install ECC ───────────────────────────────────────────────────
Write-Step "⚙️  Installing kalera-claude-code..."
if (-not $DryRun) {
    $eccErr = claude plugin install kalera-claude-code@kalera-claude-code 2>&1 | Out-String
    $eccRc  = $LASTEXITCODE

    if ($eccRc -eq 0) {
        Write-Host "   ✅ kalera-claude-code installed" -ForegroundColor Green
    }
    elseif ($eccRc -eq 2) {
        Write-Fail "   Plugin 'kalera-claude-code' not found in marketplace 'kalera-labs/kalera-claude-code'"
    }
    elseif ($eccRc -eq 3) {
        Write-Fail "   Plugin 'kalera-claude-code' already installed — skip or uninstall first"
    }
    else {
        Write-Fail "   Install failed (rc=$eccRc): $eccErr"
    }
}

# ─── Install Munin ─────────────────────────────────────────────────
Write-Step "🧠 Installing Munin memory plugin..."
if (-not $DryRun) {
    $munErr = claude plugin install munin-claude-code@kalera-claude-code 2>&1 | Out-String
    $munRc  = $LASTEXITCODE

    if ($munRc -ne 0) {
        # Fallback to old marketplace
        $munErr2 = claude plugin install munin-claude-code@munin-ecosystem 2>&1 | Out-String
        $munRc2  = $LASTEXITCODE
        if ($munRc2 -eq 0) { $munRc = 0; $munErr = '' }
        else { $munErr = "primary: $munErr; fallback: $munErr2" }
    }

    if ($munRc -eq 0) {
        Write-Host "   ✅ munin-claude-code installed" -ForegroundColor Green
    }
    elseif ($munRc -eq 2) {
        Write-Fail "   Plugin not found on marketplace 'kalera-labs/kalera-claude-code'"
    }
    elseif ($munRc -eq 3) {
        Write-Fail "   Plugin already installed — skip or uninstall first"
    }
    else {
        Write-Fail "   Install failed (rc=$munRc): $munErr"
    }
}

# ─── Install rules ────────────────────────────────────────────────
Write-Step ""
Write-Step "📋 Installing rules..."
if ($DryRun) {
    Write-Info "[dry-run] would: copy rules/common + selected language rulesets to $rulesDest"
}
elseif (Test-Path (Join-Path $scriptRoot 'rules')) {
    if (-not (Test-Path $rulesDest)) {
        New-Item -ItemType Directory -Path $rulesDest -Force | Out-Null
    }

    $commonSrc = Join-Path $scriptRoot 'rules\common'
    if (Test-Path $commonSrc) {
        foreach ($f in Get-ChildItem $commonSrc -File) {
            $dest = Join-Path $rulesDest $f.Name
            if (Test-Path $dest) {
                $bak = "$dest.kalera.bak"
                Copy-Item $f.FullName $bak -Force
                Write-Info "📝 rules/common/$($f.Name) (backed up existing → .kalera.bak)"
            }
            else {
                Copy-Item $f.FullName $dest -Force
            }
        }
        Write-Host "   ✅ rules/common/" -ForegroundColor Green
    }

    foreach ($lang in $selectedLang) {
        $langSrc  = Join-Path $scriptRoot "rules\$lang"
        $langDest = Join-Path $rulesDest $lang
        if (Test-Path $langSrc) {
            if (-not (Test-Path $langDest)) {
                New-Item -ItemType Directory -Path $langDest -Force | Out-Null
            }
            foreach ($f in Get-ChildItem $langSrc -File) {
                $dest = Join-Path $langDest $f.Name
                if (Test-Path $dest) {
                    $bak = "$dest.kalera.bak"
                    Copy-Item $f.FullName $bak -Force
                    Write-Info "📝 rules/$lang/$($f.Name) (backed up existing → .kalera.bak)"
                }
                else {
                    Copy-Item $f.FullName $dest -Force
                }
            }
            Write-Host "   ✅ rules/$lang/" -ForegroundColor Green
        }
    }
}

# ─── Cleanup temp ──────────────────────────────────────────────────
if ($installTemp -and (Test-Path $installTemp)) {
    Write-Verbose "Cleaning up temp directory: $installTemp"
    Remove-Item $installTemp -Recurse -Force -EA SilentlyContinue
}

# ─── Done ──────────────────────────────────────────────────────────
Write-Host ""
Write-Host "✅ Kalera Claude Code installed!" -ForegroundColor Green
if ($DryRun) { Write-Host "   (dry-run — no changes made)" -ForegroundColor Yellow }
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Restart Claude Code"
Write-Host "  2. Sign up at https://munin.kalera.ai (free)"
Write-Host "  3. Run: /munin:projectid"
Write-Host "     → It will show current ID or prompt you to set it"
Write-Host ""
Write-Host "Docs: https://github.com/kalera-labs/kalera-claude-code"
