<#
.SYNOPSIS
  Provisions a fresh Windows Server 2022 VM as a GitLab CI runner capable of
  building the Mullvad VPN desktop app (Windows installer).

  This installs only the slice of GitHub's `windows-latest` image that the
  build actually needs, mirroring Mullvad's `mullvad-build-env` action:
  VS 2022 Build Tools (C++ + Windows SDK), Rust 1.95.0 + i686 target, Go,
  Perl, protoc, Volta/node, Git (long paths), and the GitLab runner itself.

.DESCRIPTION
  Run in an ELEVATED PowerShell ("Run as Administrator") on a clean VM.
  Takes roughly 30 minutes, almost all of it the VS Build Tools install.
  A reboot at the end is recommended so the runner service picks up the
  machine-wide PATH/env changes.

.PARAMETER GitLabUrl
  Base URL of your GitLab instance, e.g. https://git.agiri.ninja

.PARAMETER RunnerToken
  Runner authentication token. In recent GitLab: create the runner under
  Project -> Settings -> CI/CD -> Runners -> "New project runner" (give it the
  tag `windows`), then copy the token it shows (starts with `glrt-`).

.PARAMETER RunnerTag
  Tag the runner registers with. Must match the `tags:` of the build-windows
  job in .gitlab-ci.yml (default `windows`).

.EXAMPLE
  .\provision-windows-runner.ps1 -GitLabUrl https://git.agiri.ninja -RunnerToken glrt-xxxxxxxx
#>
param(
    [Parameter(Mandatory = $true)] [string] $GitLabUrl,
    [Parameter(Mandatory = $true)] [string] $RunnerToken,
    [string] $RunnerTag = "windows"
)

$ErrorActionPreference = "Stop"
Set-ExecutionPolicy Bypass -Scope Process -Force

# machine-wide tool locations so the runner service (which may run as a
# different account than your interactive RDP user) can find rust/volta.
$RustHome  = "C:\rust"
$VoltaHome = "C:\volta"

function Add-MachinePath([string] $dir) {
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($current -notlike "*$dir*") {
        [Environment]::SetEnvironmentVariable("Path", "$current;$dir", "Machine")
    }
    $env:Path += ";$dir"
}

Write-Host "==> Installing Chocolatey"
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    [System.Net.ServicePointManager]::SecurityProtocol = 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    Add-MachinePath "C:\ProgramData\chocolatey\bin"
}

Write-Host "==> Installing base tools (git, go, perl, protoc)"
choco install -y --no-progress git golang strawberryperl protoc

# git on windows caps filenames at 260 chars by default; the build tree exceeds it.
git config --system core.longpaths true
# bash.exe (git-bash) lives here; .gitlab-ci.yml invokes the build via `bash -c`.
Add-MachinePath "C:\Program Files\Git\bin"

Write-Host "==> Installing Visual Studio 2022 Build Tools (C++ workload + Windows SDK)"
# the vctools workload pulls MSVC x64/x86 plus a recommended Windows SDK, which
# is what the winfw and nsis-plugins C++ projects need to build via msbuild.
choco install -y --no-progress visualstudio2022buildtools
choco install -y --no-progress visualstudio2022-workload-vctools

Write-Host "==> Installing Rust 1.95.0 (machine-wide) + i686 target"
$env:CARGO_HOME  = "$RustHome\cargo"
$env:RUSTUP_HOME = "$RustHome\rustup"
[Environment]::SetEnvironmentVariable("CARGO_HOME",  $env:CARGO_HOME,  "Machine")
[Environment]::SetEnvironmentVariable("RUSTUP_HOME", $env:RUSTUP_HOME, "Machine")
$rustupInit = "$env:TEMP\rustup-init.exe"
Invoke-WebRequest "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe" -OutFile $rustupInit
& $rustupInit -y --default-toolchain 1.95.0 --profile minimal
Add-MachinePath "$RustHome\cargo\bin"
& "$RustHome\cargo\bin\rustup.exe" component add clippy
# 32-bit target is required to build the NSIS plugins.
& "$RustHome\cargo\bin\rustup.exe" target add i686-pc-windows-msvc

Write-Host "==> Installing Volta + pinned node/npm"
$env:VOLTA_HOME = $VoltaHome
[Environment]::SetEnvironmentVariable("VOLTA_HOME", $VoltaHome, "Machine")
choco install -y --no-progress volta
Add-MachinePath "$VoltaHome\bin"
# versions match desktop/package.json; Volta will also auto-select these in-repo.
& "$VoltaHome\bin\volta.exe" install node@24.15.0 npm@11.12.1

Write-Host "==> Installing GitLab Runner"
$runnerDir = "C:\GitLab-Runner"
$runnerExe = "$runnerDir\gitlab-runner.exe"
New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null
Invoke-WebRequest "https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-windows-amd64.exe" -OutFile $runnerExe
Add-MachinePath $runnerDir

Write-Host "==> Registering runner with $GitLabUrl (tag: $RunnerTag)"
& $runnerExe register `
    --non-interactive `
    --url $GitLabUrl `
    --token $RunnerToken `
    --executor shell `
    --shell powershell `
    --description "windows-mullvad-build"

Write-Host "==> Installing runner as a Windows service"
# runs as Built-in System by default; all tools above are installed machine-wide
# so the service account can see them after a reboot.
& $runnerExe install
& $runnerExe start

Write-Host ""
Write-Host "Provisioning complete. Reboot so the runner service picks up the new PATH:"
Write-Host "    Restart-Computer"
Write-Host "After reboot, confirm with:  gitlab-runner status"
