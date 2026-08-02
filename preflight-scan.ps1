# NORTHSTAR - repo-public pre-flight scan v2 (PowerShell)
# Fixes v1 false positives: word-boundaries (so "AgentCsv" != "tcs") and skips binary files.
# Run INSIDE your local zero-access-agent repo.

$ErrorActionPreference = 'Continue'
# \b = word boundary; short/ambiguous tokens are boundaried so substrings don't trip them.
$pat = '\bmetso\b|\btcs\b|euc-intelligence|search\.windows\.net|openai\.azure\.com|AP-PF64KXER|WVD-TCSM365|\brobopack\b|\bespoo\b|\b217128\b|\b236188\b|\b203880\b|rg-wsteu|proj-endpoint-assistant|AI-ASE-euc'
$fail = $false

Write-Host "============================================"
Write-Host " NORTHSTAR pre-flight scan v2"
Write-Host "============================================"

Write-Host "`n== 1. gitleaks - secrets across FULL history =="
if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    gitleaks detect --source . --log-opts="--all" --redact --report-path gitleaks-report.json 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "   PASS: 0 leaks" -ForegroundColor Green }
    else { Write-Host "   !! FAIL: gitleaks found something - open gitleaks-report.json" -ForegroundColor Red; $fail = $true }
} else { Write-Host "   gitleaks not installed" -ForegroundColor Yellow }

# -P = PCRE (needed for \b) ; -I = ignore binary files
Write-Host "`n== 2. identity denylist - working tree (text files only) =="
$wt = git grep -nIP $pat -- .
if ($LASTEXITCODE -eq 0 -and $wt) { $wt | ForEach-Object { Write-Host $_ }; Write-Host "   !! FAIL (working tree)" -ForegroundColor Red; $fail = $true }
else { Write-Host "   PASS: working tree CLEAN" -ForegroundColor Green }

Write-Host "`n== 3. identity denylist - FULL history (text files only) =="
$allCommits = git rev-list --all
$hist = git grep -nIP $pat $allCommits
if ($LASTEXITCODE -eq 0 -and $hist) { $hist | ForEach-Object { Write-Host $_ }; Write-Host "   !! FAIL (history)" -ForegroundColor Red; $fail = $true }
else { Write-Host "   PASS: history CLEAN" -ForegroundColor Green }

# Step 4: list binary/image/office files that a text scan CANNOT read - eyeball these by hand
Write-Host "`n== 4. MANUAL REVIEW - open each of these and confirm no real names are visible =="
$bins = git ls-files | Select-String -Pattern '\.(png|jpe?g|gif|bmp|pdf|xlsx?|pptx?|docx?|pbix|pbit)$'
if ($bins) { $bins | ForEach-Object { Write-Host ("   [eye] " + $_) -ForegroundColor Cyan } }
else { Write-Host "   (no binary/image/office files found)" }

Write-Host "`n============================================"
if (-not $fail) { Write-Host " TEXT CHECKS PASS. Now eyeball the [eye] files above, then Section A is done." -ForegroundColor Green }
else { Write-Host " STOP - scrub the !! FAIL lines before going public." -ForegroundColor Red }
Write-Host "============================================"