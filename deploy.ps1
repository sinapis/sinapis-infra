#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys sinapis-infra and diamond-inventory to the production server.

.DESCRIPTION
    1. Syncs source files to root@139.162.158.200 via rsync/scp.
    2. Rebuilds and restarts Docker containers in the correct order:
       - diamond-inventory (app + frontend build)
       - sinapis-infra     (nginx + mariadb)
    3. Smoke-tests that the site is reachable and the API responds.

.PARAMETER SkipSync
    Skip the file-sync phase (useful when only restarting containers).

.PARAMETER AppOnly
    Only deploy diamond-inventory (skip sinapis-infra restart).

.PARAMETER InfraOnly
    Only restart sinapis-infra (skip diamond-inventory rebuild).

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -SkipSync
    .\deploy.ps1 -AppOnly
#>

param(
    [switch]$SkipSync,
    [switch]$AppOnly,
    [switch]$InfraOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
$RemoteHost = "root@139.162.158.200"
$RemoteRoot = "/root"
# Script now lives in sinapis-infra\ – parent is the multi-app root
$LocalRoot = Split-Path $PSScriptRoot -Parent

$AppDir   = "diamond-inventory"     # relative to LocalRoot / RemoteRoot
$InfraDir = "sinapis-infra"         # relative to LocalRoot / RemoteRoot

$HealthUrl = "https://diamond.sinapistech.com"
$ApiUrl = "https://diamond.sinapistech.com/api/filters"

# ─────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────
function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "━━━ $msg" -ForegroundColor Cyan
}

function Write-OK([string]$msg) { Write-Host "  ✔  $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "  ·  $msg" -ForegroundColor Gray }
function Write-Fail([string]$msg) { Write-Host "  ✖  $msg" -ForegroundColor Red }

function Invoke-SSH([string]$command) {
    Write-Info "ssh $RemoteHost `"$command`""
    $result = ssh $RemoteHost $command
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "SSH command failed (exit $LASTEXITCODE)"
        throw "SSH command failed: $command"
    }
    return $result
}

function Send-ZipBundle {
    param(
        [string[]]$LocalPaths,   # absolute paths of items to include
        [string]  $RemoteDir,    # remote destination directory
        [string]  $Label         # used for logging and temp file name
    )

    $existing = $LocalPaths | Where-Object { Test-Path $_ }
    if (-not $existing) {
        Write-Info "Nothing to sync for $Label"
        return
    }

    $stamp   = Get-Date -Format 'yyyyMMddHHmmss'
    $zipFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$Label-$stamp.zip")
    try {
        Write-Info "Compressing $Label..."
        Compress-Archive -Path $existing -DestinationPath $zipFile -Force
        $sizekb = [Math]::Round((Get-Item $zipFile).Length / 1KB, 1)

        $remoteZip = "$RemoteDir/deploy-tmp-$stamp.zip"
        Write-Info "Uploading archive ($sizekb KB) → $RemoteHost`:$remoteZip"
        scp $zipFile "${RemoteHost}:${remoteZip}"
        if ($LASTEXITCODE -ne 0) { throw "scp of zip failed for $Label" }

        Write-Info "Extracting on remote..."
        Invoke-SSH "mkdir -p $RemoteDir && unzip -o $remoteZip -d $RemoteDir && rm -f $remoteZip" | Out-Null
    }
    finally {
        if (Test-Path $zipFile) { Remove-Item -Force $zipFile }
    }
}

function Test-HttpEndpoint([string]$url, [int]$timeoutSec = 30, [int]$statusCode = 200) {
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing `
            -TimeoutSec $timeoutSec `
            -SkipCertificateCheck `
            -Method GET
        return $resp.StatusCode -eq $statusCode
    }
    catch {
        return $false
    }
}

# ─────────────────────────────────────────────
# Pre-flight: verify ssh connectivity
# ─────────────────────────────────────────────
Write-Step "Pre-flight: checking SSH connectivity"
try {
    Invoke-SSH "echo ok" | Out-Null
    Write-OK "SSH connection established"
}
catch {
    Write-Fail "Cannot reach $RemoteHost via SSH. Ensure your SSH key is loaded."
    exit 1
}

# ─────────────────────────────────────────────
# PHASE 1 – Sync source files
# ─────────────────────────────────────────────
if (-not $SkipSync) {

    if (-not $InfraOnly) {
        Write-Step "Syncing diamond-inventory source files"

        $localApp  = Join-Path $LocalRoot $AppDir
        $remoteApp = "$RemoteRoot/$AppDir"

        $appPaths = @("backend", "frontend", "docker", "Dockerfile", "docker-compose.yml", "package.json", ".dockerignore") |
            ForEach-Object { Join-Path $localApp $_ }

        # Include .env if present locally (never committed to git)
        $envFile = Join-Path $localApp ".env"
        if (Test-Path $envFile) { $appPaths += $envFile }
        else { Write-Info ".env not found locally – assuming it already exists on server" }

        Send-ZipBundle -LocalPaths $appPaths -RemoteDir $remoteApp -Label "diamond-inventory"
        Write-OK "diamond-inventory files synced"
    }

    if (-not $AppOnly) {
        Write-Step "Syncing sinapis-infra source files"

        $localInfra  = Join-Path $LocalRoot $InfraDir
        $remoteInfra = "$RemoteRoot/$InfraDir"

        $infraPaths = @("nginx", "docker-compose.yml") |
            ForEach-Object { Join-Path $localInfra $_ }

        $infraEnv = Join-Path $localInfra ".env"
        if (Test-Path $infraEnv) { $infraPaths += $infraEnv }

        Send-ZipBundle -LocalPaths $infraPaths -RemoteDir $remoteInfra -Label "sinapis-infra"
        Write-OK "sinapis-infra files synced"
    }
}
else {
    Write-Info "Skipping file sync (--SkipSync)"
}

# ─────────────────────────────────────────────
# PHASE 2 – Deploy diamond-inventory
# ─────────────────────────────────────────────
if (-not $InfraOnly) {
    Write-Step "Deploying diamond-inventory"

    $appRemote = "$RemoteRoot/$AppDir"

    # Stop nginx first so it releases the shared volume
    Write-Info "Temporarily stopping sinapis-infra nginx..."
    Invoke-SSH "cd $RemoteRoot/$InfraDir && docker-compose rm -sf nginx 2>/dev/null || true" | Out-Null

    # Bring down the app stack
    Write-Info "Stopping old diamond-inventory containers..."
    Invoke-SSH "cd $appRemote && docker-compose down" | Out-Null

    # Remove stale frontend volume so the new build is picked up
    Write-Info "Removing stale frontend_dist volume..."
    Invoke-SSH "docker volume rm diamond-inventory_frontend_dist 2>/dev/null || true" | Out-Null

    # Purge any leftover node_modules from the server working tree.
    # Without this they bloat the Docker build context and corrupt exec bits
    # on vite/node binaries (Windows zip strips Linux execute permissions).
    # .dockerignore prevents this going forward, but we clean up defensively.
    Write-Info "Purging stale node_modules from server working tree..."
    Invoke-SSH "rm -rf $appRemote/frontend/node_modules $appRemote/backend/node_modules" | Out-Null

    # Rebuild and start (no-cache ensures fresh frontend bundle)
    Write-Info "Rebuilding and starting diamond-inventory (this may take a few minutes)..."
    Invoke-SSH "cd $appRemote && docker-compose build --no-cache && docker-compose up -d"

    Write-OK "diamond-inventory deployed"
}

# ─────────────────────────────────────────────
# PHASE 3 – Restart sinapis-infra (nginx + mariadb)
# ─────────────────────────────────────────────
if (-not $AppOnly) {
    Write-Step "Restarting sinapis-infra"

    $infraRemote = "$RemoteRoot/$InfraDir"
    # Cannot use 'down' here: it tries to remove the shared web-network while
    # diamond-app is still attached, which fails. 'rm -sf' stops + removes only
    # the containers (leaving networks/volumes intact), then 'up -d' does a clean
    # create (not recreate), which also avoids the ContainerConfig bug in
    # docker-compose 1.29.2 + newer Docker Engine.
    Invoke-SSH "cd $infraRemote && docker-compose rm -sf && docker-compose up -d"

    Write-OK "sinapis-infra started"
}

# ─────────────────────────────────────────────
# PHASE 4 – Health checks
# ─────────────────────────────────────────────
Write-Step "Running health checks"

# Give containers a moment to fully start
Write-Info "Waiting 8 seconds for containers to initialize..."
Start-Sleep -Seconds 8

# Check 1: Frontend (HTTPS)
$maxRetries = 5
$retryDelay = 6   # seconds

Write-Info "Testing frontend: $HealthUrl"
$frontendOk = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    if (Test-HttpEndpoint $HealthUrl) {
        $frontendOk = $true
        break
    }
    Write-Info "  Attempt $i/$maxRetries failed – retrying in ${retryDelay}s..."
    Start-Sleep -Seconds $retryDelay
}

if ($frontendOk) {
    Write-OK "Frontend is UP: $HealthUrl"
}
else {
    Write-Fail "Frontend did NOT respond at $HealthUrl after $maxRetries attempts"
}

# Check 2: API endpoint
Write-Info "Testing API: $ApiUrl"
$apiOk = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    if (Test-HttpEndpoint $ApiUrl) {
        $apiOk = $true
        break
    }
    Write-Info "  Attempt $i/$maxRetries failed – retrying in ${retryDelay}s..."
    Start-Sleep -Seconds $retryDelay
}

if ($apiOk) {
    Write-OK "API is UP: $ApiUrl"
}
else {
    Write-Fail "API did NOT respond at $ApiUrl after $maxRetries attempts"
}

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
if ($frontendOk -and $apiOk) {
    Write-Host "  DEPLOYMENT SUCCESSFUL ✔" -ForegroundColor Green
    Write-Host "  $HealthUrl" -ForegroundColor Green
}
elseif ($frontendOk -or $apiOk) {
    Write-Host "  DEPLOYMENT PARTIAL ⚠" -ForegroundColor Yellow
    Write-Host "  Check the failing endpoint above." -ForegroundColor Yellow
}
else {
    Write-Host "  DEPLOYMENT FAILED ✖" -ForegroundColor Red
    Write-Host "  SSH to $RemoteHost and check docker logs." -ForegroundColor Red
}
Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
