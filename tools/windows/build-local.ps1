# SPDX-FileCopyrightText: Copyright 2026 Fritchii Project
# SPDX-License-Identifier: GPL-3.0-or-later

# Local Windows build of Fritchii (Qt app + eden-cli).
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
#   ... -BuildType RelWithDebInfo -Compiler msvc -Clean -Target yuzu-cmd

param(
    [ValidateSet("Release", "RelWithDebInfo", "Debug")]
    [string]$BuildType = "Release",

    [ValidateSet("auto", "clang-cl", "msvc")]
    [string]$Compiler = "auto",

    [string]$BuildDir = "build",

    # Build only one target, e.g. "yuzu" (Qt app) or "yuzu-cmd" (eden-cli). Empty = everything.
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
    $Compiler = if (Get-Command clang-cl -ErrorAction SilentlyContinue) { "clang-cl" } else { "msvc" }
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
if (Get-Command sccache -ErrorAction SilentlyContinue) {
    $configureArgs += @("-DCMAKE_C_COMPILER_LAUNCHER=sccache", "-DCMAKE_CXX_COMPILER_LAUNCHER=sccache")
}

Write-Host "build-local: configuring (the first run downloads dependencies and takes a while)"
& cmake @configureArgs
if ($LASTEXITCODE -ne 0) {
    Fail "configure failed. If it keeps failing, try -Clean, or delete .cache\cpm."
}

$buildArgs = @("--build", $BuildDir, "--parallel", $Jobs)
if ($Target) {
    $buildArgs += @("--target", $Target)
}
Write-Host "build-local: building with $Jobs jobs"
& cmake @buildArgs
if ($LASTEXITCODE -ne 0) {
    Fail "build failed (see the first 'error' above)."
}

$binDir = Join-Path (Resolve-Path $BuildDir) "bin"
Write-Host ""
Write-Host "build-local: done. Executables in $binDir" -ForegroundColor Green
Get-ChildItem $binDir -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  $($_.FullName)"
}
