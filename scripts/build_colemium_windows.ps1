param(
  [int]$Jobs = [int]([Environment]::GetEnvironmentVariable('NUMBER_OF_PROCESSORS'))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Exec($cmd, $arguments){
  Write-Host "==> $cmd $arguments"
  $p = Start-Process -FilePath $cmd -ArgumentList $arguments -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "Command failed: $cmd $arguments (exit $($p.ExitCode))" }
}

Push-Location $PSScriptRoot\..
try {
  # Initialize VS environment if cl.exe is not on PATH
  if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    $vswhere = "$Env:ProgramFiles(x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
      $vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
      if ($vsPath) {
        $vsDevCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
        if (Test-Path $vsDevCmd) {
          Write-Host "==> Initializing VS environment via VsDevCmd.bat" -ForegroundColor Cyan
          & cmd /c "call `"$vsDevCmd`" -arch=amd64 && set" | ForEach-Object {
            if ($_ -match '^(.*?)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2]) }
          }
        }
      }
    }
  }

  # 1) Downloads
  New-Item -ItemType Directory -Force -Path build\download_cache | Out-Null
  Exec python "utils/downloads.py retrieve -c build/download_cache -i downloads.ini"
  # Pre-clean any partial Chromium temp dir from previous runs
  if (Test-Path build\src\chromium-*) {
    Write-Host "==> Cleaning leftover temp dir(s) under build\\src" -ForegroundColor Yellow
    Get-ChildItem build\src -Directory -Name | Where-Object { $_ -like 'chromium-*' } | ForEach-Object {
      Remove-Item -Recurse -Force (Join-Path 'build\src' $_) -ErrorAction SilentlyContinue
    }
  }
  # Prefer 7-Zip if installed (registry or default location), otherwise fall back to Python extractor
  $sevenZip = ""
  try {
    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\7zFM.exe'
    $sevenZipDir = (Get-ItemProperty -Path $reg -ErrorAction Stop).Path
    if ($sevenZipDir) { $candidate = Join-Path $sevenZipDir '7z.exe'; if (Test-Path $candidate) { $sevenZip = $candidate } }
  } catch {}
  if (-not $sevenZip) { $candidate = 'C:\Program Files\7-Zip\7z.exe'; if (Test-Path $candidate) { $sevenZip = $candidate } }

  if ($sevenZip) {
    Write-Host "==> Using 7-Zip at: $sevenZip" -ForegroundColor Cyan
    Exec python "utils/downloads.py unpack   -c build/download_cache -i downloads.ini --7z-path `"$sevenZip`" -- build/src"
  } else {
    Write-Host "==> 7-Zip not found; falling back to Python extractor (symlinks may be slower)" -ForegroundColor Yellow
    Exec python "utils/downloads.py unpack   -c build/download_cache -i downloads.ini -- build/src"
  }

  # 2) Prune binaries
  Exec python "utils/prune_binaries.py build/src pruning.list"

  # 3) Apply patches
  Exec python "utils/patches.py apply build/src patches"

  # 4) Domain substitution
  Exec python "utils/domain_substitution.py apply -r domain_regex.list -f domain_substitution.list -c build/domsubcache.tar.gz build/src"

  # 5) Build GN bootstrap
  New-Item -ItemType Directory -Force -Path build\src\out\Default | Out-Null
  Push-Location build\src
  try {
    Exec python "tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles -j$Jobs -o out/Default/"

    # 6) GN gen
    Copy-Item -Force ..\..\flags.gn out\Default\args.gn
    Exec .\out\Default\gn "gen out/Default --fail-on-unused-args"

    # 7) Build
    Exec ninja "-C out/Default chrome"
  } finally { Pop-Location }

  Write-Host "\nBuild complete. Binary at: build\\src\\out\\Default\\chrome.exe" -ForegroundColor Green
} finally {
  Pop-Location
}


