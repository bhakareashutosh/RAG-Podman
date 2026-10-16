<#
.SYNOPSIS
    Interactive & Animated Runner for Google ADK + RAG + Podman Workshop (Windows Launcher).
.DESCRIPTION
    Launches the interactive TUI console dashboard with animated spinners, status cards,
    typewriter chat interface, and automated Gemini API key configuration.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

# Set UTF-8 console output
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

# Path translation to WSL mount
$drive = $ScriptDir.Substring(0, 1).ToLower()
$subPath = $ScriptDir.Substring(2).Replace('\', '/')
$wslPath = "/mnt/$drive$subPath"

$shScript = "$wslPath/run.sh"
if (-not (Test-Path (Join-Path $ScriptDir "run.sh")) -and (Test-Path (Join-Path $ScriptDir "adk-rag-podman\run.sh"))) {
    $shScript = "$wslPath/adk-rag-podman/run.sh"
}

# Check WSL
$HasWsl = [bool](Get-Command "wsl.exe" -ErrorAction SilentlyContinue)

if ($HasWsl) {
    # Ensure LF line endings and executable bit
    wsl.exe -d Ubuntu -e bash -c "sed -i 's/\r$//' '$shScript' 2>/dev/null; chmod +x '$shScript' 2>/dev/null"

    # Forward environment variable if set in Windows
    $envPrefix = ""
    if ($env:GOOGLE_API_KEY) {
        $envPrefix = "export GOOGLE_API_KEY='$($env:GOOGLE_API_KEY)'; "
    }

    if ($ScriptArgs -and $ScriptArgs.Count -gt 0) {
        $escapedArgs = ($ScriptArgs | ForEach-Object { "'$_'" }) -join " "
        wsl.exe -d Ubuntu -e bash -c "$envPrefix '$shScript' $escapedArgs"
    } else {
        # Launch interactive menu in WSL
        wsl.exe -d Ubuntu -e bash -c "$envPrefix '$shScript'"
    }
} else {
    Write-Host "[ERROR] WSL2 is required to run rootless Podman on Windows." -ForegroundColor Red
    Write-Host "Please install WSL2 Ubuntu or Podman Desktop." -ForegroundColor Yellow
    exit 1
}
