$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$Message) {
  Write-Host ("[{0}] {1}" -f (Get-Date -Format s), $Message)
}

function Ensure-Winget {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget not found (Windows App Installer missing)"
  }
}

function Winget-Install([string]$Id, [string]$Override) {
  Write-Step ("winget install {0}" -f $Id)
  $args = @(
    'install', '--id', $Id, '--exact', '--silent',
    '--accept-package-agreements', '--accept-source-agreements'
  )
  if ($Override -and $Override.Trim().Length -gt 0) {
    $args += @('--override', $Override)
  }
  & winget @args
  $rc = $LASTEXITCODE
  Write-Step ("{0} exit={1}" -f $Id, $rc)
  return $rc
}

function Ensure-RustupAvailable {
  $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
  if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }

  if (Get-Command rustup -ErrorAction SilentlyContinue) { return }

  Write-Step "rustup not found; trying winget Rustlang.Rustup"
  $rc = Winget-Install 'Rustlang.Rustup' ''
  if ($rc -eq 0) {
    if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }
    if (Get-Command rustup -ErrorAction SilentlyContinue) { return }
  }

  Write-Step "winget rustup failed or not on PATH; falling back to rustup-init download"
  $tmp = Join-Path $env:TEMP 'rustup-init.exe'
  Invoke-WebRequest -Uri 'https://win.rustup.rs/x86_64' -OutFile $tmp
  & $tmp -y | Out-Null

  if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }
  if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    throw "rustup still not available after install"
  }
}

Ensure-Winget

Write-Step "Installing Windows dependencies for building codex CLI (Rust + MSVC)"

# Visual Studio Build Tools (MSVC) - requires elevation; if it fails, you'll need to run this script in an elevated shell.
$vsOverride = '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
$rcVs = Winget-Install 'Microsoft.VisualStudio.2022.BuildTools' $vsOverride
if ($rcVs -ne 0) {
  Write-Step "WARN: VS Build Tools install failed. cl.exe/link.exe may be missing; run this script in an elevated PowerShell."
}

Winget-Install 'Git.Git' '' | Out-Null
Winget-Install 'Kitware.CMake' '' | Out-Null
Winget-Install 'Ninja-build.Ninja' '' | Out-Null
Winget-Install 'NASM.NASM' '' | Out-Null
Winget-Install 'StrawberryPerl.StrawberryPerl' '' | Out-Null

Ensure-RustupAvailable

Write-Step "Configuring rustup toolchain: stable-x86_64-pc-windows-msvc"
& rustup set profile minimal | Out-Null
& rustup toolchain install stable-x86_64-pc-windows-msvc | Out-Null
& rustup default stable-x86_64-pc-windows-msvc | Out-Null

Write-Step ("rustup=" + (& rustup --version))
Write-Step ("cargo=" + (& cargo --version))
Write-Step ("rustc=" + (& rustc --version))

# Validate MSVC toolchain discovery (best-effort)
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
  $inst = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($inst) {
    $devcmd = Join-Path $inst 'Common7\Tools\VsDevCmd.bat'
    if (Test-Path $devcmd) {
      Write-Step ("VsDevCmd=" + $devcmd)
      cmd.exe /c "`"$devcmd`" -no_logo -arch=amd64 -host_arch=amd64 && where cl && where link" | Out-Host
    } else {
      Write-Step ("WARN: VsDevCmd.bat not found: " + $devcmd)
    }
  } else {
    Write-Step "WARN: vswhere found no VC tools install"
  }
} else {
  Write-Step "WARN: vswhere.exe not found (VS Build Tools likely missing)"
}

Write-Step "DONE"

