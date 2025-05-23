# SSH Key-based Authentication Setup Script
# Configure SSH key-based authentication to Open-WebUI server

$SERVER_HOST = "jinrongjie-openwebui.baibaomen.com"
$SERVER_PORT = "8222"
$SERVER_USER = "root"

Write-Host "=== SSH Key-based Authentication Setup Script ===" -ForegroundColor Green
Write-Host "Target server: ${SERVER_USER}@${SERVER_HOST}:${SERVER_PORT}" -ForegroundColor Cyan

# Check if SSH key already exists
$sshKeyPath = "$env:USERPROFILE\.ssh\id_rsa"
$sshPubKeyPath = "$env:USERPROFILE\.ssh\id_rsa.pub"

if (-not (Test-Path $sshKeyPath)) {
    Write-Host "`nSSH key not found, generating new key pair..." -ForegroundColor Yellow
    
    # Create .ssh directory
    $sshDir = "$env:USERPROFILE\.ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    
    # Generate SSH key
    ssh-keygen -t rsa -b 4096 -f $sshKeyPath -N '""' -C "open-webui-deploy"
    
    Write-Host "SSH key generation completed!" -ForegroundColor Green
} else {
    Write-Host "`nExisting SSH key found" -ForegroundColor Green
}

# Read public key content
if (Test-Path $sshPubKeyPath) {
    $publicKey = Get-Content $sshPubKeyPath -Raw
    Write-Host "`nYour public key content:" -ForegroundColor Yellow
    Write-Host $publicKey
    
    Write-Host "`nCopying public key to remote server..." -ForegroundColor Yellow
    Write-Host "Please enter server password (only needed this once):" -ForegroundColor Cyan
    
    # Check if ssh-copy-id command is available
    $sshCopyIdExists = $false
    try {
        Get-Command ssh-copy-id -ErrorAction Stop | Out-Null
        $sshCopyIdExists = $true
    } catch {
        $sshCopyIdExists = $false
    }
    
    if ($sshCopyIdExists) {
        # Use ssh-copy-id
        ssh-copy-id -p $SERVER_PORT -i $sshPubKeyPath "${SERVER_USER}@${SERVER_HOST}"
    } else {
        # Manually copy public key
        $publicKeyEscaped = $publicKey.Trim().Replace('"', '\"')
        $command = "mkdir -p ~/.ssh && echo `"$publicKeyEscaped`" >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
        
        ssh -p $SERVER_PORT "${SERVER_USER}@${SERVER_HOST}" $command
    }
    
    Write-Host "`nTesting SSH key-based authentication..." -ForegroundColor Yellow
    $testCommand = "echo 'SSH key-based authentication configured successfully!'"
    ssh -p $SERVER_PORT "${SERVER_USER}@${SERVER_HOST}" $testCommand
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nSSH key-based authentication setup successful!" -ForegroundColor Green
        Write-Host "You can now run deployment scripts without entering a password." -ForegroundColor Green
    } else {
        Write-Host "`nSSH key-based authentication setup may have failed. Please check:" -ForegroundColor Red
        Write-Host "1. If the server allows key authentication" -ForegroundColor Yellow
        Write-Host "2. If ~/.ssh/authorized_keys file permissions are correct" -ForegroundColor Yellow
        Write-Host "3. If SSH service configuration is correct" -ForegroundColor Yellow
    }
} else {
    Write-Host "Error: Cannot find public key file!" -ForegroundColor Red
    exit 1
}

Write-Host "`nTip: If you still need to enter a password, please check the server's SSH configuration:" -ForegroundColor Yellow
Write-Host "1. Ensure 'PubkeyAuthentication yes' is enabled in /etc/ssh/sshd_config" -ForegroundColor Gray
Write-Host "2. Ensure ~/.ssh directory permission is 700" -ForegroundColor Gray
Write-Host "3. Ensure ~/.ssh/authorized_keys file permission is 600" -ForegroundColor Gray 