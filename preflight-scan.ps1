# preflight-scan.ps1 — pre-publish safety scan.
# IMPORTANT: this script contains NO sensitive strings. The denylist lives in a
# local, git-ignored file (.denylist.local, one regex term per line) that you keep
# on your machine and NEVER commit. If the file is absent, the scan is skipped.
$deny = ".denylist.local"
if (-not (Test-Path $deny)) { Write-Host "No .denylist.local found — skipping denylist scan."; exit 0 }
$terms = Get-Content $deny | Where-Object { $_ -and -not $_.StartsWith('#') }
$pat   = ($terms -join '|')
$hits  = git grep -nIE $pat $(git rev-list --all) 2>$null
if ($hits) { Write-Host "DENYLIST HIT:`n$hits"; exit 1 } else { Write-Host "Clean — no denylisted terms in history."; exit 0 }
