$ProxyDir = "$env:USERPROFILE\.claude\claude-opus-proxy"
$Port = 8080

# Kill existing instance on the same port
$existing = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Port $Port already in use - killing old process"
    Stop-Process -Id $existing.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

Write-Host "Starting Claude Opus proxy on http://localhost:8080"
Write-Host "Model: opus (claude-opus-4-8)"
Write-Host ""

$proc = Start-Process -FilePath "node" -ArgumentList "$ProxyDir\server.js","8080","opus" -WindowStyle Hidden -PassThru
Write-Host "PID: $($proc.Id)"
Write-Host ""
Write-Host "GET  http://localhost:8080/v1/models"
Write-Host "POST http://localhost:8080/v1/chat/completions"
Write-Host ""
Write-Host "In Hermes: select model claude-code-cli / claude-opus"
