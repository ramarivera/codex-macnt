param(
    [Parameter(Mandatory = $true)] [string] $ProjectPath,
    [Parameter(Mandatory = $true)] [string] $RunId,
    [Parameter(Mandatory = $true)] [string] $GitRef,
    [Parameter(Mandatory = $true)] [string] $DmgUrl,
    [string] $OutputDir = "/c/codex-vm-output",
    [string] $EnableLinuxUiPolish = "1",
    [bool] $SkipRustBuild = $false,
    [bool] $SkipRebuildNative = $false,
    [string] $PrebuiltCliUrl = "",
    [string] $BundledWindowsZip = ""
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Convert-ToWindowsPath {
    param([Parameter(Mandatory = $true)] [string] $Path)

    if ($Path -match '^/([a-zA-Z])/(.*)$') {
        $drive = $Matches[1].ToUpper()
        $tail = $Matches[2]
        $tail = $tail -replace '/', '\\'
        return "${drive}:\\$tail"
    }

    return $Path
}

function Write-Step {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format s)] $Message"
}

function Ensure-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is not installed. $InstallHint"
    }
}

$manifest = $null

function Ensure-Makensis {
    if (Get-Command makensis -ErrorAction SilentlyContinue) { return }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Step "makensis not found; attempting install via winget (NSIS.NSIS)"
        & winget install --id NSIS.NSIS --silent --accept-package-agreements --accept-source-agreements | Out-Null
        if (Get-Command makensis -ErrorAction SilentlyContinue) { return }
        $candidate = "C:\\Program Files (x86)\\NSIS\\makensis.exe"
        if (Test-Path $candidate) {
            $env:PATH = "$([System.IO.Path]::GetDirectoryName($candidate));$env:PATH"
            return
        }
    }

    throw "NSIS (makensis) unavailable; install NSIS and ensure makensis is on PATH."
}

$script:RceditPath = $null
function Ensure-Rcedit {
    if ($script:RceditPath -and (Test-Path $script:RceditPath)) { return $script:RceditPath }

    $dst = Join-Path $installerWorkdir 'rcedit.exe'
    if (Test-Path $dst) {
        $script:RceditPath = $dst
        return $dst
    }

    Write-Step "Fetching rcedit (for EXE icon patching)"
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/electron/rcedit/releases/latest"
        $asset = $rel.assets | Where-Object { $_.name -match 'rcedit.*x64.*\\.exe$' } | Select-Object -First 1
        if (-not $asset) {
            $asset = $rel.assets | Where-Object { ($_.name -match 'rcedit.*\\.exe$') -and ($_.name -match 'x64') } | Select-Object -First 1
        }
        if (-not $asset) {
            Write-Step "rcedit asset not found in latest release; skipping EXE icon patching"
            return $null
        }
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dst
        $script:RceditPath = $dst
        return $dst
    } catch {
        Write-Step "Failed to fetch rcedit; skipping EXE icon patching: $($_.Exception.Message)"
        return $null
    }
}

$ProjectPath = Convert-ToWindowsPath $ProjectPath
$OutputDir = Convert-ToWindowsPath $OutputDir

Write-Step "Preparing Windows Codex build in $ProjectPath"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Set-Location $ProjectPath

if (-not $SkipRustBuild) {
    Ensure-Command git "Install Git for Windows or Git via package manager."
    Ensure-Command cargo "Install rustup and toolchains with the MSVC/Windows target."
}

$env:CODEX_GIT_REF = $GitRef
$env:CODEX_DMG_URL = $DmgUrl
$env:ENABLE_LINUX_UI_POLISH = $EnableLinuxUiPolish
$env:CODEX_SKIP_RUST_BUILD = if ($SkipRustBuild) { "1" } else { "0" }
$env:CODEX_SKIP_REBUILD_NATIVE = if ($SkipRebuildNative) { "1" } else { "0" }

$installerWorkdir = Join-Path $ProjectPath '.codex-vm-windows'
New-Item -ItemType Directory -Path $installerWorkdir -Force | Out-Null
Set-Location $installerWorkdir

$zipCandidate = $BundledWindowsZip
if (-not $zipCandidate) {
    $zipCandidate = Join-Path $ProjectPath "Codex-Windows-x64.zip"
}

$useBundledZip = Test-Path $zipCandidate

if ($useBundledZip) {
    Write-Step "Using bundled Windows app zip: $zipCandidate"
    # Extract into installer workdir; zip contains top-level folder `codex-windows-x64/`.
    if (Test-Path (Join-Path $installerWorkdir "codex-windows-x64")) {
        Remove-Item (Join-Path $installerWorkdir "codex-windows-x64") -Recurse -Force -ErrorAction SilentlyContinue
    }
    Expand-Archive -Path $zipCandidate -DestinationPath $installerWorkdir -Force
} else {
    Ensure-Command node "Install Node.js before running this script."
    Ensure-Command npm "Install npm with Node.js before running this script."

    if (Test-Path Codex.dmg) {
        Write-Step "Using existing Codex.dmg"
    } else {
        Write-Step "Downloading DMG from $DmgUrl"
        Invoke-WebRequest -Uri $DmgUrl -OutFile Codex.dmg
    }

    if (-not (Test-Path Codex.img)) {
        Ensure-Command dmg2img "Install dmg2img and retry (or provide Codex-Windows-x64.zip to avoid DMG extraction)."
        Write-Step "Converting DMG with dmg2img"
        dmg2img Codex.dmg Codex.img | Out-Null
    }

    if (-not (Test-Path extracted)) {
        Ensure-Command 7z "Install 7-Zip before continuing."
        Write-Step "Extracting app.asar from DMG/IMG using 7z"
        & 7z x Codex.img -oextracted/ -y | Out-Null
    }

    $asarPath = Get-ChildItem -Path extracted -Recurse -Filter app.asar | Select-Object -First 1
    if (-not $asarPath) {
        throw "Could not locate app.asar in extracted DMG payload"
    }

    $localAsar = Join-Path $installerWorkdir 'app.asar'
    Copy-Item -Path $asarPath.FullName -Destination $localAsar -Force

    if (-not (Get-Command asar -ErrorAction SilentlyContinue)) {
        Write-Step "asar CLI missing; installing @electron/asar temporarily"
        npm install -g @electron/asar | Out-Null
    }

    if (-not (Test-Path app_unpacked)) {
        Write-Step "Extracting ASAR bundle"
        New-Item -ItemType Directory -Path app_unpacked | Out-Null
        asar extract "$localAsar" app_unpacked
    }
}

Set-Location $ProjectPath
if ((-not $SkipRustBuild) -and (Test-Path .git)) {
    git config --global --add safe.directory "$ProjectPath" | Out-Null
}

if ($SkipRustBuild) {
    if (-not $PrebuiltCliUrl) {
        throw "SkipRustBuild is enabled but PrebuiltCliUrl is empty."
    }

    $cliDownloadPath = Join-Path $installerWorkdir 'codex-prebuilt.exe'
    Write-Step "Downloading prebuilt codex.exe from $PrebuiltCliUrl"
    Invoke-WebRequest -Uri $PrebuiltCliUrl -OutFile $cliDownloadPath

    if ($useBundledZip) {
        $cliDstDir = Join-Path $installerWorkdir 'codex-windows-x64/resources'
    } else {
        $cliDstDir = Join-Path $installerWorkdir 'app_unpacked/resources'
    }
    New-Item -ItemType Directory -Path $cliDstDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cliDstDir 'bin') -Force | Out-Null
    Copy-Item $cliDownloadPath (Join-Path $cliDstDir 'codex.exe') -Force
    Copy-Item $cliDownloadPath (Join-Path $cliDstDir 'bin/codex.exe') -Force
} else {
    if (Test-Path codex-src) {
        Remove-Item codex-src -Recurse -Force
    }

    git clone https://github.com/openai/codex.git codex-src
    Set-Location codex-src

    if ($GitRef -ne 'latest-tag') {
        git fetch --depth 1 origin $GitRef
        git checkout FETCH_HEAD
    } else {
        git fetch --tags --force
        $tag = (git tag --sort=-v:refname | Select-Object -First 1)
        if (-not $tag) {
            throw "No tags found for latest-tag resolution"
        }
        git checkout $tag
    }

    Set-Location codex-rs
    Write-Step "Building codex.exe with Rust toolchain"
    cargo build --release --bin codex
    if (-not (Test-Path target/release/codex.exe)) {
        throw "codex.exe build failed"
    }

    $cliSrc = Join-Path (Get-Location) 'target/release/codex.exe'
    $cliDstDir = Join-Path $installerWorkdir 'app_unpacked/resources'
    New-Item -ItemType Directory -Path $cliDstDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $cliDstDir 'bin') -Force | Out-Null
    $cliDst = Join-Path $cliDstDir 'codex.exe'
    Copy-Item $cliSrc $cliDst -Force
    Copy-Item $cliDst (Join-Path $cliDstDir 'bin/codex.exe') -Force
}

Set-Location $installerWorkdir

# Rebuild native modules for Windows/ Electron ABI
if ((-not $SkipRebuildNative) -and (-not $useBundledZip)) {
    Ensure-Command node "Install Node.js before running this script."
    Ensure-Command npm "Install npm with Node.js before running this script."

    $packagePath = Join-Path $installerWorkdir 'app_unpacked/package.json'
    $appNodeDeps = Get-Content $packagePath -Raw | ConvertFrom-Json
    $targetElectron = ($appNodeDeps.devDependencies.electron -replace '^\\^', '')

    if ($targetElectron) {
        Write-Step "Rebuilding native modules for electron $targetElectron"

        $sqliteVer = (Get-Content (Join-Path $installerWorkdir 'app_unpacked/node_modules/better-sqlite3/package.json') -Raw | ConvertFrom-Json).version
        $ptyVer = (Get-Content (Join-Path $installerWorkdir 'app_unpacked/node_modules/node-pty/package.json') -Raw | ConvertFrom-Json).version

        $nativeBuild = Join-Path $installerWorkdir '_native_src'
        if (Test-Path $nativeBuild) { Remove-Item $nativeBuild -Recurse -Force }
        New-Item -ItemType Directory -Path $nativeBuild -Force | Out-Null

        Push-Location $nativeBuild
        npm init -y | Out-Null
        npm install "better-sqlite3@$sqliteVer" "node-pty@$ptyVer" --ignore-scripts | Out-Null
        Pop-Location

        Remove-Item app_unpacked/node_modules/better-sqlite3 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item app_unpacked/node_modules/node-pty -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item "$nativeBuild/node_modules/better-sqlite3" -Destination "$installerWorkdir/app_unpacked/node_modules" -Recurse -Force
        Copy-Item "$nativeBuild/node_modules/node-pty" -Destination "$installerWorkdir/app_unpacked/node_modules" -Recurse -Force

        npm install -g electron-rebuild | Out-Null
        & electron-rebuild --version | Out-Null
        & electron-rebuild --version-app "$targetElectron" --arch x64 --module-dir "$installerWorkdir/app_unpacked" --only better-sqlite3,node-pty --force | Out-Null
    }
} else {
    Write-Step "Skipping native module rebuild (SkipRebuildNative=true)"
}

$electronDir = Join-Path $installerWorkdir 'electron-dist'
if (-not (Test-Path $electronDir)) { New-Item -ItemType Directory -Path $electronDir | Out-Null }

$distDir = Join-Path $installerWorkdir 'codex-windows-x64'
if ($useBundledZip) {
    if (-not (Test-Path $distDir)) {
        throw "Bundled zip extraction failed; expected folder missing: $distDir"
    }
} else {
    if (Test-Path $distDir) { Remove-Item $distDir -Recurse -Force }
    Copy-Item -Recurse (Join-Path $installerWorkdir 'app_unpacked') $distDir -Force
    New-Item -ItemType Directory -Path (Join-Path $distDir 'resources/bin') -Force | Out-Null
    Copy-Item "$installerWorkdir/app_unpacked/resources/codex.exe" (Join-Path $distDir 'resources/codex.exe') -Force
    Copy-Item "$installerWorkdir/app_unpacked/resources/codex.exe" (Join-Path $distDir 'resources/bin/codex.exe') -Force
}

Ensure-Makensis

$installerDir = Join-Path $ProjectPath 'installer/windows'
$nsiTemplate = Join-Path $installerDir 'codex.nsi'
if (-not (Test-Path $nsiTemplate)) {
    throw "Windows installer template missing: $nsiTemplate"
}

Copy-Item $nsiTemplate (Join-Path $distDir 'codex.nsi') -Force

$iconArg = ''
$iconSource = Get-ChildItem $installerDir -Recurse -Filter 'codex-icon.ico' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($iconSource) {
    Copy-Item $iconSource.FullName (Join-Path $distDir 'codex-icon.ico') -Force
    $iconArg = '-DAPP_ICON=codex-icon.ico'
}

$appExe = Join-Path $distDir 'Codex.exe'
$iconInDist = Join-Path $distDir 'codex-icon.ico'
if ((Test-Path $appExe) -and (Test-Path $iconInDist)) {
    $rcedit = Ensure-Rcedit
    if ($rcedit) {
        Write-Step "Patching EXE icon: $appExe"
        & $rcedit $appExe --set-icon $iconInDist | Out-Null
    }
}

$packagePathForVer = if ($useBundledZip) { Join-Path $distDir 'package.json' } else { Join-Path $installerWorkdir 'app_unpacked/package.json' }
$appVer = (Get-Content $packagePathForVer -Raw | ConvertFrom-Json).version
$manifest = Join-Path $OutputDir "manifest.json"

Set-Location $distDir
$nsisCmd = "makensis -DAPP_VERSION=$appVer -DSOURCE_DIR=. ${iconArg} codex.nsi"
Write-Step "Running NSIS: $nsisCmd"
Invoke-Expression $nsisCmd

$installerOut = Join-Path $installerWorkdir "Codex-Setup-Windows-x64.exe"
if (Test-Path (Join-Path $distDir 'Codex-Setup-Windows-x64.exe')) {
    Move-Item (Join-Path $distDir 'Codex-Setup-Windows-x64.exe') $installerOut -Force
}

if (-not (Test-Path $installerOut)) {
    throw "Expected Windows installer was not produced: $installerOut"
}

Move-Item $installerOut (Join-Path $OutputDir 'Codex-Setup-Windows-x64.exe') -Force

$manifestObj = [ordered]@{
    run_id = $RunId
    app_version = $appVer
    git_ref = $GitRef
    dmg_url = $DmgUrl
    bundled_windows_zip = if ($useBundledZip) { $zipCandidate } else { "" }
    skip_rust_build = $SkipRustBuild
    skip_rebuild_native = $SkipRebuildNative
    prebuilt_cli_url = $PrebuiltCliUrl
    timestamp_utc = (Get-Date).ToUniversalTime().ToString("o")
}
$manifestObj | ConvertTo-Json -Depth 6 | Set-Content -Path $manifest -Encoding utf8

@"
{
  \"platform\": \"windows\",
  \"run_id\": \"$RunId\",
  \"git_ref\": \"$GitRef\",
  \"app_dmg_url\": \"$DmgUrl\",
  \"host\": \"$env:COMPUTERNAME\",
  \"artifact\": \"Codex-Setup-Windows-x64.exe\"
}
"@ | Set-Content -Path (Join-Path $OutputDir 'manifest.json') -Encoding utf8

if (Test-Path (Join-Path $OutputDir 'Codex-Setup-Windows-x64.exe')) {
    Write-Step "Windows guest build complete: $OutputDir"
    exit 0
}

throw "Windows build did not produce installer in $OutputDir"
