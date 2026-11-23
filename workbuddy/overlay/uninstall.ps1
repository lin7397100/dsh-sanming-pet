# 三明文旅乐园 · 桌宠浮窗 卸载

param(
  [string]$Target = (Join-Path $env:LOCALAPPDATA 'SanmingPetOverlay'),
  [switch]$Purge
)

$ErrorActionPreference = 'SilentlyContinue'
Write-Host '=== 卸载 三明文旅乐园 · 桌宠浮窗 ===' -ForegroundColor Cyan

Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*pet-overlay*' } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
    Write-Host "已结束进程 $($_.ProcessId)"
  }

$desktop = [Environment]::GetFolderPath('Desktop')
$startup = [Environment]::GetFolderPath('Startup')
$programs = [Environment]::GetFolderPath('Programs')
foreach ($p in @($desktop, $startup, $programs)) {
  Remove-Item (Join-Path $p '三明文宠.lnk') -Force
  Remove-Item (Join-Path $p '三明文旅浮窗.lnk') -Force   # 旧名字，一并清掉
}
Write-Host '快捷方式已删除（桌面 / 开机自启 / 开始菜单）'

# 1.9.19：删掉注册表卸载项。之前这里只清 .lnk，卸完后「应用和功能」里会残留一条。
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SanmingPetOverlay'
if (Test-Path $reg) {
  Remove-Item $reg -Recurse -Force
  Write-Host '注册表卸载项已删除'
}

if ($Purge) {
  Remove-Item $Target -Recurse -Force
  Write-Host "目录已删除：$Target" -ForegroundColor Yellow
} else {
  Write-Host "程序目录保留：$Target（想彻底清掉加 -Purge）"
}

Write-Host '卸载完成。' -ForegroundColor Green
