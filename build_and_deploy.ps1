# =============================================================================
# CLIProxyAPI - Build, Push DockerHub & Portainer Deploy Pipeline
# Tu dong dong goi Go server, day Image len DockerHub & redeploy len Portainer
# =============================================================================

param (
    [switch]$SkipPush = $false,
    [switch]$SkipBuild = $false,
    [switch]$AutoDeployProd = $false,
    [switch]$LocalOnly = $false,
    [switch]$NonInteractive = $false
)

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "CLIProxyAPI - Build, Push & Portainer Deploy Pipeline"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "   CLIProxyAPI - Build, Push DockerHub & Portainer Deploy" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host ""

$rootDir = $PSScriptRoot
if (-not $rootDir) {
    $rootDir = Get-Location
}

# 1. Tim va nap file cau hinh (Uu tien portainer.env, sau do toi .env)
$envFile = Join-Path $rootDir "portainer.env"
if (-not (Test-Path $envFile)) {
    $envFile = Join-Path $rootDir ".env"
}

if (-not (Test-Path $envFile)) {
    Write-Host "[LOI] Khong tim thay file portainer.env hoac .env tai $rootDir!" -ForegroundColor Red
    Write-Host " -> Chay lenh sau roi dien token/secret vao file local:" -ForegroundColor Yellow
    Write-Host "    Copy-Item portainer.env.example portainer.env" -ForegroundColor Cyan
    exit 1
}

$envConfig = @{}
Get-Content $envFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $idx = $line.IndexOf("=")
        if ($idx -gt 0) {
            $key = $line.Substring(0, $idx).Trim()
            $rawVal = $line.Substring($idx + 1).Trim()
            if ($rawVal.StartsWith('"') -and $rawVal.EndsWith('"')) {
                $val = $rawVal.Trim('"')
            } elseif ($rawVal.StartsWith("'") -and $rawVal.EndsWith("'")) {
                $val = $rawVal.Trim("'")
            } else {
                $commentIdx = $rawVal.IndexOf("#")
                if ($commentIdx -ge 0) {
                    $rawVal = $rawVal.Substring(0, $commentIdx).Trim()
                }
                $val = $rawVal.Trim('"').Trim("'")
            }
            $envConfig[$key] = $val
        }
    }
}

$repo = if ($envConfig["DOCKER_IMAGE_REPO"]) { $envConfig["DOCKER_IMAGE_REPO"] } else { "dungnt118/freepbx" }
$tag = if ($envConfig["DOCKER_IMAGE_TAG"]) { $envConfig["DOCKER_IMAGE_TAG"] } else { "cli-proxy-api" }
$username = if ($envConfig["DOCKERHUB_USERNAME"]) { $envConfig["DOCKERHUB_USERNAME"] } else { "dungnt118" }
$token = $envConfig["DOCKERHUB_TOKEN"]

$webPort = if ($envConfig["CLIPROXY_PORT"]) { $envConfig["CLIPROXY_PORT"] } else { "8317" }
$dockerImage = if ($envConfig["DOCKER_IMAGE"]) { $envConfig["DOCKER_IMAGE"] } else { "$($repo):$($tag)" }

$portainerUrl = if ($envConfig["PORTAINER_URL"]) { $envConfig["PORTAINER_URL"].TrimEnd("/") } else { "https://portainer.demego.vn" }
$portainerToken = $envConfig["PORTAINER_ACCESS_TOKEN"]
$portainerEndpointId = if ($envConfig["PORTAINER_ENDPOINT_ID"]) { [int]$envConfig["PORTAINER_ENDPOINT_ID"] } else { 3 }
$portainerStackId = if ($envConfig["PORTAINER_STACK_ID"]) { $envConfig["PORTAINER_STACK_ID"] } else { "" }
$portainerStackName = if ($envConfig["PORTAINER_STACK_NAME"]) { $envConfig["PORTAINER_STACK_NAME"] } else { "cli-proxy-api" }

$version = (git describe --tags --always --dirty 2>$null | Out-String).Trim()
if (-not $version) { $version = "dev" }
$commit = (git rev-parse --short HEAD 2>$null | Out-String).Trim()
if (-not $commit) { $commit = "none" }
$buildDate = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "[THONG TIN CAU HINH]" -ForegroundColor Yellow
Write-Host " - File cau hinh:       $envFile"
Write-Host " - DockerHub Repo:      $repo"
Write-Host " - DockerHub Username:  $username"
Write-Host " - Target Docker Image: $dockerImage"
Write-Host " - Version / Commit:    $version ($commit) @ $buildDate"
Write-Host " - Port Public:         http://localhost:$webPort (API & /management.html)"
if ($portainerUrl) {
    $stackDisplay = if ($portainerStackId) { "#$portainerStackId" } else { "(Tu dong tim/tao theo ten)" }
    Write-Host " - Portainer Server:    $portainerUrl (Stack: $portainerStackName | StackId: $stackDisplay | Endpoint: $portainerEndpointId)"
}
Write-Host ""

# 2. Kiem tra Docker Daemon
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[LOI] Docker daemon chua khoi dong hoac chua chay!" -ForegroundColor Red
    if (-not $NonInteractive) { Read-Host "Nhan Enter de thoat..." }
    exit 1
}

# 3. Dang nhap DockerHub bang Token
if (-not $LocalOnly -and -not $SkipPush) {
    if ($token -and $username) {
        Write-Host "[1/4] Dang dang nhap DockerHub voi tai khoan $username..." -ForegroundColor Cyan
        $token | docker login -u $username --password-stdin
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Dang nhap DockerHub thanh cong!" -ForegroundColor Green
        } else {
            Write-Host "[CANH BAO] Dang nhap bang token khong thanh cong. Su dung phien dang nhap hien tai." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[1/4] Khong co DOCKERHUB_TOKEN rieng, su dung phien dang nhap hien tai." -ForegroundColor Yellow
    }
    Write-Host ""
}

# 4. Build Docker Image
if (-not $SkipBuild) {
    Write-Host "[2/4] Bat dau Build Docker Image: $dockerImage ..." -ForegroundColor Cyan
    $dockerFile = Join-Path $rootDir "Dockerfile"
    if (-not (Test-Path $dockerFile)) {
        Write-Host "[LOI] Khong tim thay Dockerfile tai: $rootDir" -ForegroundColor Red
        if (-not $NonInteractive) { Read-Host "Nhan Enter de thoat..." }
        exit 1
    }

    $env:DOCKER_BUILDKIT = 1
    docker build `
        --build-arg "VERSION=$version" `
        --build-arg "COMMIT=$commit" `
        --build-arg "BUILD_DATE=$buildDate" `
        -t $dockerImage `
        -f $dockerFile `
        $rootDir

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[LOI] Build Docker image '$dockerImage' that bai!" -ForegroundColor Red
        if (-not $NonInteractive) { Read-Host "Nhan Enter de thoat..." }
        exit 1
    }
    Write-Host "[OK] Build Docker image '$dockerImage' thanh cong!" -ForegroundColor Green
} else {
    Write-Host "[2/4] Bo qua buoc build Docker image theo tham so -SkipBuild." -ForegroundColor Yellow
}
Write-Host ""

if ($LocalOnly) {
    Write-Host "[HOAN TAT] Che do -LocalOnly: da build xong $dockerImage." -ForegroundColor Green
    exit 0
}

# 5. Push Docker Image len DockerHub
$shouldSkipPush = $SkipPush.IsPresent -or ($envConfig["SKIP_DOCKER_PUSH"] -eq "true") -or ($envConfig["AUTO_PUSH_DOCKERHUB"] -eq "false")
if (-not $shouldSkipPush) {
    Write-Host "[3/4] Dang Push Image len DockerHub: $dockerImage ..." -ForegroundColor Cyan
    docker push $dockerImage
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[LOI] Push image len DockerHub that bai!" -ForegroundColor Red
        if (-not $NonInteractive) { Read-Host "Nhan Enter de thoat..." }
        exit 1
    }
    Write-Host "[OK] Push image len DockerHub thanh cong: $dockerImage" -ForegroundColor Green
} else {
    Write-Host "[3/4] Bo qua buoc Push DockerHub theo cau hinh/tham so." -ForegroundColor Yellow
}
Write-Host ""

# 6. Deploy len Portainer qua REST API
if ($portainerToken) {
    $doDeploy = $AutoDeployProd.IsPresent
    if (-not $doDeploy -and -not $NonInteractive) {
        $ans = Read-Host "Ban co muon deploy len Portainer ($portainerUrl - stack '$portainerStackName') ngay bay gio khong? [y/N]"
        if ($ans -match "^[yY]") {
            $doDeploy = $true
        }
    }

    if ($doDeploy) {
        Write-Host "[4/4] Dang chay deploy/portainer-deploy.mjs..." -ForegroundColor Cyan
        $deployScript = Join-Path $rootDir "deploy\portainer-deploy.mjs"
        node $deployScript
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[LOI] Deploy len Portainer that bai!" -ForegroundColor Red
            if (-not $NonInteractive) { Read-Host "Nhan Enter de thoat..." }
            exit $LASTEXITCODE
        }
        Write-Host "[OK] Deploy len Portainer hoan tat!" -ForegroundColor Green
    } else {
        Write-Host "[4/4] Da bo qua buoc deploy Portainer (chay lai voi -AutoDeployProd neu muon tu dong deploy)." -ForegroundColor Yellow
    }
} else {
    Write-Host "[4/4] Chua cau hinh PORTAINER_ACCESS_TOKEN trong portainer.env — bo qua buoc deploy Portainer." -ForegroundColor Yellow
}
