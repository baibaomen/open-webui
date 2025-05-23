# Open-WebUI Frontend Deployment Script - Simple Version
# Server configuration
$SERVER = "root@jinrongjie-openwebui.baibaomen.com"
$PORT = "8222"
$REMOTE_DIR = "/open-webui/frontend"
$BUILD_DIR = "./build"

# Check build directory
if (!(Test-Path $BUILD_DIR)) {
    Write-Host "Error: build directory not found!" -ForegroundColor Red
    exit 1
}

# 1. Create ZIP archive using 7-Zip
Write-Host "Creating ZIP archive..." -ForegroundColor Yellow
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$zipFile = "$env:TEMP\frontend-$timestamp.zip"

# Use 7-Zip (try common installation paths)
$7zip = if (Test-Path "C:\Program Files\7-Zip\7z.exe") {
    "C:\Program Files\7-Zip\7z.exe" 
} elseif (Test-Path "C:\Program Files (x86)\7-Zip\7z.exe") {
    "C:\Program Files (x86)\7-Zip\7z.exe"
} else {
    Write-Host "Error: 7-Zip not found!" -ForegroundColor Red
    exit 1
}

& $7zip a -tzip -mx=3 $zipFile "$BUILD_DIR\*" -r | Out-Null

# 2. Upload to server
Write-Host "Uploading to server..." -ForegroundColor Yellow
scp -P $PORT $zipFile "${SERVER}:/tmp/"

# 3 & 4. Backup and deploy on server
Write-Host "Deploying on server..." -ForegroundColor Yellow

# Get zip filename for use in remote commands
$zipFileName = Split-Path $zipFile -Leaf

# Execute remote commands - all in one line to avoid Windows line ending issues
$remoteCommands = "cd /tmp && [ -d $REMOTE_DIR ] && mv $REMOTE_DIR ${REMOTE_DIR}-backup-$timestamp; mkdir -p $REMOTE_DIR && cd $REMOTE_DIR && unzip -q /tmp/$zipFileName && [ -d build ] && mv build/* . && rmdir build; rm -f /tmp/$zipFileName && echo 'Deployment completed!'"

ssh -p $PORT $SERVER $remoteCommands

# Cleanup local file
Remove-Item $zipFile -Force

Write-Host "Done!" -ForegroundColor Green