# SPDX-FileCopyrightText: Copyright 2026 Fritchii Project
# SPDX-License-Identifier: GPL-3.0-or-later

# Local Windows build of Fritchii (fritchii.exe and the small lichii.exe forwarder).
#
# Requirements (one-time):
#   - Visual Studio 2022 or newer with "Desktop development with C++"
#     (for -Compiler clang-cl also "C++ Clang tools for Windows")
#   - Git for Windows
#   - Vulkan SDK (run tools/windows/install-vulkan-sdk.ps1 as administrator)
# Qt, SDL3, FFmpeg, Boost etc. are downloaded automatically by CMake on the first configure.
#
# Usage (from any PowerShell):
#   powershell -ExecutionPolicy Bypass -File tools\windows\build-local.ps1
#   ... -BuildType RelWithDebInfo -Compiler msvc -Clean -Target yuzu

param(
    [ValidateSet("Release", "RelWithDebInfo", "Debug")]
    [string]$BuildType = "Release",

    [ValidateSet("auto", "clang-cl", "msvc")]
    [string]$Compiler = "auto",

    [string]$BuildDir = "build",

    # Build only one target, e.g. "yuzu" (fritchii.exe). Empty = everything.
    [string]$Target = "",

    [int]$Jobs = [Environment]::ProcessorCount,

    # Delete the build directory first (needed after switching compiler).
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
Set-Location $RepoRoot

function Fail($message) {
    Write-Host "build-local: $message" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "git not found. Install Git for Windows: https://gitforwindows.org"
}

# Vulkan SDK
if (-not $env:VULKAN_SDK -or -not (Test-Path $env:VULKAN_SDK)) {
    $sdk = Get-ChildItem "C:\VulkanSDK" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($sdk) {
        $env:VULKAN_SDK = $sdk.FullName
    } else {
        Fail "Vulkan SDK not found. Run tools\windows\install-vulkan-sdk.ps1 as administrator, then open a new terminal."
    }
}
Write-Host "build-local: Vulkan SDK: $env:VULKAN_SDK"

# The shader compiler ships in the SDK's Bin folder, which isn't on PATH until a new login.
$vulkanBin = Join-Path $env:VULKAN_SDK "Bin"
if (-not (Get-Command glslangValidator -ErrorAction SilentlyContinue)) {
    $env:PATH = "$vulkanBin;$env:PATH"
}
if (-not (Get-Command glslangValidator -ErrorAction SilentlyContinue)) {
    Fail "glslangValidator.exe not found in $vulkanBin. Reinstall the Vulkan SDK (tools\windows\install-vulkan-sdk.ps1)."
}

# Visual Studio environment (puts cl/clang-cl, and VS's bundled cmake + ninja on PATH)
if (-not $env:VCINSTALLDIR) {
    & "$PSScriptRoot\load-msvc-env.ps1"
    if (-not $env:VCINSTALLDIR) {
        Fail "Could not load the Visual Studio environment."
    }
}

foreach ($tool in @("cmake", "ninja")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "$tool not found. Install the 'C++ CMake tools for Windows' component in the Visual Studio Installer."
    }
}

if ($Compiler -eq "auto") {
    if (-not (Get-Command clang-cl -ErrorAction SilentlyContinue)) {
        Fail ("clang-cl not found. Fritchii releases are built with clang-cl; plain MSVC turns some " +
              "warnings into errors that upstream code doesn't avoid. Add the 'C++ Clang tools for " +
              "Windows' component (Microsoft.VisualStudio.Component.VC.Llvm.Clang) in the Visual " +
              "Studio Installer, or pass -Compiler msvc to try MSVC anyway.")
    }
    $Compiler = "clang-cl"
}
if ($Compiler -eq "clang-cl") {
    if (-not (Get-Command clang-cl -ErrorAction SilentlyContinue)) {
        Fail "clang-cl not found. Install 'C++ Clang tools for Windows' or use -Compiler msvc."
    }
    $cc = "clang-cl"
} else {
    $cc = "cl"
}
Write-Host "build-local: compiler: $Compiler, build type: $BuildType, dir: $BuildDir"

if ($Clean -and (Test-Path $BuildDir)) {
    Write-Host "build-local: removing $BuildDir"
    Remove-Item -Recurse -Force $BuildDir
}

# Switching compiler inside an existing build dir doesn't work; tell the user instead of failing later.
$cache = Join-Path $BuildDir "CMakeCache.txt"
if (Test-Path $cache) {
    $cached = Select-String -Path $cache -Pattern "^CMAKE_CXX_COMPILER:\w+=(.*)$" | Select-Object -First 1
    $cachedName = if ($cached) { [IO.Path]::GetFileNameWithoutExtension($cached.Matches[0].Groups[1].Value) }
    if ($cachedName -and ($cachedName -ne $cc)) {
        Fail "$BuildDir was configured with a different compiler. Re-run with -Clean."
    }
}

$configureArgs = @(
    "-S", ".", "-B", $BuildDir, "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=$BuildType",
    "-DCMAKE_C_COMPILER=$cc",
    "-DCMAKE_CXX_COMPILER=$cc",
    "-DYUZU_TESTS=OFF",
    "-DENABLE_WERROR=OFF",
    "-DENABLE_QT_TRANSLATION=OFF"
)
if ($Compiler -eq "clang-cl") {
    # With ENABLE_WERROR off the project passes -Wall, which clang-cl treats as -Weverything:
    # hundreds of warnings per file make the build much slower. /w silences warnings (errors stay).
    $configureArgs += @(
        "-DCMAKE_C_FLAGS=/DWIN32 /D_WINDOWS /w",
        "-DCMAKE_CXX_FLAGS=/DWIN32 /D_WINDOWS /EHsc /w"
    )
}
if (Get-Command sccache -ErrorAction SilentlyContinue) {
    $configureArgs += @("-DCMAKE_C_COMPILER_LAUNCHER=sccache", "-DCMAKE_CXX_COMPILER_LAUNCHER=sccache")
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
$configureLog = Join-Path (Resolve-Path $BuildDir) "configure.log"
$logFile = Join-Path (Resolve-Path $BuildDir) "build-local.log"
$errorPattern = "FAILED:|error:|error C\d+|error LNK|fatal error|undefined symbol|CMake Error"

$lineWidth = 100
try { $lineWidth = [Math]::Max(40, $Host.UI.RawUI.WindowSize.Width - 1) } catch {}

# Runs a command, writes everything to $Log and shows only ninja's [n/total] progress on one line
# plus error lines. Native stderr becomes error records in Windows PowerShell, so the output is
# turned into plain strings and the error preference relaxed while it runs.
function Invoke-Quiet([string[]]$Arguments, [string]$Log) {
    $ErrorActionPreference = "Continue"
    & cmake @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $Log | ForEach-Object {
        if ($_ -match '^\[(\d+)/(\d+)\]\s*(.*)$') {
            $text = "[$($matches[1])/$($matches[2])] $($matches[3])"
            if ($text.Length -gt $lineWidth) { $text = $text.Substring(0, $lineWidth) }
            Write-Host -NoNewline ("`r" + $text.PadRight($lineWidth))
        } elseif ($_ -match $errorPattern) {
            Write-Host ""
            Write-Host $_ -ForegroundColor Red
        }
    }
    $code = $LASTEXITCODE
    Write-Host ""
    return $code
}

function Show-Errors([string]$Log) {
    Write-Host "build-local: errors (first 30 lines):" -ForegroundColor Red
    Select-String -Path $Log -Pattern $errorPattern | Select-Object -First 30 |
        ForEach-Object { Write-Host "  $($_.Line)" }
}

Write-Host "build-local: configuring (the first run downloads dependencies and takes a while)"
if ((Invoke-Quiet $configureArgs $configureLog) -ne 0) {
    Show-Errors $configureLog
    Fail "configure failed. Full output: $configureLog. If it keeps failing, try -Clean, or delete .cache\cpm."
}

$buildArgs = @("--build", $BuildDir, "--parallel", $Jobs)
if ($Target) {
    $buildArgs += @("--target", $Target)
}
Write-Host "build-local: building with $Jobs jobs (full output in $logFile)"
if ((Invoke-Quiet $buildArgs $logFile) -ne 0) {
    Show-Errors $logFile
    Fail "build failed. Full output: $logFile"
}

$binDir = Join-Path (Resolve-Path $BuildDir) "bin"
Write-Host ""
Write-Host "build-local: done. Executables in $binDir" -ForegroundColor Green
Get-ChildItem $binDir -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  $($_.FullName)"
}
