# 三明文旅乐园 · 桌宠浮窗 一键安装（Windows）
#
# 用法（在解压出来的目录里右键「使用 PowerShell 运行」，或命令行执行）：
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Autostart      # 同时设置开机自启
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Target D:\Pet  # 装到指定目录
#
# 装完之后：桌面会出现「三明文宠」快捷方式（明奇奇的头像图标），双击即可让明奇奇贴上 WorkBuddy 输入框。

param(
  [string]$Target = (Join-Path $env:LOCALAPPDATA 'SanmingPetOverlay'),
  [switch]$Autostart,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
Write-Host '=== 三明文旅乐园 · 桌宠浮窗 安装 ===' -ForegroundColor Cyan

# 1) 环境检查
if ($env:OS -ne 'Windows_NT') { throw '这个浮窗依赖 Windows 的 WPF，只能在 Windows 上运行。' }
$src = $PSScriptRoot
if (-not (Test-Path (Join-Path $src 'pet-overlay.ps1'))) { throw "安装包不完整：找不到 pet-overlay.ps1（当前目录 $src）" }
if (-not (Test-Path (Join-Path $src 'data\三明三元区轮播.json'))) { throw '安装包不完整：缺少 data\三明三元区轮播.json' }
if (-not (Test-Path (Join-Path $src 'assets\frames\mingqiqi-idle.png'))) { throw '安装包不完整：缺少 assets\frames 帧资源' }

# 知识库是可选功能：缺工具就提示，不阻断安装
$kbOk = $true
if (-not (Test-Path (Join-Path $src 'tools\kb-search.py'))) { $kbOk = $false }
if (-not (Test-Path (Join-Path $src 'tools\sag\sag.exe'))) { $kbOk = $false }
if ($kbOk) {
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
  if (-not $py) {
    $kbOk = $false
    Write-Host ''
    Write-Host '⚠ 没找到 Python，本地知识库检索会不可用（其余功能正常）。' -ForegroundColor Yellow
    Write-Host '  装一个就行：winget install Python.Python.3.12    或    scoop install python' -ForegroundColor Gray
    Write-Host ''
  }
} else {
  Write-Host '⚠ 安装包缺少 tools\ 目录，本地知识库检索会不可用（其余功能正常）。' -ForegroundColor Yellow
}

# 2) 找一个能跑 WPF 的 PowerShell：优先 PowerShell 7（分层透明窗口在 7 上最稳）
function Find-Pwsh {
  $portable = Join-Path $PSScriptRoot 'pwsh\pwsh.exe'
  if (Test-Path $portable) { return $portable }
  $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($c in @(
      (Join-Path $env:USERPROFILE 'scoop\shims\pwsh.exe'),
      (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
      (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')) ) {
    if (Test-Path $c) { return $c }
  }
  return $null
}
$pwshExe = Find-Pwsh
if (-not $pwshExe) {
  $ps5 = Get-Command powershell -ErrorAction SilentlyContinue
  if ($ps5) { $pwshExe = $ps5.Source }
  if (-not $pwshExe) { $pwshExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
  Write-Host ''
  Write-Host '⚠ 没找到 PowerShell 7，先用系统自带的 PowerShell 5.1。' -ForegroundColor Yellow
  Write-Host '  个别机器上 5.1 的透明浮窗可能渲染不正常，推荐先装 7：' -ForegroundColor Yellow
  Write-Host '    winget install Microsoft.PowerShell    或    scoop install pwsh' -ForegroundColor Gray
  Write-Host ''
}
if (-not (Test-Path $pwshExe)) { throw '找不到 PowerShell 解释器' }
Write-Host "解释器：$pwshExe"

# 3) 复制文件（不覆盖已存在的 config.json，保留用户设置）
if (Test-Path $Target) {
  Write-Host "目标目录已存在，更新文件：$Target" -ForegroundColor Yellow
} else {
  New-Item -ItemType Directory -Force -Path $Target | Out-Null
  Write-Host "创建目录：$Target"
}
# SAG 检索服务会占着 tools\sag\sag.exe；不先停掉，robocopy 会按默认「重试一百万次」卡死
Get-Process sag -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 250
$robocopy = Get-Command robocopy -ErrorAction SilentlyContinue
if ($robocopy) {
  & robocopy $src $Target /E /XF config.json preview.png /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "复制文件失败（robocopy 返回 $LASTEXITCODE）" }
} else {
  Copy-Item (Join-Path $src '*') -Destination $Target -Recurse -Force
  Remove-Item (Join-Path $Target 'config.json') -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $Target 'preview.png') -Force -ErrorAction SilentlyContinue
}
# 安装包自身不需要装到目标目录
Remove-Item (Join-Path $Target 'install.ps1') -Force -ErrorAction SilentlyContinue

# 4) 桌面快捷方式
$script = Join-Path $Target 'pet-overlay.ps1'
$shell = New-Object -ComObject WScript.Shell
function New-Shortcut([string]$lnkPath, [string]$desc) {
  $lnk = $shell.CreateShortcut($lnkPath)
  $lnk.TargetPath = $pwshExe
  $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
  $lnk.WorkingDirectory = $Target
  $lnk.WindowStyle = 7
  $lnk.Description = $desc
  # 快捷方式图标用品宠头像（assets\icon\sanmingpet.ico），不再是 PowerShell 的蓝底图标
  $icoPath = Join-Path $Target 'assets\icon\sanmingpet.ico'
  if (Test-Path $icoPath) { $lnk.IconLocation = "$icoPath,0" }
  $lnk.Save()
  Write-Host "快捷方式：$lnkPath"
}
$desktop = [Environment]::GetFolderPath('Desktop')
New-Shortcut (Join-Path $desktop '三明文宠.lnk') '让明奇奇贴在 WorkBuddy 输入框上方'
# 开始菜单也放一份：关掉之后还能在开始菜单搜到、重新打开
$programs = [Environment]::GetFolderPath('Programs')
New-Shortcut (Join-Path $programs '三明文宠.lnk') '三明文旅乐园桌宠（开始菜单入口）'
# 顺手清掉旧名字的快捷方式（1.9.17 及以前叫「三明文旅浮窗」）
foreach ($p in @($desktop, $programs, [Environment]::GetFolderPath('Startup'))) {
  Remove-Item (Join-Path $p '三明文旅浮窗.lnk') -Force -ErrorAction SilentlyContinue
}

# 5) 可选：开机自启
if ($Autostart) {
  $startup = [Environment]::GetFolderPath('Startup')
  New-Shortcut (Join-Path $startup '三明文宠.lnk') '开机自动启动三明文旅桌宠'
}

# 6) 立刻启动（先结束已有实例，避免叠两只）
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*pet-overlay*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 300
if (-not $NoLaunch) {
  Start-Process -FilePath $pwshExe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script`"" -WindowStyle Hidden
  Start-Sleep -Seconds 2
  Write-Host '已启动。' -ForegroundColor Green
}

Write-Host ''
Write-Host '装好了。用法：' -ForegroundColor Cyan
Write-Host '  · 双击桌面「三明文宠」= 启动贴边宠物'
Write-Host '  · 按住宠物或卡片可拖动，拖过之后不再自动跟随'
Write-Host '  · 点宠物弹出设置面板：轮播开关 / 换明灵灵·明宝宝 / 贴边跟随 / 知识库'
Write-Host '  · Ctrl+Alt+K 直接打开本地知识库，绑个文件夹就能提问（不联网）'
Write-Host '  · 点照片用默认浏览器打开该景点详情'
Write-Host '  · 关掉：点宠物 → 设置面板右下角「关闭浮窗」（进程直接结束，不留托盘图标）'
Write-Host '  · 再打开：双击桌面，或开始菜单搜「三明文宠」'
Write-Host '  · 永久不要了：跑 uninstall.ps1（加 -Purge 连目录一起删）'
Write-Host ''
Write-Host "安装位置：$Target"
