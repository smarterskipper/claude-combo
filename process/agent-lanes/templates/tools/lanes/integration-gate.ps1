# Integration gate (PowerShell 7+): same contract as integration-gate.sh. Run: $env:LANE_PORT=5301; pwsh tools/lanes/integration-gate.ps1 <worktree>   (exit 0 pass, 1 fail, 2 refused)
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false   # native exit codes are checked explicitly below
Set-Location $Root

# ===== STACK: fill in once (section 8) =====
$BaseBranch    = if ($env:BASE_BRANCH) { $env:BASE_BRANCH } else { 'integration' }
$Compile       = { dotnet build -c Release -warnaserror -nodeReuse:false }
$Build         = { dotnet publish src/Api/Api.csproj -c Release -o tools/lanes/out/publish --no-restore }
$BaselineDir   = 'tools/lanes/baseline'
$TrackedOutput = @()        # tracked folders the checks regenerate
$Leftovers     = '\.received\.|-actual\.png$|-diff\.png$'
function Get-Checks {       # returns @{ Name; Cmd } entries
  Get-ChildItem -Recurse -Filter '*Tests.csproj' | Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | ForEach-Object {
    $p = $_.FullName; $n = $_.BaseName
    @{ Name = "test-$n"; Cmd = [scriptblock]::Create("dotnet test `"$p`" -c Release --no-build --logger `"trx;LogFileName=$n.trx`" --results-directory `"$Out/tests`"") }
  }
}
function Invoke-Teardown { dotnet build-server shutdown | Out-Null }
# ===== end STACK =====

function Test-GitPath($p) { Test-Path (git rev-parse --git-path $p) }
if ((Test-GitPath 'rebase-merge') -or (Test-GitPath 'rebase-apply') -or (Test-GitPath 'MERGE_HEAD') -or (Test-GitPath 'CHERRY_PICK_HEAD') -or (git diff --name-only --diff-filter=U)) {
  Write-Host "GATE REFUSED: a rebase, merge or cherry-pick is in progress in $Root"; exit 2
}
$markers = git grep --untracked -lE '^(<<<<<<<|>>>>>>>)( |$)' -- .
if ($markers) { Write-Host "GATE REFUSED: conflict markers in: $($markers | Select-Object -First 5)"; exit 2 }
if ($env:REQUIRE_BASE) { git merge-base --is-ancestor $env:REQUIRE_BASE HEAD; if ($LASTEXITCODE -ne 0) { Write-Host "GATE REFUSED: HEAD does not contain $($env:REQUIRE_BASE)"; exit 2 } }

$portOverride = $env:LANE_PORT
if (Test-Path .lane.env) { foreach ($line in Get-Content .lane.env) { if ($line -match '^\s*([A-Za-z_]+)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] } } }
if ($portOverride) { $env:LANE_PORT = $portOverride }
if (-not $env:LANE_PORT) { Write-Host 'GATE REFUSED: LANE_PORT is not set'; exit 2 }
$env:CI = '1'; $env:DiffEngine_Disabled = 'true'

$Out = Join-Path $Root 'tools/lanes/out/integration'
Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Out | Out-Null
$script:fail = 0
function Invoke-Check([string]$Name, [scriptblock]$Cmd) {
  $log = Join-Path $Out "$Name.log"
  $global:LASTEXITCODE = 0
  try { & $Cmd *> $log; $ok = ($LASTEXITCODE -eq 0) } catch { "$_" | Out-File -Append $log; $ok = $false }
  if ($ok) { "pass  $Name" | Tee-Object -Append (Join-Path $Out 'summary.txt') }
  else { "FAIL  $Name" | Tee-Object -Append (Join-Path $Out 'summary.txt'); Get-Content $log -Tail 15 | ForEach-Object { "      $_" }; $script:fail = 1 }
}
function Get-TreeState { ((git status --porcelain --untracked-files=no) -join "`n") + "`n" + (git diff | git hash-object --stdin) }
function Get-Untracked { @(git status --porcelain --untracked-files=all | Where-Object { $_ -like '`?`?*' }) }

try {
  $before = Get-TreeState; $untrackedBefore = Get-Untracked
  $patch = Join-Path $Out 'tracked-output-start.patch'
  if ($TrackedOutput) { git diff --binary --output=$patch -- @TrackedOutput }

  Invoke-Check compile $Compile
  foreach ($c in Get-Checks) { Invoke-Check $c.Name $c.Cmd }
  Invoke-Check baseline { $env:BASELINE_OUT = "$Out/baseline"; pwsh tools/lanes/capture-baseline.ps1 }
  Invoke-Check baseline-diff { git diff --no-index --exit-code -- $BaselineDir "$Out/baseline" }
  Invoke-Check build $Build
  Invoke-Check no-leftovers { $l = git status --porcelain --untracked-files=all | Select-String $Leftovers; if ($l) { $l; $global:LASTEXITCODE = 1 } }

  if ($TrackedOutput) {
    git checkout -- @TrackedOutput 2>$null
    if ((Test-Path $patch) -and (Get-Item $patch).Length -gt 0) { git apply --binary $patch }
  }
  if ((Get-TreeState) -ne $before) { git status --short > (Join-Path $Out 'tree-after.txt'); 'FAIL  tree changed by the gate'; $script:fail = 1 }
  $new = Get-Untracked | Where-Object { $_ -notin $untrackedBefore }
  if ($new) { 'FAIL  the gate left untracked files (gitignore their folder):'; $new | ForEach-Object { "      $_" }; $script:fail = 1 }
} finally { Invoke-Teardown }

if ($script:fail -eq 0) { 'GATE PASS' } else { 'GATE FAIL' }
exit $script:fail
