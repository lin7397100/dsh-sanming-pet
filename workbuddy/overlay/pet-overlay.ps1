# 三明文旅乐园 · WorkBuddy 贴边浮窗（可交互版）
#
# 功能：
#   - 左边景点照片卡片，轮播三元区 6 个景点；点照片用默认浏览器打开该景点详情
#   - 右边明奇奇（可换明灵灵 / 明宝宝），会呼吸、会播放跃起/翻滚/挥手等动作
#   - 按住任意位置可拖动整只浮窗；拖过之后停止自动跟随，位置存进配置
#   - 点宠物弹出设置面板：轮播开关 / 换宠物 / 贴边跟随 / 打开当前景点
#   - 空白处鼠标穿透，不挡下面的输入框
#
# 用法：
#   pwsh -File pet-overlay.ps1            常驻，贴在 WorkBuddy 输入框上方
#   pwsh -File pet-overlay.ps1 -Preview   只离屏渲染一张预览图
#   pwsh -File pet-overlay.ps1 -Detach    不跟随，固定屏幕右下角
#
# 关闭：点宠物 → 设置面板右下角「关闭浮窗」；再启动：双击桌面 / 开始菜单里的「三明文宠」

param(
  [switch]$Preview,
  [switch]$PreviewPanel,
  [switch]$Compact,
  [switch]$Detach,
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

function global:Write-PetLog([string]$msg) {
  try {
    $p = Join-Path $env:TEMP 'sanming-pet-overlay.log'
    Add-Content -Path $p -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8
  } catch { }
}

# ---------- 单实例：重复双击不要叠出第二只宠物 ----------
if (-not $Preview) {
  try {
    $script:InstMutex = New-Object System.Threading.Mutex($false, 'SanmingPetOverlaySingle')
    if (-not $script:InstMutex.WaitOne(0)) {
      Write-PetLog 'exit: 已有实例在运行，本次启动直接退出'
      [System.Environment]::Exit(0)
    }
  } catch { }
}

# ---------- 资源位置：优先用自带 assets，没有再用 dsh-sanming-pet 插件 ----------
$LocalFrames = Join-Path $PSScriptRoot 'assets\frames'
$Frames = $LocalFrames
if (-not (Test-Path $LocalFrames)) {
  $PluginRoot = @(
    'C:\Users\lin\Doubao\chats\2026-11-13\new-chat\_github\dsh-sanming-pet',
    (Join-Path $env:USERPROFILE '.dsh\profiles\desktop\node_modules\dsh-sanming-pet'),
    (Join-Path $env:USERPROFILE '.dsh\profiles\superagent\node_modules\dsh-sanming-pet')
  ) | Where-Object { Test-Path (Join-Path $_ 'lib\assets\frames\mingqiqi-idle.png') } | Select-Object -First 1
  if (-not $PluginRoot) { throw '找不到宠物帧资源（assets\frames 或 dsh-sanming-pet 插件都缺）' }
  $Frames = Join-Path $PluginRoot 'lib\assets\frames'
}

$DataFile = Join-Path $PSScriptRoot 'data\三明三元区轮播.json'
if (-not (Test-Path $DataFile)) { throw "缺少轮播数据：$DataFile" }
$items = (Get-Content $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json).items
if (-not $items -or $items.Count -eq 0) { throw '轮播数据为空' }

$ConfigFile = Join-Path $PSScriptRoot 'data\config.json'




# 每个景点的详情页（点照片时打开；数据里带 url 的优先用数据）
$SpotUrl = @{
  '万寿岩'   = 'https://smrb.smnet.com.cn/pad/layout/content/202609/26/content_9316.html'
  '格氏栲'   = 'https://smrb.smnet.com.cn/pad/layout/content/202607/04/content_5851.html'
  '麒麟山'   = 'http://www.fjsyxww.com/2024-02/06/content_1638973.htm'
  '仙人谷'   = 'https://m.baike.com/wiki/%E4%B8%89%E6%98%8E%E4%BB%99%E4%BA%BA%E8%B0%B7%E5%9B%BD%E5%AE%B6%E6%A3%AE%E6%9E%97%E5%85%AC%E5%9B%AD/494930'
  '十八寨'   = 'https://www.bing.com/search?q=%E4%B8%89%E5%85%83%E5%8C%BA%20%E5%BF%A0%E5%B1%B1%E5%8D%81%E5%85%AB%E5%AF%A8'
  '城市绿道' = 'http://m.toutiao.com/group/6193274297451987201/'
}

# ---------- 模型配置（可选：接自己的 LLM 出答案 / 接 JEV 做语义增强；不配则纯检索） ----------
$ModelFile = Join-Path $PSScriptRoot 'data\模型.json'

function Load-ModelCfg {
  $def = [ordered]@{
    answer = [ordered]@{ enabled = $false; baseUrl = ''; model = ''; apiKey = ''; maxTokens = 700; topN = 5 }
    jev    = [ordered]@{ url = ''; model = ''; auth = 'none'; key = '' }
  }
  if (Test-Path $ModelFile) {
    try {
      $j = Get-Content $ModelFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($sec in @('answer', 'jev')) {
        $sv = $j.PSObject.Properties[$sec]
        if ($sv -and $sv.Value) {
          foreach ($k in @($def[$sec].Keys)) {
            $pv = $sv.Value.PSObject.Properties[$k]
            if ($pv -and $null -ne $pv.Value) { $def[$sec][$k] = $pv.Value }
          }
        }
      }
    } catch { Write-PetLog "模型配置读取失败: $($_.Exception.Message)" }
  }
  return $def
}

function Save-ModelCfg {
  try {
    $dir = Split-Path $ModelFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($script:LlmCfg | ConvertTo-Json -Depth 6) | Set-Content -Path $ModelFile -Encoding UTF8
    Write-PetLog '模型配置已保存'
  } catch { Write-PetLog "模型配置保存失败: $($_.Exception.Message)" }
}

# 开关 + 地址 + 模型名 三样齐了才算能出答案
function Get-LlmReady {
  $a = $script:LlmCfg.answer
  if (-not [bool]$a.enabled) { return $false }
  if ([string]::IsNullOrWhiteSpace([string]$a.baseUrl)) { return $false }
  if ([string]::IsNullOrWhiteSpace([string]$a.model)) { return $false }
  return $true
}

# 用户可能填 http://x:11434、http://x:11434/v1 或完整 endpoint，统一归一化
function Get-ChatEndpoint([string]$base) {
  $u = ([string]$base).Trim().TrimEnd('/')
  if ($u -match 'chat/completions$') { return $u }
  if ($u -match '/v\d+$') { return "$u/chat/completions" }
  return "$u/v1/chat/completions"
}

# JEV 是否已配置，以 sag status 为准，不信本地 json
function Get-JevConfigured {
  if (-not (Test-Path $script:SagExe)) { return $null }
  # sag 输出是 UTF-8，控制台默认编码不是的话中文会乱，正则就永远匹配不上
  $old = $null
  try {
    $old = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
  } catch { }
  try {
    $out = (& $script:SagExe status 2>&1 | Out-String)
    if ($out -match 'JEV\s*已配置[:：]\s*(true|false)') { return ($matches[1] -eq 'true') }
  } catch { } finally {
    if ($old) { try { [Console]::OutputEncoding = $old } catch { } }
  }
  return $null
}

$script:LlmCfg = Load-ModelCfg

# ---------- 配置 ----------
function Load-Config {
  $def = [ordered]@{ pet = 'mingqiqi'; carouselOn = $true; follow = $true; showCard = $true; left = $null; top = $null }
  if (Test-Path $ConfigFile) {
    try {
      $j = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($k in @($def.Keys)) {
        $pv = $j.PSObject.Properties[$k]
        if ($pv -and $null -ne $pv.Value) { $def[$k] = $pv.Value }
      }
    } catch { Write-PetLog "配置读取失败，用默认值: $($_.Exception.Message)" }
  }
  return $def
}
function Save-Config {
  try {
    # 窗口还没 Show（比如启动时 Apply-Pet 就会调一次）时，$win.Left 是 WPF 给的
    # 默认值，不是用户摆的位置。这时候必须沿用已存的位置，否则每启动一次宠物就挪一次。
    $vis = $false
    try { $vis = [bool]$win.IsVisible } catch { }
    $curL = $null
    $curT = $null
    if ($vis) {
      $curL = [int]$win.Left
      $curT = [int]$win.Top
    }
    if ($null -eq $curL -and $null -ne $script:savedLeft) {
      $curL = [int]$script:savedLeft
      $curT = [int]$script:savedTop
    }
    $cfg = [ordered]@{
      pet        = $script:petId
      carouselOn = $script:carouselOn
      follow     = $script:followOn
      showCard   = $script:showCard
      left       = if ($script:followOn) { $null } else { $curL }
      top        = if ($script:followOn) { $null } else { $curT }
    }
    if ($vis -and -not $script:followOn) {
      $script:savedLeft = $curL
      $script:savedTop = $curT
    }
    $dir = Split-Path $ConfigFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    ($cfg | ConvertTo-Json -Depth 4) | Set-Content -Path $ConfigFile -Encoding UTF8
  } catch { Write-PetLog "配置保存失败: $($_.Exception.Message)" }
}

$cfg = Load-Config
$script:petId = if ($cfg.pet) { $cfg.pet } else { 'mingqiqi' }
$script:carouselOn = [bool]$cfg.carouselOn
$script:followOn = [bool]$cfg.follow
$script:showCard = if ($null -ne $cfg.showCard) { [bool]$cfg.showCard } else { $true }
$script:savedLeft = $cfg.left
$script:savedTop = $cfg.top

# 速览数据：关掉景区卡片后，头顶小标签轮播这些短句
$ShortFile = Join-Path $PSScriptRoot 'data\三元区速览.json'
$shortItems = @()
if (Test-Path $ShortFile) {
  try { $shortItems = (Get-Content $ShortFile -Raw -Encoding UTF8 | ConvertFrom-Json).items } catch { }
}
if (-not $shortItems -or $shortItems.Count -eq 0) { $shortItems = @(@{ kind = '景区'; text = '三明三元区 · 万寿岩 18.5 万年' }) }
$script:shortIdx = -1
$script:showCard -eq $false | Out-Null

# ---------- 知识库（复用 SAG Wiki 的本地索引，纯本地 BM25，不联网） ----------
$script:SagExe = Join-Path $PSScriptRoot 'tools\sag\sag.exe'
$script:KbScript = Join-Path $PSScriptRoot 'tools\kb-search.py'
$script:KbRoots = @()
$script:KbWin = $null
$script:KbBusy = $false
$script:pyPath = $null

function Get-PythonPath {
  if ($script:pyPath) { return $script:pyPath }
  $cands = @(
    (Join-Path $env:USERPROFILE 'scoop\apps\python\current\python.exe'),
    (Join-Path $env:USERPROFILE 'scoop\shims\python.exe'),
    'C:\Python313\python.exe', 'C:\Python312\python.exe', 'C:\Python311\python.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python313\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe')
  )
  try { $g = Get-Command python -ErrorObject SilentlyContinue; if ($g) { $cands += $g.Source } } catch { }
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { $script:pyPath = $c; return $c } }
  return $null
}

# 调 kb-search.py，把中文输出按 UTF-8 收回来
# 注意：桌面快捷方式启动的 pwsh 没有 PYTHONUTF8，python 在 Windows 下 stdout 会退回
# 系统代码页（中文系统是 cp936/GBK）。下面这行 Console 编码是"按 UTF-8 解码"，
# 所以必须同时强制 python 也按 UTF-8 输出，否则中文路径/文件名全是乱码（1.9.18 修复）。
function Invoke-KbPython {
  param([string[]]$ArgList)
  $py = Get-PythonPath
  if (-not $py) { Write-PetLog 'kb: 没找到 python'; return $null }
  if (-not (Test-Path $script:KbScript)) { Write-PetLog 'kb: 缺 tools\kb-search.py'; return $null }
  $oldOut = $null
  $oldIo = $env:PYTHONIOENCODING
  $oldUtf8 = $env:PYTHONUTF8
  try { $oldOut = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
  $env:PYTHONIOENCODING = 'utf-8'
  $env:PYTHONUTF8 = '1'
  try {
    $out = & $py $script:KbScript @ArgList 2>&1
    return (($out | ForEach-Object { [string]$_ }) -join "`n")
  } catch {
    Write-PetLog "kb: python 调用失败 $($_.Exception.Message)"
    return $null
  } finally {
    if ($null -eq $oldIo) { Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue }
    else { $env:PYTHONIOENCODING = $oldIo }
    if ($null -eq $oldUtf8) { Remove-Item Env:\PYTHONUTF8 -ErrorAction SilentlyContinue }
    else { $env:PYTHONUTF8 = $oldUtf8 }
    if ($oldOut) { try { [Console]::OutputEncoding = $oldOut } catch { } }
  }
}

# ---------- Win32 ----------
Add-Type -Namespace Native -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
'@

function Get-WorkBuddyRect {
  $targets = @()
  foreach ($name in @('WorkBuddy', 'WorkBuddy.exe', 'CodeBuddy', 'CodeBuddy.exe')) {
    try { $targets += [System.Diagnostics.Process]::GetProcessesByName($name) } catch { }
  }
  foreach ($proc in $targets) {
    $h = $proc.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { continue }
    $r = New-Object Native.Win+RECT
    if ([Native.Win]::GetWindowRect($h, [ref]$r) -and ($r.Right - $r.Left) -gt 400) {
      return @{ Left = $r.Left; Top = $r.Top; Right = $r.Right; Bottom = $r.Bottom }
    }
  }
  return $null
}

# ---------- 界面 ----------
$W = 560
$H = 348

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="$W" Height="$H"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize">
  <Grid x:Name="Root" Background="Transparent">
    <!-- 不要 DropShadowEffect：分层窗口上阴影会在圆角外糊成一圈灰边，改成 1px 描边 -->
    <Border x:Name="Card" Width="288" HorizontalAlignment="Left" VerticalAlignment="Center"
            Margin="10,0,0,0" CornerRadius="18" Background="#FFFFFF"
            BorderBrush="#E1E9E3" BorderThickness="1" Opacity="0" Cursor="Hand">
      <Grid>
        <!-- 景点卡片 -->
        <StackPanel x:Name="CardView" Margin="12,12,12,14">
          <Rectangle x:Name="Photo" Height="178" RadiusX="13" RadiusY="13">
            <Rectangle.Fill>
              <ImageBrush x:Name="PhotoBrush" Stretch="UniformToFill" AlignmentX="Center" AlignmentY="Center"/>
            </Rectangle.Fill>
          </Rectangle>
          <StackPanel Orientation="Horizontal" Margin="2,11,0,0">
            <Ellipse Width="7" Height="7" Fill="#43A047" VerticalAlignment="Center" Margin="0,1,7,0"/>
            <TextBlock x:Name="SpotTitle" FontSize="15.5" FontWeight="Bold" Foreground="#1E3329"
                       FontFamily="Microsoft YaHei"/>
          </StackPanel>
          <TextBlock x:Name="SpotDesc" FontSize="12.3" Foreground="#54635A" TextWrapping="Wrap"
                     LineHeight="18.6" Margin="2,5,2,0" FontFamily="Microsoft YaHei"/>
          <TextBlock x:Name="HintLine" Text="点照片打开详情 · 点我设置" FontSize="10.5"
                     Foreground="#9AA79E" Margin="2,8,0,0" FontFamily="Microsoft YaHei"/>
        </StackPanel>

        <!-- 设置面板 -->
        <StackPanel x:Name="PanelView" Margin="14,12,14,12" Visibility="Collapsed">
          <TextBlock Text="贴边浮窗设置" FontSize="14.5" FontWeight="Bold" Foreground="#1E3329"
                     FontFamily="Microsoft YaHei" Margin="0,0,0,10"/>

          <Border x:Name="RowCarousel" CornerRadius="10" Background="#F2F6F3" Padding="10,7,10,7" Margin="0,0,0,8" Cursor="Hand">
            <Grid>
              <TextBlock Text="景点轮播" FontSize="12.5" Foreground="#3A4C40" FontFamily="Microsoft YaHei" VerticalAlignment="Center"/>
              <Border x:Name="ChipCarousel" HorizontalAlignment="Right" CornerRadius="9" Background="#43A047" Padding="9,2,9,2">
                <TextBlock x:Name="ChipCarouselText" Text="开" FontSize="11" Foreground="White" FontFamily="Microsoft YaHei"/>
              </Border>
            </Grid>
          </Border>

          <Border x:Name="RowCard" CornerRadius="10" Background="#F2F6F3" Padding="10,7,10,7" Margin="0,0,0,8" Cursor="Hand">
            <Grid>
              <TextBlock Text="景区卡片" FontSize="12.5" Foreground="#3A4C40" FontFamily="Microsoft YaHei" VerticalAlignment="Center"/>
              <Border x:Name="ChipCard" HorizontalAlignment="Right" CornerRadius="9" Background="#43A047" Padding="9,2,9,2">
                <TextBlock x:Name="ChipCardText" Text="开" FontSize="11" Foreground="White" FontFamily="Microsoft YaHei"/>
              </Border>
            </Grid>
          </Border>

          <Border x:Name="RowKb" CornerRadius="10" Background="#F2F6F3" Padding="10,7,10,7" Margin="0,0,0,8" Cursor="Hand">
            <Grid>
              <TextBlock Text="知识库" FontSize="12.5" Foreground="#3A4C40" FontFamily="Microsoft YaHei" VerticalAlignment="Center"/>
              <Border x:Name="ChipKb" HorizontalAlignment="Right" CornerRadius="9" Background="#BFC7C1" Padding="9,2,9,2">
                <TextBlock x:Name="ChipKbText" Text="未绑定" FontSize="11" Foreground="White" FontFamily="Microsoft YaHei"/>
              </Border>
            </Grid>
          </Border>

          <TextBlock Text="形象" FontSize="11.5" Foreground="#7C8A80" FontFamily="Microsoft YaHei" Margin="2,0,0,6"/>
          <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
            <Border x:Name="PickQiqi" CornerRadius="10" Padding="4" Background="Transparent" Cursor="Hand">
              <Image x:Name="ThumbQiqi" Width="52" Height="52" Stretch="Uniform"/>
            </Border>
            <Border x:Name="PickLingling" CornerRadius="10" Padding="4" Background="Transparent" Margin="6,0,0,0" Cursor="Hand">
              <Image x:Name="ThumbLingling" Width="52" Height="52" Stretch="Uniform"/>
            </Border>
            <Border x:Name="PickBaobao" CornerRadius="10" Padding="4" Background="Transparent" Margin="6,0,0,0" Cursor="Hand">
              <Image x:Name="ThumbBaobao" Width="52" Height="52" Stretch="Uniform"/>
            </Border>
          </StackPanel>

          <Border x:Name="RowFollow" CornerRadius="10" Background="#F2F6F3" Padding="10,7,10,7" Margin="0,0,0,8" Cursor="Hand">
            <Grid>
              <TextBlock Text="位置" FontSize="12.5" Foreground="#3A4C40" FontFamily="Microsoft YaHei" VerticalAlignment="Center"/>
              <TextBlock x:Name="FollowText" Text="跟随 WorkBuddy" FontSize="11" Foreground="#5A6B60"
                         FontFamily="Microsoft YaHei" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </Border>

          <Border x:Name="RowOpen" CornerRadius="10" Background="#EAF3EC" Padding="10,7,10,7" Cursor="Hand">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="打开当前景点详情" FontSize="12.5" Foreground="#2E7D32" FontFamily="Microsoft YaHei" VerticalAlignment="Center"/>
                <TextBlock Text="↗" FontSize="13" Foreground="#2E7D32" FontFamily="Microsoft YaHei" VerticalAlignment="Center" Margin="6,0,0,0"/>
              </StackPanel>
              <!-- 关闭浮窗：真的结束进程，不是缩到托盘；再启动双击桌面/开始菜单的快捷方式 -->
              <Border x:Name="BtnQuit" Grid.Column="1" CornerRadius="8" Background="#FBEFEC"
                      BorderBrush="#EFD3C8" BorderThickness="1" Padding="12,2,12,2"
                      Cursor="Hand" VerticalAlignment="Center" Margin="10,0,0,0">
                <TextBlock Text="关闭浮窗" FontSize="12" Foreground="#9A4C33" FontWeight="SemiBold"
                           FontFamily="Microsoft YaHei" IsHitTestVisible="False"/>
              </Border>
            </Grid>
          </Border>        </StackPanel>
      </Grid>
    </Border>

    <Image x:Name="Pet" Width="230" Height="230" Stretch="Uniform"
           HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,6,0"
           Cursor="Hand" RenderOptions.BitmapScalingMode="HighQuality">
      <Image.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="PetScale" ScaleX="1" ScaleY="1"/>
          <TranslateTransform x:Name="PetShift" X="0" Y="0"/>
        </TransformGroup>
      </Image.RenderTransform>
    </Image>

    <!-- 精简模式：头顶小标签，轮播景区/美食/特产一句话 -->
    <Border x:Name="Bubble" HorizontalAlignment="Center" VerticalAlignment="Top"
            Margin="8,4,8,0" MaxWidth="236" CornerRadius="13" Background="#FFFFFF"
            BorderBrush="#E1E9E3" BorderThickness="1" Padding="10,6,10,6"
            Visibility="Collapsed" Cursor="Hand">
      <StackPanel Orientation="Horizontal">
        <Border x:Name="BubbleDot" Width="6" Height="6" CornerRadius="3" Background="#43A047"
                VerticalAlignment="Center" Margin="0,0,8,0"/>
        <TextBlock x:Name="BubbleText" FontSize="12" Foreground="#24382C"
                   FontFamily="Microsoft YaHei" TextWrapping="Wrap" MaxWidth="196" LineHeight="17"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
"@

$win = [System.Windows.Markup.XamlReader]::Parse($xaml)
$pet = $win.FindName('Pet')
$card = $win.FindName('Card')
$cardView = $win.FindName('CardView')
$panelView = $win.FindName('PanelView')
$photo = $win.FindName('Photo')
$photoBrush = $photo.Fill
$spotTitle = $win.FindName('SpotTitle')
$spotDesc = $win.FindName('SpotDesc')
$petScale = $win.FindName('PetScale')
$petShift = $win.FindName('PetShift')
$chipCarousel = $win.FindName('ChipCarousel')
$chipCarouselText = $win.FindName('ChipCarouselText')
$followText = $win.FindName('FollowText')
$bubble = $win.FindName('Bubble')
$bubbleText = $win.FindName('BubbleText')
$bubbleDot = $win.FindName('BubbleDot')

# ---------- 图片加载 ----------
$script:frameCache = @{}
function Load-Bmp([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  $b = New-Object System.Windows.Media.Imaging.BitmapImage
  $b.BeginInit()
  $b.CacheOption = 'OnLoad'
  $b.UriSource = New-Object System.Uri($path)
  $b.EndInit()
  $b.Freeze()
  return $b
}
function Get-Frame([string]$name) {
  $key = "$script:petId|$name"
  if ($script:frameCache.ContainsKey($key)) { return $script:frameCache[$key] }
  $bmp = Load-Bmp (Join-Path $Frames "$($script:petId)-$name.png")
  $script:frameCache[$key] = $bmp
  return $bmp
}

$script:photoCache = @{}
function Get-Photo([string]$rel) {
  if (-not $rel) { return $null }
  if ($script:photoCache.ContainsKey($rel)) { return $script:photoCache[$rel] }
  $bmp = Load-Bmp (Join-Path (Join-Path $PSScriptRoot 'data') $rel)
  $script:photoCache[$rel] = $bmp
  return $bmp
}

# 呼吸：3 秒一个来回
$breathe = New-Object System.Windows.Media.Animation.Storyboard
foreach ($t in @('ScaleX', 'ScaleY')) {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation 0.988, 1.012, ([TimeSpan]::FromSeconds(3))
  $a.AutoReverse = $true
  $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $a.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
  [System.Windows.Media.Animation.Storyboard]::SetTarget($a, $petScale)
  [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($a, (New-Object System.Windows.PropertyPath $t))
  $breathe.Children.Add($a)
}
$sh = New-Object System.Windows.Media.Animation.DoubleAnimation 0, -3, ([TimeSpan]::FromSeconds(3))
$sh.AutoReverse = $true
$sh.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
$sh.EasingFunction = New-Object System.Windows.Media.Animation.SineEase
[System.Windows.Media.Animation.Storyboard]::SetTarget($sh, $petShift)
[System.Windows.Media.Animation.Storyboard]::SetTargetProperty($sh, (New-Object System.Windows.PropertyPath 'Y'))
$breathe.Children.Add($sh)

# ---------- 动作库 ----------
$PosePool = @('wave', 'waveUp', 'cheer', 'clap', 'jump', 'tada', 'stretch', 'point', 'raise', 'hug', 'sit', 'sleep', 'turnL', 'turnB', 'walk', 'run1', 'run2', 'ball', 'hold', 'holdL')
$SeqPool = @{
  mingqiqi    = @(@('qiLeapA', 'qiLeapB', 'qiLeapC', 'qiLeapD'), @('qiRollA', 'qiRollB', 'qiRollC', 'qiRollD', 'qiRollE'), @('qiRushA', 'qiRushB', 'qiRushC'))
  minglingling = @(@('lingHopA', 'lingHopB', 'lingHopC', 'lingHopD'), @('lingRollA', 'lingRollB', 'lingRollC', 'lingRollD', 'lingRollE'), @('lingBowA', 'lingBowC'))
  mingbaobao  = @(@('baoBoingA', 'baoBoingB', 'baoBoingC', 'baoBoingD'), @('baoRollA', 'baoRollB', 'baoRollC', 'baoRollD', 'baoRollE'), @('baoHugA', 'baoHugB', 'baoHugC'))
}

$script:actTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:actTimer.Interval = [TimeSpan]::FromSeconds(1)

$script:seqTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:seqTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:seqTimer.Add_Tick({
  if ($script:seqIdx -lt $script:seqFrames.Count) {
    $pet.Source = $script:seqFrames[$script:seqIdx]
    $script:seqIdx++
  } else {
    $script:seqTimer.Stop()
    $pet.Source = Get-Frame 'idle'
    $script:actGap = 0
    $script:actTimer.Start()
  }
})

$script:poseTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:poseTimer.Interval = [TimeSpan]::FromMilliseconds(1300)
$script:poseTimer.Add_Tick({
  $script:poseTimer.Stop()
  $pet.Source = Get-Frame 'idle'
  $script:actGap = 0
  $script:actTimer.Start()
})

function Play-Pose([string]$name) {
  $b = Get-Frame $name
  if (-not $b) { return }
  $script:seqTimer.Stop(); $script:poseTimer.Stop(); $script:actTimer.Stop()
  $pet.Source = $b
  $script:poseTimer.Stop()
  $script:poseTimer.Start()
}

function Play-Seq([string[]]$names) {
  $fr = @()
  foreach ($n in $names) { $b = Get-Frame $n; if ($b) { $fr += $b } }
  if ($fr.Count -eq 0) { return }
  $script:seqTimer.Stop(); $script:poseTimer.Stop(); $script:actTimer.Stop()
  $script:seqFrames = $fr
  $script:seqIdx = 0
  $script:seqTimer.Start()
}

# 每 ~1 秒记一次秒数，攒够随机间隔就挑一个动作；这样比固定 9 秒更像"活物"
$script:actGap = 0
$script:actDue = 6
$script:actTimer.Add_Tick({
  $script:actGap++
  if ($script:actGap -ge $script:actDue) {
    $script:actTimer.Stop()
    $script:actDue = Get-Random -Minimum 5 -Maximum 11
    $script:actGap = 0
    # 4 成播连帧（跃起/翻滚/冲），6 成摆单帧姿势
    if ((Get-Random -Maximum 10) -lt 4) {
      $seqs = $SeqPool[$script:petId]
      if ($seqs -and $seqs.Count -gt 0) {
        Play-Seq $seqs[(Get-Random -Maximum $seqs.Count)]
        return
      }
    }
    $cand = $PosePool | Where-Object { Test-Path (Join-Path $Frames "$($script:petId)-$_.png") }
    if ($cand -and $cand.Count -gt 0) {
      Play-Pose ($cand[(Get-Random -Maximum $cand.Count)])
    } else {
      $script:actTimer.Start()
    }
  }
})

# ---------- 轮播 ----------
$script:idx = -1
$script:busy = $false

function Apply-Item($item) {
  $spotTitle.Text = $item.title
  $spotDesc.Text = $item.text
  $bmp = Get-Photo $item.img
  if ($bmp) { $photoBrush.ImageSource = $bmp }
}

function Show-NextLine {
  if ($script:busy) { return }
  if (-not $script:carouselOn) { return }
  # 精简模式：卡片不显示，改轮到头顶小标签
  if (-not $script:showCard) { Show-Bubble; return }
  # 设置面板打开时不要淡出卡片，否则面板跟着一起闪
  if ($panelView -and $panelView.Visibility -eq 'Visible') { $card.Opacity = 1; return }
  $script:busy = $true
  $script:idx = ($script:idx + 1) % $items.Count
  $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation 1, 0, ([TimeSpan]::FromMilliseconds(240))
  $fadeOut.Add_Completed({
    try {
      Apply-Item $items[$script:idx]
      $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation 0, 1, ([TimeSpan]::FromMilliseconds(360))
      $card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)
    } catch {
      Write-PetLog ("换条失败 idx=$($script:idx): " + $_.Exception.Message)
      $card.Opacity = 1
    }
    $script:busy = $false
  })
  $card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
}

$lineTimer = New-Object System.Windows.Threading.DispatcherTimer
$lineTimer.Interval = [TimeSpan]::FromSeconds(7)
$lineTimer.Add_Tick({ Show-NextLine })

function Update-Chip {
  $green = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#43A047'))
  $gray = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#BFC7C1'))
  if ($script:carouselOn) {
    $chipCarousel.Background = $green
    $chipCarouselText.Text = '开'
  } else {
    $chipCarousel.Background = $gray
    $chipCarouselText.Text = '关'
  }
  $cardChip = $win.FindName('ChipCard')
  $cardChipText = $win.FindName('ChipCardText')
  if ($cardChip -and $cardChipText) {
    if ($script:showCard) { $cardChip.Background = $green; $cardChipText.Text = '开' }
    else { $cardChip.Background = $gray; $cardChipText.Text = '关' }
  }
}

function Set-Carousel([bool]$on) {
  $script:carouselOn = $on
  Update-Chip
  if ($on) { $lineTimer.Start(); Show-NextLine } else { $lineTimer.Stop() }
  Save-Config
}

# 头顶小标签：轮播三元区速览短句
function Show-Bubble {
  if (-not $script:carouselOn) { return }
  $script:shortIdx = ($script:shortIdx + 1) % $shortItems.Count
  $it = $shortItems[$script:shortIdx]
  $bubbleText.Text = [string]$it.text
  $col = '#43A047'
  if ($it.kind -eq '美食') { $col = '#EF8A3C' } elseif ($it.kind -eq '特产') { $col = '#C2543F' }
  $bubbleDot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($col))
  $fade = New-Object System.Windows.Media.Animation.DoubleAnimation 0.35, 1.0, ([TimeSpan]::FromMilliseconds(320))
  $bubble.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
}

# 显示景区卡片 / 只留宠物：窗口尺寸和控件位置一起换
function Apply-Layout {
  if ($script:showCard) {
    $win.Width = 560
    $win.Height = 348
    $card.Visibility = 'Visible'
    $bubble.Visibility = 'Collapsed'
    $pet.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $pet.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $pet.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
    $card.Opacity = 1
  } else {
    $win.Width = 252
    $win.Height = 300
    $card.Visibility = 'Collapsed'
    $bubble.Visibility = 'Visible'
    $pet.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $pet.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    $pet.Margin = New-Object System.Windows.Thickness 0, 0, 4, 8
    $bubble.Opacity = 1
    Show-Bubble
  }
  try { Update-Position } catch { }
  try { Keep-OnScreen } catch { }
}

function Set-ShowCard([bool]$on) {
  $script:showCard = $on
  Update-Chip
  # 面板开着就先别改窗口尺寸，等关掉面板再应用
  if ($panelView -and $panelView.Visibility -eq 'Visible') { Save-Config; return }
  Apply-Layout
  Save-Config
}

# 展开/收起设置面板。面板要 288 宽，精简模式放不下，所以展开时临时把窗口撑回完整尺寸
function Show-Panel([bool]$show) {
  if ($show) {
    # 记住展开前的位置：面板比精简态宽 308px，贴着屏幕右边展开会顶出屏外
    $script:panelPrevPos = @([double]$win.Left, [double]$win.Top)
    # 面板比卡片高（多了「知识库」一行），展开时把窗口一起撑高
    $win.Width = 560
    $win.Height = 396
    $card.Visibility = 'Visible'
    $bubble.Visibility = 'Collapsed'
    $pet.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $pet.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $pet.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
    $cardView.Visibility = 'Collapsed'
    $panelView.Visibility = 'Visible'
    $card.Opacity = 1
  } else {
    $panelView.Visibility = 'Collapsed'
    $cardView.Visibility = 'Visible'
    Apply-Layout
    # 收起后窗口退回窄的，位置也退回展开前那个点，宠物重新贴回屏幕右边
    if ($script:panelPrevPos) {
      $win.Left = $script:panelPrevPos[0]
      $win.Top = $script:panelPrevPos[1]
      $script:panelPrevPos = $null
    }
  }
  try { Keep-OnScreen } catch { }
  try { Update-Position } catch { }
}

# ---------- 宠物 ----------
function Apply-Pet([string]$id) {
  $script:petId = $id
  $idle = Get-Frame 'idle'
  if ($idle) { $pet.Source = $idle }
  foreach ($b in @(@('PickQiqi', 'mingqiqi'), @('PickLingling', 'minglingling'), @('PickBaobao', 'mingbaobao'))) {
    $border = $win.FindName($b[0])
    if ($id -eq $b[1]) {
      $border.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#E3F1E5'))
      $border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#43A047'))
      $border.BorderThickness = '2'
    } else {
      $border.Background = [System.Windows.Media.Brushes]::Transparent
      $border.BorderBrush = [System.Windows.Media.Brushes]::Transparent
      $border.BorderThickness = '1'
    }
  }
}

# ---------- 打开网页 ----------
function Open-Current {
  $it = if ($script:idx -ge 0) { $items[$script:idx] } else { $items[0] }
  $url = $it.url
  if (-not $url) { $url = $SpotUrl[$it.spot] }
  if (-not $url) { Write-PetLog "没有该景点链接: $($it.spot)"; return }
  try { Start-Process $url } catch { Write-PetLog "打开链接失败: $($_.Exception.Message)" }
}

# ---------- 知识库窗口 ----------
function New-Brush([string]$hex) {
  return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex)))
}

$script:KbXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="466" Height="588" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Microsoft YaHei">
  <!-- 不要 DropShadowEffect：半透明窗口下阴影会在圆角处糊成一圈灰边 -->
  <Border CornerRadius="16" Background="#FFFFFF" BorderBrush="#E3EAE4" BorderThickness="1" SnapsToDevicePixels="True">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="54"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="36"/>
      </Grid.RowDefinitions>

      <Grid x:Name="KbTitleBar" Grid.Row="0" Background="Transparent" Margin="18,0,10,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="6" Height="6" CornerRadius="3" Background="#2F6B45" VerticalAlignment="Center" Margin="0,0,9,0"/>
          <TextBlock Text="知识库" FontSize="15" FontWeight="Bold" Foreground="#16241C" VerticalAlignment="Center"/>
          <TextBlock Text="本地检索 · 不联网" FontSize="10" Foreground="#94A398" VerticalAlignment="Center" Margin="8,2,0,0"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border x:Name="KbModel" Height="22" CornerRadius="7" Background="#F5F9F5" BorderBrush="#E3EAE4"
                  BorderThickness="1" Padding="9,0,9,0" Margin="0,0,8,0" VerticalAlignment="Center" Cursor="Hand">
            <TextBlock x:Name="KbModelText" Text="模型 · 关" FontSize="10" Foreground="#8C9A90"
                       VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Border>
          <Border x:Name="KbClose" Width="30" Height="30" CornerRadius="8" Background="Transparent"
                  VerticalAlignment="Center" Cursor="Hand">
            <TextBlock Text="✕" FontSize="13" Foreground="#8A978D" HorizontalAlignment="Center"
                       VerticalAlignment="Center" IsHitTestVisible="False"/>
          </Border>
        </StackPanel>
      </Grid>

      <Border Grid.Row="1" Margin="14,0,14,10" CornerRadius="12" Background="#F5F9F5" Padding="13,10,13,10">
        <StackPanel>
          <Grid>
            <!-- 点这行可以收起/展开文件夹列表；列表限高 126px，绑再多也不会把结果区挤没 -->
            <!-- 整行做成浅绿胶囊：箭头原来只有 10px，糊在灰字里根本看不出能点 -->
            <Border x:Name="KbFoldHead" VerticalAlignment="Center" HorizontalAlignment="Left"
                    CornerRadius="8" Background="#CFE9D6" BorderBrush="#A5D2B6" BorderThickness="1"
                    Padding="9,5,11,5" Cursor="Hand">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="KbFoldArrow" Text="▼" FontSize="15" Foreground="#1B5B37"
                           FontWeight="Bold" VerticalAlignment="Center" Margin="0,0,7,0"/>
                <TextBlock x:Name="KbFolderLabel" Text="还没绑定文件夹" FontSize="12" Foreground="#22382B"
                           FontWeight="SemiBold" VerticalAlignment="Center"/>
                <TextBlock x:Name="KbFoldHint" Text="收起" FontSize="10.5" Foreground="#4C7D5E"
                           VerticalAlignment="Center" Margin="8,1,0,0"/>
              </StackPanel>
            </Border>
            <!-- 绑定文件夹：实心墨绿胶囊，和「检索」按钮同色系；白底灰边那种像系统默认按钮，太小太糊 -->
            <Border x:Name="KbAdd" HorizontalAlignment="Right" VerticalAlignment="Center" Height="30"
                    CornerRadius="9" Background="#2F6B45" BorderBrush="#26593A" BorderThickness="1"
                    Padding="11,0,13,0" Cursor="Hand">
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="＋" FontSize="12" FontWeight="Bold" Foreground="#BFE3CB"
                           VerticalAlignment="Center" Margin="0,0,5,0" IsHitTestVisible="False"/>
                <TextBlock Text="绑定文件夹" FontSize="11" FontWeight="SemiBold" Foreground="White"
                           VerticalAlignment="Center" IsHitTestVisible="False"/>
              </StackPanel>
            </Border>
          </Grid>
          <ScrollViewer x:Name="KbRootScroll" MaxHeight="126" Margin="0,7,0,0" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="KbRootList"/>
          </ScrollViewer>
        </StackPanel>
      </Border>

      <Border Grid.Row="2" Margin="14,0,14,10" CornerRadius="10" Background="#FFFFFF"
              BorderBrush="#E2EAE3" BorderThickness="1" Padding="12,0,5,0" Height="42">
        <Grid>
          <TextBox x:Name="KbQuery" BorderThickness="0" Background="Transparent" FontSize="13"
                   Foreground="#16241C" VerticalAlignment="Center" VerticalContentAlignment="Center"
                   CaretBrush="#2F6B45"/>
          <TextBlock x:Name="KbPlaceholder" Text="问点什么，比如：三元区有哪些景点" FontSize="11.5"
                     Foreground="#B3BEB6" VerticalAlignment="Center" IsHitTestVisible="False"/>
          <Border x:Name="KbGo" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="7"
                  Background="#2F6B45" Height="30" Padding="15,0,15,0" Cursor="Hand" Margin="0,0,1,0">
            <TextBlock Text="检索" FontSize="11" Foreground="White" VerticalAlignment="Center"/>
          </Border>
        </Grid>
      </Border>

      <ScrollViewer x:Name="KbScroll" Grid.Row="3" Margin="14,0,10,0" VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="KbResultList"/>
      </ScrollViewer>

      <Grid Grid.Row="4" Margin="16,0,14,0">
        <Border VerticalAlignment="Top" Height="1" Background="#EFF3F0" Margin="-2,0,-4,0"/>
        <TextBlock x:Name="KbStatus" VerticalAlignment="Center" FontSize="10.5" Foreground="#8C9A90"
                   TextTrimming="CharacterEllipsis" Text="绑定一个文件夹就能开始检索"/>
        <TextBlock x:Name="KbStat" HorizontalAlignment="Right" VerticalAlignment="Center"
                   FontSize="10.5" Foreground="#A2AEA6" Text=""
                   Background="Transparent"/>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

function Set-KbStatus([string]$text) {
  if (-not $script:KbWin) { return }
  $st = $script:KbWin.FindName('KbStatus')
  if ($st) { $st.Text = $text }
}

function Update-KbChip {
  $chip = $win.FindName('ChipKb')
  $txt = $win.FindName('ChipKbText')
  if (-not $chip -or -not $txt) { return }
  $n = @($script:KbRoots).Count
  if ($n -le 0) { $chip.Background = (New-Brush '#BFC7C1'); $txt.Text = '未绑定' }
  else { $chip.Background = (New-Brush '#43A047'); $txt.Text = "$n 个" }
}

function Get-KbRoots {
  $raw = Invoke-KbPython -ArgList @('--roots')
  $script:KbRoots = @()
  if ($raw) {
    try {
      $j = $raw | ConvertFrom-Json
      if ($j.ok -and $j.roots) { $script:KbRoots = @($j.roots) }
    } catch { Write-PetLog "kb: roots 解析失败 $($_.Exception.Message)" }
  }
  Update-KbChip
  return $script:KbRoots
}

# 把命中词标绿加粗：手工切段，避免 RegExp 对中文特殊字符出问题
function Add-Highlight([System.Windows.Controls.TextBlock]$tb, [string]$text, [string[]]$tokens, [double]$size, [string]$fg) {
  $tb.FontSize = $size
  $tb.TextWrapping = 'Wrap'
  $tb.LineHeight = [double]($size * 1.62)
  $tb.Foreground = (New-Brush $fg)
  $marks = @()
  foreach ($t in $tokens) {
    if (-not $t -or $t.Length -lt 1) { continue }
    $from = 0
    while ($from -lt $text.Length) {
      $i = $text.IndexOf($t, $from, [System.StringComparison]::OrdinalIgnoreCase)
      if ($i -lt 0) { break }
      $marks += , @($i, $t.Length)
      $from = $i + $t.Length
    }
  }
  if ($marks.Count -eq 0) { $tb.Inlines.Add((New-Object System.Windows.Documents.Run $text)); return }
  $marks = @($marks | Sort-Object { $_[0] })
  $pos = 0
  $hl = New-Brush '#2F6B45'
  $hlBg = New-Brush '#E3F2E7'
  foreach ($m in $marks) {
    $s = [int]$m[0]; $len = [int]$m[1]
    if ($s -lt $pos) { continue }
    if ($s -gt $pos) { $tb.Inlines.Add((New-Object System.Windows.Documents.Run ($text.Substring($pos, $s - $pos)))) }
    $r = New-Object System.Windows.Documents.Run ($text.Substring($s, $len))
    $r.FontWeight = 'Bold'
    $r.Foreground = $hl
    $r.Background = $hlBg
    $tb.Inlines.Add($r)
    $pos = $s + $len
  }
  if ($pos -lt $text.Length) { $tb.Inlines.Add((New-Object System.Windows.Documents.Run ($text.Substring($pos)))) }
}

function New-KbCard($hit, [string[]]$tokens) {
  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = (New-Object System.Windows.CornerRadius 10, 10, 10, 10)
  $border.Background = (New-Brush '#FFFFFF')
  # 用 1px 细描边代替阴影，圆角处不会糊出灰边
  $border.BorderBrush = (New-Brush '#E9F0EA')
  $border.BorderThickness = '1'
  $border.Padding = (New-Object System.Windows.Thickness 14, 10, 14, 12)
  $border.Margin = (New-Object System.Windows.Thickness 0, 0, 0, 7)
  $border.Cursor = 'Hand'

  $sp = New-Object System.Windows.Controls.StackPanel
  $head = New-Object System.Windows.Controls.TextBlock
  $head.FontSize = 11.5
  $head.Foreground = (New-Brush '#2F6B45')
  $head.FontWeight = 'Bold'
  $head.TextTrimming = 'CharacterEllipsis'
  $head.Text = [string]$hit.file
  # 第二跳的结果：标出是靠哪个编号/型号串过来的，否则用户看不懂它为什么在这
  if ($hit.hop -eq 2 -and $hit.bridge) {
    $titleRow = New-Object System.Windows.Controls.Grid
    $head.Margin = New-Object System.Windows.Thickness 0, 0, 96, 0
    $titleRow.Children.Add($head) | Out-Null
    $badge = New-Object System.Windows.Controls.Border
    $badge.CornerRadius = (New-Object System.Windows.CornerRadius 6, 6, 6, 6)
    $badge.Background = (New-Brush '#EDF6EF')
    $badge.Padding = (New-Object System.Windows.Thickness 6, 1, 6, 1)
    $badge.HorizontalAlignment = 'Right'
    $badge.VerticalAlignment = 'Center'
    $bt = New-Object System.Windows.Controls.TextBlock
    $bt.FontSize = 9.5
    $bt.Foreground = (New-Brush '#2F6B45')
    $bt.TextTrimming = 'CharacterEllipsis'
    $bt.Text = "第二跳 · 由 $($hit.bridge) 串到"
    $badge.Child = $bt
    $titleRow.Children.Add($badge) | Out-Null
    $sp.Children.Add($titleRow) | Out-Null
  } else {
    $sp.Children.Add($head) | Out-Null
  }

  $meta = New-Object System.Windows.Controls.TextBlock
  $meta.FontSize = 10
  $meta.Foreground = (New-Brush '#93A096')
  $meta.Margin = (New-Object System.Windows.Thickness 0, 2, 0, 5)
  $metaText = "第 $($hit.line) 行"
  if ($hit.heading) { $metaText = "$metaText · $($hit.heading)" }
  $meta.Text = $metaText
  $sp.Children.Add($meta) | Out-Null

  $body = New-Object System.Windows.Controls.TextBlock
  if ($hit.readable -eq $false) {
    # PDF / Word 不是纯文本，按行号回读只会拿到乱码，这里如实说明
    $fmt = if ($hit.format) { [string]$hit.format } else { '该格式' }
    $note = "这是 $fmt 文件，已建立索引，但没有可预览的纯文本。点卡片用系统程序打开。"
    Add-Highlight $body $note @() 11.2 '#7C8C82'
  } else {
    $text = [string]$hit.text
    if ($text.Length -gt 340) { $text = $text.Substring(0, 340) + ' …' }
    # 源文件是 md 的话，片段里全是 ** ## 这些标记，先清掉再高亮
    Add-Highlight $body (Get-TextNoMd $text) $tokens 11.6 '#3E4F44'
  }
  $sp.Children.Add($body) | Out-Null

  $border.Child = $sp
  $path = [string]$hit.path
  $line = [int]$hit.line
  # PowerShell 的 scriptblock 不自动闭包，事件里的局部变量会变 null —— 用 Tag 传值
  # 点卡片默认弹「这一段」的完整正文，不再直接把整份文档甩到 VS Code；
  # 想跳原文的话详情窗里有「在 VS Code 打开原文」
  $border.Tag = @{ path = $path; line = $line; hit = $hit; tokens = $tokens }
  $border.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#F7FBF8') })
  $border.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#FFFFFF') })
  $border.Add_MouseLeftButtonUp({
    param($s, $e)
    $t = $s.Tag
    if ($t -and $t.hit) { Show-KbDetail $t.hit @($t.tokens) }
  })
  return $border
}

function Open-KbFile([string]$path, [int]$line) {
  if (-not (Test-Path -LiteralPath $path)) { Set-KbStatus '原文件已被移动或删除'; return }
  try {
    $c = Get-Command code -ErrorObject SilentlyContinue
    if ($c) { Start-Process $c.Source -ArgumentList @('-g', "$path`:$line"); return }
  } catch { }
  try { Start-Process notepad.exe -ArgumentList "`"$path`"" } catch { Write-PetLog "kb: 打开文件失败 $($_.Exception.Message)" }
}

function Invoke-KbSearch {
  if (-not $script:KbWin) { return }
  $q = $script:KbWin.FindName('KbQuery').Text
  $list = $script:KbWin.FindName('KbResultList')
  $list.Children.Clear()
  if (-not $q -or $q.Trim().Length -eq 0) { Set-KbStatus '先输入要查的问题'; return }
  if (@($script:KbRoots).Count -eq 0) { Set-KbStatus '还没绑定文件夹，先点右上角绑定一个'; return }
  Set-KbStatus '检索中…'
  # --hops 2：第一跳 BM25 召回，第二跳拿命中里的单号/型号再捞一次
  $raw = Invoke-KbPython -ArgList @($q, '--limit', '8', '--hops', '2')
  if (-not $raw) { Set-KbStatus '检索器没跑起来（缺 python 或 tools\kb-search.py）'; return }
  try { $j = $raw | ConvertFrom-Json } catch { Set-KbStatus '返回内容异常'; Write-PetLog "kb: 输出非 JSON: $raw"; return }
  if (-not $j.ok) { Set-KbStatus ([string]$j.message); return }
  $hits = @($j.hits)
  $tokens = @($j.tokens)
  $bridges = @($j.bridges)
  # 检索器把「有什么好玩的」翻成了 景区 / 景点 / 旅游 这类正式说法，
  # 这些补充词也一并显示、一并高亮，不然用户只看到「三元区」会以为是玄学
  $intent = @($j.intent)
  if ($hits.Count -eq 0) {
    $list.Children.Add((New-KbCardHint "没找到相关内容。换个说法，或确认文件确实在这个文件夹里。")) | Out-Null
    Set-KbStatus ("关键词：" + ($tokens -join ' / ') + " · 0 条")
    return
  }
  $hl = @($tokens) + @($bridges) + @($intent)
  foreach ($h in $hits) { $list.Children.Add((New-KbCard $h $hl)) | Out-Null }
  $h1 = @($hits | Where-Object { $_.hop -eq 1 }).Count
  $h2 = $hits.Count - $h1
  if ($h2 -gt 0 -and $bridges.Count -gt 0) {
    Set-KbStatus ("命中 $h1 条 · 第二跳 +$h2（由 $($bridges[0]) 串到）")
  } else {
    $stat = "命中 $h1 条 · 关键词：" + ($tokens -join ' / ')
    if ($intent.Count -gt 0) { $stat += " ＋" + ($intent -join '/') }
    Set-KbStatus $stat
  }
  Write-PetLog "kb search: q=$q hits=$($hits.Count) hop1=$h1 hop2=$h2 tokens=$($tokens -join ',') intent=$($intent -join ',') bridges=$($bridges -join ',')"

  # 配了答案模型就再走一遍生成；没配就到此为止，只给原文
  $script:KbLastHits = $hits
  if (Get-LlmReady) {
    if (Start-KbAnswer $q $hits $list) {
      Set-KbStatus ("命中 $($hits.Count) 条 · 正在让 $($script:LlmCfg.answer.model) 读答案…")
    }
  }
}

# 底部右侧那行：索引库体积。偏大时变成可点的「可收缩」
function Update-KbStat {
  if (-not $script:KbWin) { return }
  $t = $script:KbWin.FindName('KbStat')
  if (-not $t) { return }
  $raw = Invoke-KbPython -ArgList @('--stats')
  if (-not $raw) { return }
  try { $j = $raw | ConvertFrom-Json } catch { return }
  if (-not $j.ok) { return }
  if ($j.suggest_vacuum) {
    $t.Text = "索引 $($j.size_mb) MB · 可收缩"
    $t.Foreground = (New-Brush '#B87400')
    $t.Cursor = 'Hand'
    $t.ToolTip = "其中有 $($j.wasted_mb) MB 是移除目录留下的空页，点这里回收"
    $t.Tag = 'vacuum'
  } else {
    $t.Text = "索引 $($j.size_mb) MB · $($j.documents) 文件"
    $t.Foreground = (New-Brush '#93A096')
    $t.Cursor = 'Arrow'
    $t.ToolTip = ''
    $t.Tag = ''
  }
}

function Invoke-KbVacuum {
  Set-KbStatus '正在收缩索引库…'
  $raw = Invoke-KbPython -ArgList @('--vacuum')
  if (-not $raw) { Set-KbStatus '收缩失败：检索器没跑起来'; return }
  try { $j = $raw | ConvertFrom-Json } catch { Set-KbStatus '收缩失败'; return }
  if (-not $j.ok) { Set-KbStatus '收缩失败'; return }
  Write-PetLog "kb vacuum: $($j.before_mb)MB -> $($j.after_mb)MB"
  Update-KbStat
  Set-KbStatus "索引库已收缩，释放 $($j.saved_mb) MB"
}

# 增量自查：改了文件但没重新索引，是本地知识库最常见的坑（问到的还是旧内容）
function Invoke-KbRefresh {
  if ($script:KbBusy) { return }
  if (@($script:KbRoots).Count -eq 0) { return }
  if (-not (Test-Path $script:SagExe)) { return }
  $raw = Invoke-KbPython -ArgList @('--changed')
  if (-not $raw) { return }
  try { $j = $raw | ConvertFrom-Json } catch { return }
  if (-not $j.ok -or -not $j.has_change) { return }
  $root = [string](@($script:KbRoots)[0].path)
  if (-not $root -or -not (Test-Path -LiteralPath $root)) { return }
  Write-PetLog "kb: 发现 $($j.modified) 个文件有改动，后台重建索引 root=$root"
  Set-KbStatus '检测到文件有改动，正在更新索引…'
  $script:KbBusy = $true
  $log = Join-Path $env:TEMP 'sanming-kb-sag.log'
  try {
    $script:KbProc = Start-Process -FilePath $script:SagExe `
      -ArgumentList @('add', $root, '--timeout', '600') `
      -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') -PassThru
  } catch {
    Write-PetLog "kb: 增量索引失败 $($_.Exception.Message)"
    $script:KbBusy = $false
    return
  }
  if ($script:KbPoll) { $script:KbPoll.Start() }
}

function New-KbCardHint([string]$text) {
  $tb = New-Object System.Windows.Controls.TextBlock
  $tb.Text = $text
  $tb.FontSize = 11.5
  $tb.Foreground = (New-Brush '#97A49A')
  $tb.TextWrapping = 'Wrap'
  $tb.TextAlignment = 'Center'
  $tb.Margin = (New-Object System.Windows.Thickness 10, 40, 10, 0)
  return $tb
}

function Render-KbRoots {
  if (-not $script:KbWin) { return }
  $list = $script:KbWin.FindName('KbRootList')
  $label = $script:KbWin.FindName('KbFolderLabel')
  $list.Children.Clear()
  $roots = @($script:KbRoots)
  $total = 0
  foreach ($r in $roots) { $total += [int]$r.files }
  if ($roots.Count -eq 0) {
    $label.Text = '还没绑定文件夹'
    return
  }
  $label.Text = "$($roots.Count) 个文件夹 · $total 个文件已索引"
  foreach ($r in $roots) {
    # 每个文件夹做成一条白底圆角行，和上面的折叠胶囊、右边的绑定按钮形成统一的卡片感
    $rowBox = New-Object System.Windows.Controls.Border
    $rowBox.CornerRadius = (New-Object System.Windows.CornerRadius 7, 7, 7, 7)
    $rowBox.Background = (New-Brush '#FFFFFF')
    $rowBox.BorderBrush = (New-Brush '#E9F0EB')
    $rowBox.BorderThickness = (New-Object System.Windows.Thickness 1, 1, 1, 1)
    $rowBox.Padding = (New-Object System.Windows.Thickness 9, 5, 7, 5)
    $rowBox.Margin = (New-Object System.Windows.Thickness 0, 0, 0, 4)
    $row = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $c2.Width = [System.Windows.GridLength]::Auto
    $row.ColumnDefinitions.Add($c1); $row.ColumnDefinitions.Add($c2)

    $name = New-Object System.Windows.Controls.TextBlock
    $name.FontSize = 11
    $name.Foreground = (New-Brush '#3A4C40')
    $name.TextTrimming = 'CharacterEllipsis'
    $name.VerticalAlignment = 'Center'
    $name.Text = "▪ " + [string]$r.name
    $name.ToolTip = [string]$r.path
    if ($r.status -ne 'ready') { $name.Text = "▪ " + [string]$r.name + "（索引中）" }
    [System.Windows.Controls.Grid]::SetColumn($name, 0)
    $row.Children.Add($name) | Out-Null

    # 移除做成小胶囊，比裸文字整齐
    $del = New-Object System.Windows.Controls.Border
    $del.CornerRadius = (New-Object System.Windows.CornerRadius 6, 6, 6, 6)
    $del.Background = (New-Brush '#FBEFEC')
    $del.BorderBrush = (New-Brush '#F2DCD4')
    $del.BorderThickness = (New-Object System.Windows.Thickness 1, 1, 1, 1)
    $del.Padding = (New-Object System.Windows.Thickness 8, 2, 8, 2)
    $del.Cursor = 'Hand'
    $del.VerticalAlignment = 'Center'
    $dt = New-Object System.Windows.Controls.TextBlock
    $dt.Text = '移除'
    $dt.FontSize = 10
    $dt.Foreground = (New-Brush '#A0563F')
    $del.Child = $dt
    $p = [string]$r.path
    $del.Tag = $p
    $del.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#F6E4DF') })
    $del.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#FBEFEC') })
    $del.Add_MouseLeftButtonUp({ param($s, $e) Remove-KbFolder ([string]$s.Tag) })
    [System.Windows.Controls.Grid]::SetColumn($del, 1)
    $row.Children.Add($del) | Out-Null
    $rowBox.Child = $row
    $list.Children.Add($rowBox) | Out-Null
  }
}

function Add-KbFolder {
  if (-not (Test-Path $script:SagExe)) { Set-KbStatus '缺 tools\sag\sag.exe'; return }
  # 用系统新式「选择文件夹」对话框（带地址栏，可直接粘贴路径），
  # 老的 FolderBrowserDialog 没有地址栏，选深层目录很费劲
  $path = $null
  $hidePet = $false
  try {
    $dlg = New-Object Microsoft.Win32.OpenFolderDialog
    $dlg.Title = '选一个文件夹作为知识库'
    $dlg.Multiselect = $false
    # 宠物是置顶窗口，会压在文件夹对话框右下角（正好挡着「选择文件夹」按钮）
    $script:suppressShow = $true
    try { if ($win.IsVisible) { $win.Hide(); $hidePet = $true } } catch { }
    Start-Sleep -Milliseconds 200
    if ($script:KbWin) { $ok = $dlg.ShowDialog($script:KbWin) } else { $ok = $dlg.ShowDialog() }
    if ($ok) { $path = [string]$dlg.FolderName }
  } catch {
    Write-PetLog "kb: 选择文件夹失败 $($_.Exception.Message)"
    Set-KbStatus '打开文件夹选择框失败'
    return
  } finally {
    $script:suppressShow = $false
    if ($hidePet) {
      try { $win.Show(); Update-Position; Set-AlwaysOnTop } catch { }
    }
  }
  if ([string]::IsNullOrWhiteSpace($path)) { return }
  # 防误绑：桌面/下载/整个用户目录/盘根 动辄上万文件，会把索引拖死
  $norm = ''
  try { $norm = [System.IO.Path]::GetFullPath($path).TrimEnd('\').ToLower() } catch { $norm = $path.ToLower() }
  $homeDir = $env:USERPROFILE.ToLower().TrimEnd('\')
  $bigDirs = @("$homeDir\desktop", "$homeDir\downloads", "$homeDir\documents", "$homeDir\pictures", $homeDir, 'c:\users', 'c:\windows', 'c:\')
  if ($bigDirs -contains $norm) {
    $ans = [System.Windows.MessageBox]::Show(
      "这个文件夹通常有成千上万个文件，全量索引要很久，也会吃掉不少磁盘。`n`n确定要把它作为知识库吗？",
      '文件夹有点大', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { Set-KbStatus '已取消，可以选个更小的子文件夹'; return }
  }
  Set-KbStatus "正在建索引：$path"
  $script:KbBusy = $true
  $log = Join-Path $env:TEMP 'sanming-kb-sag.log'
  try {
    $script:KbProc = Start-Process -FilePath $script:SagExe `
      -ArgumentList @('add', $path, '--timeout', '600') `
      -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') -PassThru
    Write-PetLog "kb add: $path pid=$($script:KbProc.Id)"
  } catch {
    Set-KbStatus "启动索引失败：$($_.Exception.Message)"
    $script:KbBusy = $false
    return
  }
  if ($script:KbPoll) { $script:KbPoll.Start() }
}

function Remove-KbFolder([string]$path) {
  # 空路径绝不能往下传：sag remove 不带参数会指向当前目录
  if ([string]::IsNullOrWhiteSpace($path)) { Write-PetLog 'kb: 忽略空路径的移除'; return }
  if (-not (Test-Path $script:SagExe)) { return }
  try {
    [void](Start-Process -FilePath $script:SagExe -ArgumentList @('remove', $path) -WindowStyle Hidden -PassThru)
    Write-PetLog "kb remove: $path"
    if ($script:KbPoll) { $script:KbPoll.Start() }
  } catch { Set-KbStatus "移除失败：$($_.Exception.Message)" }
}

function Build-KbWindow {
  $kb = [System.Windows.Markup.XamlReader]::Parse($script:KbXaml)
  $script:KbWin = $kb

  # 只在顶部 54px 标题区允许拖动，避免点输入框时把整窗拖走
  # 拖拽会吃掉鼠标，所以 ✕ 必须走 MouseLeftButtonDown 并标记 Handled，否则点不动
  $kb.Add_MouseLeftButtonDown({
    param($s, $e)
    try {
      $pos = $e.GetPosition($script:KbWin)
      if ($pos.Y -le 54) { $script:KbWin.DragMove() }
    } catch { }
  })
  $close = $kb.FindName('KbClose')
  $close.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:KbWin.Hide()
    if ($script:MdlWin -and $script:MdlWin.IsVisible) { try { $script:MdlWin.Hide() } catch { } }
    if ($script:DtWin -and $script:DtWin.IsVisible) { try { $script:DtWin.Hide() } catch { } }
  })
  $close.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#F2F5F3') })
  $close.Add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })

  # 文件夹面板折叠
  $script:KbFoldOpen = $true
  $foldHead = $kb.FindName('KbFoldHead')
  if ($foldHead) {
    # 直接在 Down 里切：这个 Border 在 Down 里吃掉事件之后，Up 不稳（窄胶囊上尤其容易丢）
    $foldHead.Add_MouseLeftButtonDown({
      param($s, $e)
      $e.Handled = $true
      try {
        $script:KbFoldOpen = -not [bool]$script:KbFoldOpen
        $sc = $script:KbWin.FindName('KbRootScroll')
        if ($sc) { $sc.Visibility = if ($script:KbFoldOpen) { 'Visible' } else { 'Collapsed' } }
        $ar = $script:KbWin.FindName('KbFoldArrow')
        if ($ar) { $ar.Text = if ($script:KbFoldOpen) { '▼' } else { '▶' } }
        $hd = $script:KbWin.FindName('KbFoldHint')
        if ($hd) { $hd.Text = if ($script:KbFoldOpen) { '收起' } else { '展开' } }
        Write-PetLog "kb fold: open=$($script:KbFoldOpen)"
      } catch {
        Write-PetLog ("kb fold ERR: " + $_.Exception.Message)
      }
    })
    $foldHead.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
    $foldHead.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#B6DEC4') })
    $foldHead.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#CFE9D6') })
  }

  $mdlBtn = $kb.FindName('KbModel')
  if ($mdlBtn) {
    # Down 里吃掉事件之后 WPF 不再派发 Up，所以按钮动作一律写在 Down 里
    $mdlBtn.Add_MouseLeftButtonDown({
      param($s, $e)
      $e.Handled = $true
      Show-ModelWindow
    })
    $mdlBtn.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
    $mdlBtn.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#EBF3ED') })
    $mdlBtn.Add_MouseLeave({ param($s, $e) Update-KbModelChip })
  }

  $add = $kb.FindName('KbAdd')
  $add.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Add-KbFolder
  })
  $add.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
  $add.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#4C9463'); $s.BorderBrush = (New-Brush '#4C9463') })
  $add.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#2F6B45'); $s.BorderBrush = (New-Brush '#26593A') })

  $go = $kb.FindName('KbGo')
  $go.Add_MouseLeftButtonUp({ param($s, $e) Invoke-KbSearch })
  $go.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#3B7F53') })
  $go.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#2F6B45') })

  # 索引体积那行：只有标了 vacuum 才响应点击，避免误触
  $kb.FindName('KbStat').Add_MouseLeftButtonUp({
    param($s, $e)
    if ($s.Tag -eq 'vacuum') { Invoke-KbVacuum }
  })

  $q = $kb.FindName('KbQuery')
  $ph = $kb.FindName('KbPlaceholder')
  $q.Add_TextChanged({
    param($s, $e)
    $ph2 = $script:KbWin.FindName('KbPlaceholder')
    $ph2.Visibility = if ($s.Text.Length -gt 0) { 'Collapsed' } else { 'Visible' }
  })
  $q.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
      $e.Handled = $true
      Invoke-KbSearch
    }
  })

  # 索引进程轮询
  $script:KbPoll = New-Object System.Windows.Threading.DispatcherTimer
  $script:KbPoll.Interval = [TimeSpan]::FromMilliseconds(1200)
  $script:KbPoll.Add_Tick({
    $done = $false
    if ($script:KbProc) { $done = $script:KbProc.HasExited } else { $done = $true }
    if (-not $done) { return }
    $script:KbPoll.Stop()
    $script:KbProc = $null
    $script:KbBusy = $false
    $script:KbRoots = @(Get-KbRoots)
    Render-KbRoots
    $n = @($script:KbRoots).Count
    $files = 0
    foreach ($r in $script:KbRoots) { $files += [int]$r.files }
    Set-KbStatus "索引就绪 · $n 个文件夹 / $files 个文件"
    Write-PetLog "kb: 索引完成 roots=$n files=$files"
  })
}

# 知识库窗口贴着宠物左侧放（放不下改右侧），纵向与浮窗底部对齐
function Reposition-KbWindow {
  if (-not $script:KbWin) { return }
  $kbW = 466.0; $kbH = 588.0
  $fl = [double]$win.Left
  $ft = [double]$win.Top
  $fw = [double]$win.Width
  $fh = [double]$win.Height
  $left = $fl - $kbW - 10
  if ($left -lt 16) { $left = $fl + $fw + 10 }
  if ($left + $kbW -gt 3424) { $left = 3424 - $kbW }
  if ($left -lt 8) { $left = 8 }
  $top = $ft + $fh - $kbH
  if ($top -lt 12) { $top = 12 }
  if ($top + $kbH -gt 1380) { $top = 1380 - $kbH }
  $script:KbWin.Left = $left
  $script:KbWin.Top = $top
}

function Show-KbWindow {
  if (-not $script:KbWin) { Build-KbWindow }
  if (-not $script:KbWin.IsVisible) {
    $script:KbRoots = @(Get-KbRoots)
    Render-KbRoots
    Reposition-KbWindow
    $script:KbWin.Show()
    try { $script:KbWin.Activate() } catch { }
    $q = $script:KbWin.FindName('KbQuery')
    $q.Focus() | Out-Null
    $q.SelectAll() | Out-Null
    Write-PetLog "kb: 打开知识库窗口 pos=$([int]$script:KbWin.Left),$([int]$script:KbWin.Top)"
    $n = @($script:KbRoots).Count
    if ($n -eq 0) { Set-KbStatus '绑定一个文件夹就能开始检索' }
    else {
      $files = 0
      foreach ($r in $script:KbRoots) { $files += [int]$r.files }
      Set-KbStatus "$n 个文件夹 / $files 个文件已索引"
    }
    Update-KbStat
    Update-KbModelChip
  } else {
    $script:KbWin.Activate()
  }
}

$script:MdlXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" Height="740" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Microsoft YaHei">
  <Border CornerRadius="16" Background="#FFFFFF" BorderBrush="#E3EAE4" BorderThickness="1" SnapsToDevicePixels="True">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="54"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="56"/>
      </Grid.RowDefinitions>

      <Grid x:Name="MdlTitleBar" Grid.Row="0" Background="Transparent" Margin="20,0,14,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="6" Height="6" CornerRadius="3" Background="#2F6B45" VerticalAlignment="Center" Margin="0,0,9,0"/>
          <TextBlock Text="模型设置" FontSize="15" FontWeight="Bold" Foreground="#16241C" VerticalAlignment="Center"/>
          <TextBlock x:Name="MdlSub" Text="仅检索" FontSize="10" Foreground="#94A398" VerticalAlignment="Center" Margin="8,2,0,0"/>
        </StackPanel>
        <Border x:Name="MdlClose" Width="30" Height="30" CornerRadius="8" Background="Transparent"
                HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand">
          <TextBlock Text="✕" FontSize="13" Foreground="#8A978D" HorizontalAlignment="Center"
                     VerticalAlignment="Center" IsHitTestVisible="False"/>
        </Border>
      </Grid>

      <Border Grid.Row="1" Margin="16,0,16,12" CornerRadius="10" Background="#F5F9F5" Padding="12,9,12,9">
        <TextBlock FontSize="10.8" Foreground="#5D6E63" TextWrapping="Wrap" LineHeight="16"
                   Text="检索这一步永远在本机跑（BM25 + 两跳），不联网、也不需要模型。下面两块是可选增强：上面决定要不要让模型把命中的原文读成一段答案；下面决定要不要把 SAG 的 JEV 决策模型接进来。两个都不配，浮窗照常能用。"/>
      </Border>

      <ScrollViewer Grid.Row="2" Margin="16,0,10,0" VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="0,0,6,8">

          <Border CornerRadius="12" Background="#FFFFFF" BorderBrush="#E9F0EA" BorderThickness="1" Padding="14,12,14,13">
            <StackPanel>
              <Grid>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="答案模型" FontSize="12.5" FontWeight="Bold" Foreground="#22382B"/>
                  <TextBlock Text="OpenAI 兼容" FontSize="9.5" Foreground="#9DA9A1" Margin="7,2,0,0"/>
                </StackPanel>
                <Border x:Name="MdlAnsChip" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="8"
                        Background="#BFC7C1" Padding="10,3,10,3" Cursor="Hand">
                  <TextBlock x:Name="MdlAnsChipText" Text="关" FontSize="10.5" Foreground="White"/>
                </Border>
              </Grid>
              <TextBlock Text="配了它，检索完会在最上面多一张「答案」卡；答案里每条事实都必须标原文编号。" FontSize="10"
                         Foreground="#8C9A90" Margin="0,5,0,0" TextWrapping="Wrap"/>

              <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="64"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="服务地址" FontSize="10.5" Foreground="#7C8A80" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Height="32" CornerRadius="8" Background="#FBFDFC"
                        BorderBrush="#E2EAE3" BorderThickness="1">
                  <TextBox x:Name="MdlUrl" BorderThickness="0" Background="Transparent" FontSize="11.5"
                           Foreground="#22382B" Padding="9,0,9,0" VerticalContentAlignment="Center"
                           CaretBrush="#2F6B45"/>
                </Border>
              </Grid>

              <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="64"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="模型名" FontSize="10.5" Foreground="#7C8A80" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Height="32" CornerRadius="8" Background="#FBFDFC"
                        BorderBrush="#E2EAE3" BorderThickness="1">
                  <TextBox x:Name="MdlModel" BorderThickness="0" Background="Transparent" FontSize="11.5"
                           Foreground="#22382B" Padding="9,0,9,0" VerticalContentAlignment="Center"
                           CaretBrush="#2F6B45"/>
                </Border>
              </Grid>

              <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="64"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="密钥" FontSize="10.5" Foreground="#7C8A80" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Height="32" CornerRadius="8" Background="#FBFDFC"
                        BorderBrush="#E2EAE3" BorderThickness="1">
                  <PasswordBox x:Name="MdlKey" BorderThickness="0" Background="Transparent" FontSize="11.5"
                               Foreground="#22382B" Padding="9,0,9,0" VerticalContentAlignment="Center"
                               CaretBrush="#2F6B45"/>
                </Border>
              </Grid>

              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Border x:Name="MdlP1" CornerRadius="6" Background="#F3F8F4" Padding="8,3,8,3" Margin="0,0,6,0" Cursor="Hand">
                  <TextBlock Text="Ollama 本地" FontSize="9.8" Foreground="#3C6B4E"/>
                </Border>
                <Border x:Name="MdlP2" CornerRadius="6" Background="#F3F8F4" Padding="8,3,8,3" Margin="0,0,6,0" Cursor="Hand">
                  <TextBlock Text="LM Studio" FontSize="9.8" Foreground="#3C6B4E"/>
                </Border>
                <Border x:Name="MdlP3" CornerRadius="6" Background="#F3F8F4" Padding="8,3,8,3" Cursor="Hand">
                  <TextBlock Text="DeepSeek 云" FontSize="9.8" Foreground="#3C6B4E"/>
                </Border>
              </StackPanel>

              <Grid Margin="0,10,0,0">
                <Border x:Name="MdlTest" Height="28" CornerRadius="7" Background="#2F6B45" Padding="13,0,13,0"
                        HorizontalAlignment="Left" Cursor="Hand">
                  <TextBlock Text="测试连接" FontSize="10.5" Foreground="White" VerticalAlignment="Center"/>
                </Border>
                <TextBlock x:Name="MdlTestMsg" FontSize="10" Foreground="#8C9A90" Margin="78,0,0,0"
                           VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </Grid>
            </StackPanel>
          </Border>

          <Border CornerRadius="12" Background="#FFFFFF" BorderBrush="#E9F0EA" BorderThickness="1"
                  Padding="14,12,14,13" Margin="0,10,0,0">
            <StackPanel>
              <Grid>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                  <TextBlock Text="JEV 语义增强" FontSize="12.5" FontWeight="Bold" Foreground="#22382B"/>
                  <TextBlock Text="SAG 官方决策模型" FontSize="9.5" Foreground="#9DA9A1" Margin="7,2,0,0"/>
                </StackPanel>
                <Border x:Name="MdlJevChip" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="8"
                        Background="#BFC7C1" Padding="10,3,10,3">
                  <TextBlock x:Name="MdlJevChipText" Text="未配置" FontSize="10" Foreground="White"/>
                </Border>
              </Grid>
              <TextBlock FontSize="10" Foreground="#8C9A90" Margin="0,5,0,0" TextWrapping="Wrap" LineHeight="15"
                         Text="JEV 要你自己下载部署（它是个小的相关性打分模型，不是聊天模型）。填好点「写入 SAG」，会改 SAG 的全局配置（不只影响本浮窗），之后命令行 sag 就能做语义问答。浮窗内的检索走本地 BM25 两跳，不依赖它，配不配都一样用。"/>

              <Grid Margin="0,10,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="64"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="服务地址" FontSize="10.5" Foreground="#7C8A80" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Height="32" CornerRadius="8" Background="#FBFDFC"
                        BorderBrush="#E2EAE3" BorderThickness="1">
                  <TextBox x:Name="MdlJevUrl" BorderThickness="0" Background="Transparent" FontSize="11.5"
                           Foreground="#22382B" Padding="9,0,9,0" VerticalContentAlignment="Center"
                           CaretBrush="#2F6B45"/>
                </Border>
              </Grid>

              <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="64"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="模型名" FontSize="10.5" Foreground="#7C8A80" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Height="32" CornerRadius="8" Background="#FBFDFC"
                        BorderBrush="#E2EAE3" BorderThickness="1">
                  <TextBox x:Name="MdlJevModel" BorderThickness="0" Background="Transparent" FontSize="11.5"
                           Foreground="#22382B" Padding="9,0,9,0" VerticalContentAlignment="Center"
                           CaretBrush="#2F6B45"/>
                </Border>
              </Grid>

              <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="64"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="鉴权" FontSize="10.5" Foreground="#7C8A80" VerticalAlignment="Center"/>
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                  <Border x:Name="MdlAuthNone" CornerRadius="6" Background="#2F6B45" BorderBrush="#2F6B45"
                          BorderThickness="1" Padding="10,3,10,3" Margin="0,0,6,0" Cursor="Hand">
                    <TextBlock x:Name="MdlAuthNoneText" Text="无鉴权" FontSize="9.8" Foreground="White"/>
                  </Border>
                  <Border x:Name="MdlAuthBearer" CornerRadius="6" Background="#F5F9F5" BorderBrush="#E3EAE4"
                          BorderThickness="1" Padding="10,3,10,3" Cursor="Hand">
                    <TextBlock x:Name="MdlAuthBearerText" Text="Bearer" FontSize="9.8" Foreground="#3C6B4E"/>
                  </Border>
                </StackPanel>
              </Grid>

              <Grid Margin="0,8,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="64"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="密钥" FontSize="10.5" Foreground="#7C8A80" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Height="32" CornerRadius="8" Background="#FBFDFC"
                        BorderBrush="#E2EAE3" BorderThickness="1">
                  <PasswordBox x:Name="MdlJevKey" BorderThickness="0" Background="Transparent" FontSize="11.5"
                               Foreground="#22382B" Padding="9,0,9,0" VerticalContentAlignment="Center"
                               CaretBrush="#2F6B45"/>
                </Border>
              </Grid>

              <Grid Margin="0,10,0,0">
                <Border x:Name="MdlJevGo" Height="28" CornerRadius="7" Background="#FFFFFF" BorderBrush="#CBDCD0"
                        BorderThickness="1" Padding="13,0,13,0" HorizontalAlignment="Left" Cursor="Hand">
                  <TextBlock Text="写入 SAG" FontSize="10.5" Foreground="#2F6B45" VerticalAlignment="Center"/>
                </Border>
                <TextBlock x:Name="MdlJevMsg" FontSize="10" Foreground="#8C9A90" Margin="78,0,0,0"
                           VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </Grid>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <Grid Grid.Row="3" Margin="20,0,16,0">
        <Border VerticalAlignment="Top" Height="1" Background="#EFF3F0" Margin="-4,0,-2,0"/>
        <TextBlock x:Name="MdlFoot" Text="存在 data\模型.json（里面是明文密钥，别把整个目录发给别人）"
                   FontSize="9.8" Foreground="#A2AEA6" VerticalAlignment="Center"/>
        <Border x:Name="MdlSave" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="7"
                Background="#2F6B45" Height="30" Padding="18,0,18,0" Cursor="Hand">
          <TextBlock Text="保存" FontSize="11" Foreground="White" VerticalAlignment="Center"/>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

function Fill-MdlFromCfg {
  $mw = $script:MdlWin
  if (-not $mw) { return }
  $a = $script:LlmCfg.answer
  $j = $script:LlmCfg.jev
  $mw.FindName('MdlUrl').Text = [string]$a.baseUrl
  $mw.FindName('MdlModel').Text = [string]$a.model
  $mw.FindName('MdlKey').Password = [string]$a.apiKey
  $mw.FindName('MdlJevUrl').Text = [string]$j.url
  $mw.FindName('MdlJevModel').Text = [string]$j.model
  $mw.FindName('MdlJevKey').Password = [string]$j.key
  $mw.FindName('MdlTestMsg').Text = ''
  $mw.FindName('MdlJevMsg').Text = ''
}

function Sync-MdlToCfg {
  $mw = $script:MdlWin
  if (-not $mw) { return }
  $a = $script:LlmCfg.answer
  $j = $script:LlmCfg.jev
  $a.baseUrl = ([string]$mw.FindName('MdlUrl').Text).Trim()
  $a.model = ([string]$mw.FindName('MdlModel').Text).Trim()
  $a.apiKey = ([string]$mw.FindName('MdlKey').Password).Trim()
  $j.url = ([string]$mw.FindName('MdlJevUrl').Text).Trim()
  $j.model = ([string]$mw.FindName('MdlJevModel').Text).Trim()
  $j.key = ([string]$mw.FindName('MdlJevKey').Password).Trim()
}

function Update-MdlChips {
  $mw = $script:MdlWin
  if (-not $mw) { return }
  $a = $script:LlmCfg.answer
  $c = $mw.FindName('MdlAnsChip')
  $ct = $mw.FindName('MdlAnsChipText')
  if ($c -and $ct) {
    if ([bool]$a.enabled) { $c.Background = (New-Brush '#2F6B45'); $ct.Text = '开' }
    else { $c.Background = (New-Brush '#BFC7C1'); $ct.Text = '关' }
  }
  $sub = $mw.FindName('MdlSub')
  if ($sub) {
    if (Get-LlmReady) { $sub.Text = "已接入 · $($a.model)"; $sub.Foreground = (New-Brush '#2F6B45') }
    else { $sub.Text = '仅检索'; $sub.Foreground = (New-Brush '#94A398') }
  }
  $auth = ([string]$script:LlmCfg.jev.auth).ToLower()
  foreach ($pair in @(@('MdlAuthNone', 'MdlAuthNoneText', '无鉴权'), @('MdlAuthBearer', 'MdlAuthBearerText', 'Bearer'))) {
    $b = $mw.FindName($pair[0])
    $t = $mw.FindName($pair[1])
    if (-not $b -or -not $t) { continue }
    $on = ($pair[2] -eq 'Bearer' -and $auth -eq 'bearer') -or ($pair[2] -eq '无鉴权' -and $auth -ne 'bearer')
    if ($on) { $b.Background = (New-Brush '#2F6B45'); $b.BorderBrush = (New-Brush '#2F6B45'); $t.Foreground = [System.Windows.Media.Brushes]::White }
    else { $b.Background = (New-Brush '#F5F9F5'); $b.BorderBrush = (New-Brush '#E3EAE4'); $t.Foreground = (New-Brush '#3C6B4E') }
  }
  $jc = $mw.FindName('MdlJevChip')
  $jt = $mw.FindName('MdlJevChipText')
  if ($jc -and $jt) {
    $ok = Get-JevConfigured
    if ($ok -eq $true) { $jc.Background = (New-Brush '#2F6B45'); $jt.Text = '已配置' }
    elseif ($ok -eq $false) { $jc.Background = (New-Brush '#BFC7C1'); $jt.Text = '未配置' }
    else { $jc.Background = (New-Brush '#D7DDD8'); $jt.Text = '查不到' }
  }
}

function Update-KbModelChip {
  if (-not $script:KbWin) { return }
  $t = $script:KbWin.FindName('KbModelText')
  $b = $script:KbWin.FindName('KbModel')
  if (-not $t) { return }
  if (Get-LlmReady) {
    $t.Text = '模型 · 开'
    $t.Foreground = (New-Brush '#2F6B45')
    if ($b) { $b.Background = (New-Brush '#EDF6EF'); $b.BorderBrush = (New-Brush '#CFE3D5') }
  } else {
    $t.Text = '模型 · 关'
    $t.Foreground = (New-Brush '#8C9A90')
    if ($b) { $b.Background = (New-Brush '#F5F9F5'); $b.BorderBrush = (New-Brush '#E3EAE4') }
  }
}

function Get-MdlModelsUri([string]$base) {
  $u = ([string]$base).Trim().TrimEnd('/')
  if ($u -match '/chat/completions$') { return ($u -replace '/chat/completions$', '/models') }
  if ($u -match '/v\d+$') { return "$u/models" }
  return "$u/v1/models"
}

function Test-LlmConn {
  Sync-MdlToCfg
  $msg = $script:MdlWin.FindName('MdlTestMsg')
  $a = $script:LlmCfg.answer
  if ([string]::IsNullOrWhiteSpace([string]$a.baseUrl)) { $msg.Text = '先填服务地址'; $msg.Foreground = (New-Brush '#A65E48'); return }
  $msg.Text = '测试中…'
  $msg.Foreground = (New-Brush '#8C9A90')
  $uri = Get-MdlModelsUri ([string]$a.baseUrl)
  $h = @{ 'Accept' = 'application/json' }
  if ($a.apiKey) { $h['Authorization'] = "Bearer $($a.apiKey)" }
  try {
    $r = Invoke-RestMethod -Method Get -Uri $uri -Headers $h -TimeoutSec 6
    $names = @()
    try { $names = @($r.data | ForEach-Object { [string]$_.id }) } catch { }
    if ($names.Count -gt 0) {
      if ($a.model -and ($names -contains [string]$a.model)) {
        $msg.Text = "通 · 列表里有 $($a.model)"
        $msg.Foreground = (New-Brush '#2F6B45')
      } else {
        $pick = ($names | Select-Object -First 3) -join ' / '
        $msg.Text = "通 · 可用：$pick"
        $msg.Foreground = (New-Brush '#B87400')
      }
    } else {
      $msg.Text = '通 · 服务有响应'
      $msg.Foreground = (New-Brush '#2F6B45')
    }
    Write-PetLog "llm test: ok uri=$uri models=$($names.Count)"
  } catch {
    $msg.Text = '连不上：' + (Get-LlmErrText $_.Exception.Message)
    $msg.Foreground = (New-Brush '#A65E48')
    Write-PetLog "llm test: fail uri=$uri $($_.Exception.Message)"
  }
}

function Save-JevToSag {
  Sync-MdlToCfg
  $msg = $script:MdlWin.FindName('MdlJevMsg')
  $j = $script:LlmCfg.jev
  if (-not (Test-Path $script:SagExe)) { $msg.Text = '缺 tools\sag\sag.exe'; $msg.Foreground = (New-Brush '#A65E48'); return }
  if ([string]::IsNullOrWhiteSpace([string]$j.url)) { $msg.Text = '先填 JEV 服务地址'; $msg.Foreground = (New-Brush '#A65E48'); return }
  if ([string]::IsNullOrWhiteSpace([string]$j.model)) { $msg.Text = '先填模型名'; $msg.Foreground = (New-Brush '#A65E48'); return }
  $auth = ([string]$j.auth).ToLower()
  if ($auth -eq 'bearer' -and [string]::IsNullOrWhiteSpace([string]$j.key)) {
    $msg.Text = 'Bearer 需要填密钥'; $msg.Foreground = (New-Brush '#A65E48'); return
  }
  $msg.Text = '写入中…'
  $msg.Foreground = (New-Brush '#8C9A90')
  $argList = @('config', '--url', [string]$j.url, '--model', [string]$j.model, '--auth', $auth, '--timeout', '600')
  $outText = ''
  try {
    if ($auth -eq 'none') {
      $outText = (& $script:SagExe @argList 2>&1 | Out-String)
    } else {
      # 用 stdin 传密钥：不出现在命令行、不进 shell 历史
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $script:SagExe
      $psi.Arguments = ((@($argList + '--key-stdin') | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' }) -join ' ')
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardInput = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      try { $p.StandardInput.Write([string]$j.key); $p.StandardInput.Close() } catch { }
      $so = $p.StandardOutput.ReadToEnd()
      $se = $p.StandardError.ReadToEnd()
      [void]$p.WaitForExit(30000)
      $outText = ($so + "`n" + $se)
    }
  } catch {
    $msg.Text = '写入失败：' + (Get-LlmErrText $_.Exception.Message)
    $msg.Foreground = (New-Brush '#A65E48')
    Write-PetLog "jev config: fail $($_.Exception.Message)"
    return
  }
  Write-PetLog "jev config: out=$($outText.Trim())"
  $ok = Get-JevConfigured
  if ($ok -eq $true) {
    $msg.Text = '已写入 · JEV 已配置'
    $msg.Foreground = (New-Brush '#2F6B45')
  } else {
    $tail = ($outText -replace '\s+', ' ').Trim()
    if ($tail.Length -gt 40) { $tail = $tail.Substring(0, 40) + '…' }
    $msg.Text = '写完但状态仍是未配置' + (if ($tail) { "：$tail" } else { '' })
    $msg.Foreground = (New-Brush '#B87400')
  }
  Update-MdlChips
}

$script:DtXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" Height="620" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        FontFamily="Microsoft YaHei">
  <Border CornerRadius="16" Background="#FFFFFF" BorderBrush="#E3EAE4" BorderThickness="1" SnapsToDevicePixels="True">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="54"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="58"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Background="Transparent" Margin="20,0,14,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Border Width="6" Height="6" CornerRadius="3" Background="#2F6B45" VerticalAlignment="Center" Margin="0,0,9,0"/>
          <TextBlock Text="段落详情" FontSize="15" FontWeight="Bold" Foreground="#16241C" VerticalAlignment="Center"/>
          <TextBlock x:Name="DtFile" Text="" FontSize="10" Foreground="#94A398" VerticalAlignment="Center"
                     Margin="9,2,0,0" MaxWidth="240" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <Border x:Name="DtClose" Width="30" Height="30" CornerRadius="8" Background="Transparent"
                HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand">
          <TextBlock Text="✕" FontSize="13" Foreground="#8A978D" HorizontalAlignment="Center"
                     VerticalAlignment="Center" IsHitTestVisible="False"/>
        </Border>
      </Grid>

      <Border Grid.Row="1" Margin="16,0,16,10" CornerRadius="10" Background="#F2F7F3" Padding="12,8,12,8">
        <StackPanel>
          <TextBlock x:Name="DtMeta" Text="" FontSize="11" Foreground="#2F6B45" FontWeight="SemiBold" TextWrapping="Wrap"/>
          <TextBlock Text="这是这一次命中的完整段落；结果卡上只显示前 340 字" FontSize="10"
                     Foreground="#8C9A90" Margin="0,3,0,0" TextWrapping="Wrap"/>
        </StackPanel>
      </Border>

      <Border Grid.Row="2" Margin="16,0,10,0" Background="#FFFFFF">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="DtBody" Margin="0,0,4,8"/>
        </ScrollViewer>
      </Border>

      <Grid Grid.Row="3" Margin="16,0,16,0">
        <TextBlock Text="只读取，不会改动原文件" FontSize="10" Foreground="#94A398" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Border x:Name="DtOpen" CornerRadius="7" Background="#FFFFFF" BorderBrush="#CBDCD0"
                  BorderThickness="1" Padding="12,6,12,6" Cursor="Hand" Margin="0,0,8,0">
            <TextBlock Text="在 VS Code 打开原文" FontSize="10.5" Foreground="#2F6B45"/>
          </Border>
          <Border x:Name="DtHide" CornerRadius="7" Background="#2F6B45" Padding="16,6,16,6" Cursor="Hand">
            <TextBlock Text="关闭" FontSize="10.5" Foreground="White"/>
          </Border>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

function Build-DetailWindow {
  $dw = [System.Windows.Markup.XamlReader]::Parse($script:DtXaml)
  $script:DtWin = $dw

  $dw.Add_MouseLeftButtonDown({
    param($s, $e)
    try {
      if ($e.GetPosition($script:DtWin).Y -le 54) { $script:DtWin.DragMove() }
    } catch { }
  })

  $dc = $dw.FindName('DtClose')
  $dc.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:DtWin.Hide()
  })
  $dc.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#F2F5F3') })
  $dc.Add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })

  $dh = $dw.FindName('DtHide')
  $dh.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:DtWin.Hide()
  })
  $dh.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#3B7F53') })
  $dh.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#2F6B45') })

  $do = $dw.FindName('DtOpen')
  $do.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $t = $s.Tag
    if ($t) { Open-KbFile ([string]$t.path) ([int]$t.line) }
  })
  $do.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
  $do.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#F3F9F4') })
  $do.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#FFFFFF') })
}

function Show-KbDetail($hit, [string[]]$tokens) {
  if (-not $script:DtWin) { Build-DetailWindow }
  $dw = $script:DtWin

  $dw.FindName('DtFile').Text = [string]$hit.file
  $span = if ([int]$hit.end_line -gt [int]$hit.line) {
    "第 $($hit.line)–$($hit.end_line) 行"
  } else {
    "第 $($hit.line) 行"
  }
  $meta = $span
  if ($hit.heading) { $meta = "$meta · $($hit.heading)" }
  if ($hit.hop -eq 2 -and $hit.bridge) { $meta = "$meta · 第二跳由 $($hit.bridge) 串到" }
  $dw.FindName('DtMeta').Text = $meta

  $body = $dw.FindName('DtBody')
  while ($body.Children.Count -gt 0) { $body.Children.RemoveAt(0) }
  $full = [string]$hit.full
  if ([string]::IsNullOrWhiteSpace($full)) { $full = [string]$hit.text }
  if ([string]::IsNullOrWhiteSpace($full)) {
    $fmt = if ($hit.format) { [string]$hit.format } else { '该格式' }
    $sp = New-Object System.Windows.Controls.StackPanel
    $tb = New-Object System.Windows.Controls.TextBlock
    Add-Highlight $tb "这是 $fmt 文件，没有可预览的纯文本。点下面「在 VS Code 打开原文」用系统程序看。" @() 11.6 '#7C8C82'
    $tb.TextWrapping = 'Wrap'
    $sp.Children.Add($tb) | Out-Null
    $body.Children.Add($sp) | Out-Null
  } else {
    $tb = New-Object System.Windows.Controls.TextBlock
    Add-Highlight $tb (Get-TextNoMd $full) $tokens 12.0 '#22382B'
    $tb.TextWrapping = 'Wrap'
    $tb.LineHeight = 19
    $body.Children.Add($tb) | Out-Null
  }
  $dw.FindName('DtOpen').Tag = @{ path = [string]$hit.path; line = [int]$hit.line }

  # 摆在知识库窗口旁边，跟模型窗同一套避让逻辑
  $left = 120.0
  $top = 100.0
  if ($script:KbWin -and $script:KbWin.IsVisible) {
    $left = [double]$script:KbWin.Left - 560 - 12
    if ($left -lt 8) { $left = [double]$script:KbWin.Left + 466 + 12 }
    $top = [double]$script:KbWin.Top + 30
  } else {
    $left = [double]$win.Left - 560 - 12
    if ($left -lt 8) { $left = 8 }
    $top = [double]$win.Top - 620
  }
  if ($left -lt 8) { $left = 8 }
  if ($top -lt 12) { $top = 12 }
  if ($top + 620 -gt 1380) { $top = 1380 - 620 }
  $dw.Left = $left
  $dw.Top = $top
  if (-not $dw.IsVisible) { $dw.Show() }
  try { $dw.Activate() } catch { }
  Write-PetLog "kb detail: $($hit.file) L$($hit.line) chars=$($full.Length) pos=$([int]$left),$([int]$top)"
}

function Build-ModelWindow {
  $mw = [System.Windows.Markup.XamlReader]::Parse($script:MdlXaml)
  $script:MdlWin = $mw

  # 只有标题条能拖动；✕ 必须走 Down + Handled，否则被 DragMove 吃掉
  $mw.Add_MouseLeftButtonDown({
    param($s, $e)
    try {
      if ($e.GetPosition($script:MdlWin).Y -le 54) { $script:MdlWin.DragMove() }
    } catch { }
  })
  $mc = $mw.FindName('MdlClose')
  $mc.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:MdlWin.Hide()
  })
  $mc.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#F2F5F3') })
  $mc.Add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })

  # 答案模型开/关
  $ac = $mw.FindName('MdlAnsChip')
  $ac.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Sync-MdlToCfg
    $a = $script:LlmCfg.answer
    $a.enabled = -not [bool]$a.enabled
    Save-ModelCfg
    Update-MdlChips
    Update-KbModelChip
    $tm = $script:MdlWin.FindName('MdlTestMsg')
    if ($tm) {
      $tm.Text = if ([bool]$a.enabled) { "答案模型已打开 · $($a.model)" } else { '答案模型已关闭，只用检索' }
      $tm.Foreground = (New-Brush '#2F6B45')
    }
    Write-PetLog "llm enabled -> $($a.enabled)"
  })
  $ac.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })

  # 三个预设
  foreach ($p in @(@('MdlP1', 'http://127.0.0.1:11434/v1', 'qwen2.5:7b'),
                   @('MdlP2', 'http://127.0.0.1:1234/v1', ''),
                   @('MdlP3', 'https://api.deepseek.com/v1', 'deepseek-chat'))) {
    $btn = $mw.FindName($p[0])
    if (-not $btn) { continue }
    $btn.Tag = @{ url = $p[1]; model = $p[2] }
    $btn.Add_MouseLeftButtonDown({
      param($s, $e)
      $e.Handled = $true
      $t = $s.Tag
      $script:MdlWin.FindName('MdlUrl').Text = [string]$t.url
      if ([string]$t.model) { $script:MdlWin.FindName('MdlModel').Text = [string]$t.model }
      $script:MdlWin.FindName('MdlTestMsg').Text = '预设已填入，点「测试连接」验一下'
    })
    $btn.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
    $btn.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#E8F2EA') })
    $btn.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#F3F8F4') })
  }

  $tt = $mw.FindName('MdlTest')
  $tt.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Test-LlmConn
  })
  $tt.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
  $tt.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#3B7F53') })
  $tt.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#2F6B45') })

  # 鉴权切换
  foreach ($p in @(@('MdlAuthNone', 'none'), @('MdlAuthBearer', 'bearer'))) {
    $btn = $mw.FindName($p[0])
    if (-not $btn) { continue }
    $btn.Tag = $p[1]
    $btn.Add_MouseLeftButtonDown({
      param($s, $e)
      $e.Handled = $true
      Sync-MdlToCfg
      $script:LlmCfg.jev.auth = [string]$s.Tag
      Update-MdlChips
    })
    $btn.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
  }

  $jg = $mw.FindName('MdlJevGo')
  $jg.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Save-JevToSag
  })
  $jg.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
  $jg.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#F3F9F4') })
  $jg.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#FFFFFF') })

  $sv = $mw.FindName('MdlSave')
  $sv.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Sync-MdlToCfg
    Save-ModelCfg
    Update-MdlChips
    Update-KbModelChip
    $a = $script:LlmCfg.answer
    $tm = $script:MdlWin.FindName('MdlTestMsg')
    if ($tm) {
      if ([bool]$a.enabled) {
        $tm.Text = "✓ 已保存 $(Get-Date -Format 'HH:mm:ss') · 答案模型开（$($a.model)）"
      } elseif (-not [string]::IsNullOrWhiteSpace([string]$a.baseUrl)) {
        $tm.Text = "✓ 已保存 $(Get-Date -Format 'HH:mm:ss') · 地址存好了，但右上开关还关着，点它变「开」才会用模型"
      } else {
        $tm.Text = "✓ 已保存 $(Get-Date -Format 'HH:mm:ss') · 还没有地址，现在只有检索"
      }
      $tm.Foreground = (New-Brush '#2F6B45')
    }
    Write-PetLog "llm: 设置已保存 enabled=$($a.enabled) url=$($a.baseUrl)"
  })
  $sv.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
  $sv.Add_MouseEnter({ param($s, $e) $s.Background = (New-Brush '#3B7F53') })
  $sv.Add_MouseLeave({ param($s, $e) $s.Background = (New-Brush '#2F6B45') })

  # 调试：任何一次按下都记下命中元素，用来确认坐标点到底落到哪
  $mw.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    try {
      $el = $e.OriginalSource
      $nm = ''
      try { $nm = [string]$el.Name } catch { }
      Write-PetLog ("mdl down: " + $el.GetType().Name + " name='$nm' at " + [int]$e.GetPosition($s).X + "," + [int]$e.GetPosition($s).Y)
    } catch { Write-PetLog ("mdl down ERR: " + $_.Exception.Message) }
  })
}

function Show-ModelWindow {
  if (-not $script:MdlWin) { Build-ModelWindow }
  # 每次打开都从磁盘重读，免得两份状态打架
  $script:LlmCfg = Load-ModelCfg
  Fill-MdlFromCfg
  Update-MdlChips
  $mw = $script:MdlWin
  $left = 120.0
  $top = 100.0
  if ($script:KbWin -and $script:KbWin.IsVisible) {
    $left = [double]$script:KbWin.Left + 466 + 12
    if ($left + 620 -gt 3420) { $left = [double]$script:KbWin.Left - 620 - 12 }
    $top = [double]$script:KbWin.Top
  } else {
    $left = [double]$win.Left - 620 - 12
    if ($left -lt 8) { $left = 8 }
    $top = [double]$win.Top + [double]$win.Height - 740
  }
  if ($left -lt 8) { $left = 8 }
  if ($top -lt 12) { $top = 12 }
  if ($top + 740 -gt 1380) { $top = 1380 - 740 }
  $mw.Left = $left
  $mw.Top = $top
  if (-not $mw.IsVisible) { $mw.Show() }
  try { $mw.Activate() } catch { }
  Write-PetLog "模型窗打开 pos=$([int]$left),$([int]$top)"
}

# ---------- 轻量 markdown 支持 ----------
# 原文卡片只做"去标记"（保留关键词高亮）；答案卡做完整渲染（粗体 / 列表 / 标题 / 代码）
function Get-TextNoMd([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return '' }
  $s = $s -replace '(?m)^\s{0,3}#{1,6}\s*', ''
  $s = $s -replace '(?m)^\s*>+\s?', ''
  $s = $s -replace '(?m)^\s*[-*+]\s+', '· '
  $s = $s -replace '!\[([^\]]*)\]\([^)]*\)', '$1'
  $s = $s -replace '\[([^\]]+)\]\([^)]+\)', '$1'
  $s = $s -replace '(?m)^\s*\|?\s*:?-{3,}[-\s:|]*$', ''
  $s = $s -replace '\|', ' '
  $s = $s -replace '[ \t]{2,}', ' '
  $s = $s -replace '[*`_]', ''
  return $s.Trim()
}

# 行内 **粗体** 与 `代码` 拆成 Run，塞进同一个 TextBlock
function Add-InlineMd([System.Windows.Controls.TextBlock]$tb, [string]$text, [double]$size, [string]$fg) {
  $rx = [regex]'\*\*(?<b>.+?)\*\*|`(?<c>.+?)`|\[(?<n>\d+)\]|<br\s*/?>'
  $pos = 0
  foreach ($m in $rx.Matches($text)) {
    if ($m.Index -gt $pos) {
      $r = New-Object System.Windows.Documents.Run ($text.Substring($pos, $m.Index - $pos))
      $r.FontSize = $size
      $r.Foreground = (New-Brush $fg)
      $tb.Inlines.Add($r) | Out-Null
    }
    if ($m.Groups['b'].Success) {
      $r = New-Object System.Windows.Documents.Run ($m.Groups['b'].Value)
      $r.FontSize = $size
      $r.FontWeight = 'Bold'
      $r.Foreground = (New-Brush $fg)
    } elseif ($m.Groups['c'].Success) {
      $r = New-Object System.Windows.Documents.Run ($m.Groups['c'].Value)
      $r.FontSize = ($size - 0.3)
      $r.FontFamily = (New-Object System.Windows.Media.FontFamily 'Consolas, Microsoft YaHei')
      $r.Foreground = (New-Brush '#2F6B45')
    } elseif ($m.Value -match '^<br') {
      $tb.Inlines.Add((New-Object System.Windows.Documents.LineBreak)) | Out-Null
    } else {
      # 引用编号 [1] 做成绿色小标记，而不是跟着正文一个颜色
      $r = New-Object System.Windows.Documents.Run ('[' + $m.Groups['n'].Value + ']')
      $r.FontSize = ($size - 0.6)
      $r.Foreground = (New-Brush '#2F8A5B')
    }
    $tb.Inlines.Add($r) | Out-Null
    $pos = $m.Index + $m.Length
  }
  if ($pos -lt $text.Length) {
    $r = New-Object System.Windows.Documents.Run ($text.Substring($pos))
    $r.FontSize = $size
    $r.Foreground = (New-Brush $fg)
    $tb.Inlines.Add($r) | Out-Null
  }
}

# 把 | a | b | 形式的表格行拆成单元格（支持 \| 转义、首尾竖线可省）
function Split-MdTableRow([string]$line) {
  $t = $line.Trim()
  if ($t.StartsWith('|')) { $t = $t.Substring(1) }
  if ($t.EndsWith('|')) { $t = $t.Substring(0, $t.Length - 1) }
  $cells = New-Object System.Collections.Generic.List[string]
  $sb = New-Object System.Text.StringBuilder
  $esc = $false
  foreach ($ch in $t.ToCharArray()) {
    if ($esc) { [void]$sb.Append($ch); $esc = $false; continue }
    if ($ch -eq '\') { $esc = $true; continue }
    if ($ch -eq '|') { $cells.Add($sb.ToString().Trim()); [void]$sb.Clear(); continue }
    [void]$sb.Append($ch)
  }
  $cells.Add($sb.ToString().Trim())
  return ,$cells.ToArray()
}

# 形如 | --- | :---: | ---: | 的分隔行才算表格，普通带竖线的句子不当表格
function Test-MdTableSep([string]$line) {
  $t = $line.Trim()
  if ($t -eq '' -or $t -notmatch '--') { return $false }
  if ($t -notmatch '^[\s|:\-]+$') { return $false }
  if (($t -split '\|').Count -lt 2) { return $false }
  return $true
}

# 渲染成真正的 WPF 表格：表头底色、细边框、按每列内容长度分配宽度、按 :---: 对齐
function New-MdTable([string[]]$rows, [double]$size, [string]$fg) {
  $outer = New-Object System.Windows.Controls.Border
  $outer.BorderBrush = (New-Brush '#DCE8E0')
  $outer.BorderThickness = (New-Object System.Windows.Thickness 1)
  $outer.CornerRadius = (New-Object System.Windows.CornerRadius 3)
  $outer.Background = (New-Brush '#FFFFFF')
  $outer.Margin = (New-Object System.Windows.Thickness 0, 3, 0, 7)
  if ($rows.Count -lt 2) { return $outer }

  $parsed = New-Object System.Collections.Generic.List[object]
  foreach ($r in $rows) { $parsed.Add((Split-MdTableRow $r)) }

  $cols = 1
  foreach ($p in $parsed) { if ($p.Count -gt $cols) { $cols = $p.Count } }

  # 列宽按该列最长内容分配，避免"序号"占掉一半宽度
  $grid = New-Object System.Windows.Controls.Grid
  for ($c = 0; $c -lt $cols; $c++) {
    $maxLen = 4
    foreach ($p in $parsed) {
      if ($c -lt $p.Count) {
        $l = ($p[$c] -replace '<[^>]+>', '').Length
        if ($l -gt $maxLen) { $maxLen = $l }
      }
    }
    $w = [Math]::Min([Math]::Max($maxLen, 3), 36)
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    $cd.Width = New-Object System.Windows.GridLength ([double]$w), ([System.Windows.GridUnitType]::Star)
    $grid.ColumnDefinitions.Add($cd) | Out-Null
  }

  $aligns = @()
  $sepCells = Split-MdTableRow $rows[1]
  for ($c = 0; $c -lt $cols; $c++) {
    $a = 'left'
    if ($c -lt $sepCells.Count) {
      $s = [string]$sepCells[$c]
      if ($s.StartsWith(':') -and $s.EndsWith(':')) { $a = 'center' }
      elseif ($s.EndsWith(':')) { $a = 'right' }
    }
    $aligns += $a
  }

  for ($k = 0; $k -lt ($parsed.Count - 1); $k++) {
    $rd = New-Object System.Windows.Controls.RowDefinition
    $grid.RowDefinitions.Add($rd) | Out-Null
  }

  for ($r = 0; $r -lt $parsed.Count; $r++) {
    if ($r -eq 1) { continue }   # 跳过分隔行
    $isHeader = ($r -eq 0)
    $gridRow = if ($isHeader) { 0 } else { $r - 1 }
    for ($c = 0; $c -lt $cols; $c++) {
      $text = ''
      if ($c -lt $parsed[$r].Count) { $text = [string]$parsed[$r][$c] }
      $bg = if ($isHeader) { '#EDF4EF' } elseif ($gridRow % 2 -eq 1) { '#F8FBF9' } else { '#FFFFFF' }
      $b = New-Object System.Windows.Controls.Border
      $b.Background = (New-Brush $bg)
      $b.BorderBrush = (New-Brush '#E3EDE7')
      $b.BorderThickness = (New-Object System.Windows.Thickness 0, 0, 1, 1)
      $tb = New-Object System.Windows.Controls.TextBlock
      $tb.TextWrapping = 'Wrap'
      $tb.FontSize = ($size - 1.2)
      $tb.LineHeight = ($size + 3.5)
      $tb.Padding = (New-Object System.Windows.Thickness 6, 3, 6, 3)
      if ($isHeader) {
        $tb.FontWeight = 'Bold'
        $tb.Foreground = (New-Brush '#2F6B45')
        Add-InlineMd $tb $text $tb.FontSize '#2F6B45'
      } else {
        $tb.Foreground = (New-Brush $fg)
        Add-InlineMd $tb $text $tb.FontSize $fg
      }
      $al = if ($c -lt $aligns.Count) { $aligns[$c] } else { 'left' }
      if ($al -eq 'center') { $tb.TextAlignment = 'Center' }
      elseif ($al -eq 'right') { $tb.TextAlignment = 'Right' }
      $b.Child = $tb
      [System.Windows.Controls.Grid]::SetColumn($b, $c)
      [System.Windows.Controls.Grid]::SetRow($b, $gridRow)
      $grid.Children.Add($b) | Out-Null
    }
  }

  $outer.Child = $grid
  return $outer
}

# 整段 markdown 渲染成 StackPanel：标题 / 无序列表 / 编号列表 / 引用 / 代码块 / 表格
function New-MarkdownPanel([string]$md, [double]$size, [string]$fg) {
  $sp = New-Object System.Windows.Controls.StackPanel
  if ([string]::IsNullOrEmpty($md)) { return $sp }
  $inCode = $false
  $lines = @($md -split "`r?`n")
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $raw = $lines[$i]
    $t = $raw.Trim()
    if ($t -match '^`{3,}') { $inCode = -not $inCode; continue }
    if ($t -eq '') { continue }

    if ($inCode) {
      $c = New-Object System.Windows.Controls.TextBlock
      $c.Text = $raw.TrimEnd()
      $c.FontFamily = (New-Object System.Windows.Media.FontFamily 'Consolas, Microsoft YaHei')
      $c.FontSize = ($size - 0.6)
      $c.Foreground = (New-Brush '#3E4F44')
      $c.TextWrapping = 'Wrap'
      $c.Margin = (New-Object System.Windows.Thickness 0, 0, 0, 1)
      $sp.Children.Add($c) | Out-Null
      continue
    }

    # 表格：当前行是表头，下一行是 | --- | 分隔行，就一路吃到不是表格行为止
    if ($t.Contains('|')) {
      $nextT = if ($i + 1 -lt $lines.Count) { $lines[$i + 1].Trim() } else { '' }
      if ((Test-MdTableSep $nextT) -and ($t -notmatch '^`{3,}')) {
        $tbl = New-Object System.Collections.Generic.List[string]
        $tbl.Add($t)
        $i++
        $tbl.Add($lines[$i].Trim())
        while ($i + 1 -lt $lines.Count) {
          $nxt = $lines[$i + 1].Trim()
          if ($nxt -eq '' -or -not $nxt.Contains('|')) { break }
          if ($nxt -match '^`{3,}') { break }
          $i++
          $tbl.Add($nxt)
        }
        $sp.Children.Add((New-MdTable $tbl.ToArray() $size $fg)) | Out-Null
        continue
      }
    }

    $hm = [regex]::Match($t, '^(#{1,6})\s*(.+)$')
    if ($hm.Success) {
      $lvl = $hm.Groups[1].Value.Length
      $h = New-Object System.Windows.Controls.TextBlock
      $h.FontWeight = 'Bold'
      $h.FontSize = if ($lvl -le 2) { $size + 1.8 } else { $size + 0.7 }
      $h.Foreground = (New-Brush '#2F6B45')
      $h.TextWrapping = 'Wrap'
      $h.Margin = (New-Object System.Windows.Thickness 0, 7, 0, 3)
      Add-InlineMd $h $hm.Groups[2].Value $h.FontSize '#2F6B45'
      $sp.Children.Add($h) | Out-Null
      continue
    }

    $lm = [regex]::Match($t, '^[-*+]\s+(.+)$')
    if ($lm.Success) {
      $row = New-Object System.Windows.Controls.Grid
      $c1 = New-Object System.Windows.Controls.ColumnDefinition
      $c1.Width = (New-Object System.Windows.GridLength 13)
      $c2 = New-Object System.Windows.Controls.ColumnDefinition
      $c2.Width = (New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star))
      $row.ColumnDefinitions.Add($c1)
      $row.ColumnDefinitions.Add($c2)
      $dot = New-Object System.Windows.Controls.TextBlock
      $dot.Text = '·'
      $dot.FontSize = $size
      $dot.Foreground = (New-Brush '#7FA98C')
      [System.Windows.Controls.Grid]::SetColumn($dot, 0)
      $row.Children.Add($dot) | Out-Null
      $body = New-Object System.Windows.Controls.TextBlock
      $body.TextWrapping = 'Wrap'
      $body.LineHeight = ($size + 6)
      Add-InlineMd $body $lm.Groups[1].Value $size $fg
      [System.Windows.Controls.Grid]::SetColumn($body, 1)
      $row.Children.Add($body) | Out-Null
      $row.Margin = (New-Object System.Windows.Thickness 0, 0, 0, 3)
      $sp.Children.Add($row) | Out-Null
      continue
    }

    $nm = [regex]::Match($t, '^(\d+)[.、)]\s+(.+)$')
    if ($nm.Success) {
      $row = New-Object System.Windows.Controls.Grid
      $c1 = New-Object System.Windows.Controls.ColumnDefinition
      $c1.Width = (New-Object System.Windows.GridLength 18)
      $c2 = New-Object System.Windows.Controls.ColumnDefinition
      $c2.Width = (New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star))
      $row.ColumnDefinitions.Add($c1)
      $row.ColumnDefinitions.Add($c2)
      $num = New-Object System.Windows.Controls.TextBlock
      $num.Text = $nm.Groups[1].Value + '.'
      $num.FontSize = $size
      $num.Foreground = (New-Brush '#7FA98C')
      [System.Windows.Controls.Grid]::SetColumn($num, 0)
      $row.Children.Add($num) | Out-Null
      $body = New-Object System.Windows.Controls.TextBlock
      $body.TextWrapping = 'Wrap'
      $body.LineHeight = ($size + 6)
      Add-InlineMd $body $nm.Groups[2].Value $size $fg
      [System.Windows.Controls.Grid]::SetColumn($body, 1)
      $row.Children.Add($body) | Out-Null
      $row.Margin = (New-Object System.Windows.Thickness 0, 0, 0, 3)
      $sp.Children.Add($row) | Out-Null
      continue
    }

    $qm = [regex]::Match($t, '^>\s*(.+)$')
    if ($qm.Success) {
      $q = New-Object System.Windows.Controls.TextBlock
      $q.TextWrapping = 'Wrap'
      $q.LineHeight = ($size + 6)
      $q.Margin = (New-Object System.Windows.Thickness 2, 0, 0, 4)
      $q.Foreground = (New-Brush '#7C8C82')
      Add-InlineMd $q $qm.Groups[1].Value ($size - 0.3) '#7C8C82'
      $sp.Children.Add($q) | Out-Null
      continue
    }

    $p = New-Object System.Windows.Controls.TextBlock
    $p.TextWrapping = 'Wrap'
    $p.LineHeight = ($size + 6.5)
    $p.Margin = (New-Object System.Windows.Thickness 0, 0, 0, 5)
    Add-InlineMd $p $t $size $fg
    $sp.Children.Add($p) | Out-Null
  }
  return $sp
}

# ---------- 可选：让模型把命中的原文读成一段答案 ----------
$script:KbAnswerList = $null
$script:KbLastHits = @()
$script:LlmBusy = $false
$script:LlmPs = $null
$script:LlmAsync = $null
$script:LlmStart = $null
$script:LlmN = 0

function Get-LlmErrText([string]$e) {
  if ([string]::IsNullOrWhiteSpace($e)) { return '未知错误' }
  $e = ($e -replace '\s+', ' ').Trim()
  if ($e -match '远程名称无法解析|No such host|nodename|getaddrinfo') { return '地址解析失败，检查服务地址拼写' }
  if ($e -match 'Unable to connect|actively refused|积极拒绝|连接被拒绝') { return '连不上，先确认服务在跑、端口对不对' }
  if ($e -match '401|403|Unauthorized|Forbidden|invalid_api_key|invalid api key') { return '鉴权没过，检查密钥' }
  if ($e -match ' 404|\b404\b|Not Found') { return '接口路径不存在，地址填到 /v1 就行' }
  if ($e -match '没有 choices|choices\[0\]') { return '返回格式不对，确认是 OpenAI 兼容接口' }
  if ($e -match 'timed out|超时|Timeout') { return '请求超时，模型太慢或地址不通' }
  if ($e.Length -gt 90) { return $e.Substring(0, 90) + '…' }
  return $e
}

# 把命中段落拼成带编号的上下文，顺带回报真正喂了几段
function Build-LlmContext($hits) {
  $a = $script:LlmCfg.answer
  $topN = [int]$a.topN
  if ($topN -le 0) { $topN = 5 }
  $parts = @()
  $n = 0
  foreach ($h in $hits) {
    if ($n -ge $topN) { break }
    if ($h.readable -eq $false) { continue }
    $t = [string]$h.text
    if ([string]::IsNullOrWhiteSpace($t)) { continue }
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt 700) { $t = $t.Substring(0, 700) + '…' }
    $n++
    $parts += ("[{0}] {1} · 第{2}行`n{3}" -f $n, [string]$h.file, [int]$h.line, $t)
  }
  return @{ ctx = ($parts -join "`n`n"); n = $n }
}

function New-KbAnswerCard([string]$text, [string]$model, [int]$n) {
  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = (New-Object System.Windows.CornerRadius 12, 12, 12, 12)
  $border.Background = (New-Brush '#F4FAF6')
  $border.BorderBrush = (New-Brush '#D9EBDF')
  $border.BorderThickness = '1'
  $border.Padding = (New-Object System.Windows.Thickness 14, 11, 14, 13)
  $border.Margin = (New-Object System.Windows.Thickness 0, 0, 0, 8)

  $sp = New-Object System.Windows.Controls.StackPanel
  $hdr = New-Object System.Windows.Controls.Grid
  $left = New-Object System.Windows.Controls.StackPanel
  $left.Orientation = 'Horizontal'
  $t1 = New-Object System.Windows.Controls.TextBlock
  $t1.Text = '答案'
  $t1.FontSize = 11.5
  $t1.FontWeight = 'Bold'
  $t1.Foreground = (New-Brush '#2F6B45')
  $t1.VerticalAlignment = 'Center'
  $t2 = New-Object System.Windows.Controls.TextBlock
  $t2.Text = '· 模型生成，仅供参考'
  $t2.FontSize = 9.5
  $t2.Foreground = (New-Brush '#7FA98C')
  $t2.Margin = (New-Object System.Windows.Thickness 5, 2, 0, 0)
  $t2.VerticalAlignment = 'Center'
  $left.Children.Add($t1) | Out-Null
  $left.Children.Add($t2) | Out-Null
  $hdr.Children.Add($left) | Out-Null
  $m = New-Object System.Windows.Controls.TextBlock
  $m.Text = $model
  $m.FontSize = 9
  $m.Foreground = (New-Brush '#A2AEA6')
  $m.HorizontalAlignment = 'Right'
  $m.VerticalAlignment = 'Center'
  $m.TextTrimming = 'CharacterEllipsis'
  $m.MaxWidth = 220
  $hdr.Children.Add($m) | Out-Null
  $sp.Children.Add($hdr) | Out-Null

  $mdPanel = New-MarkdownPanel $text 12.2 '#22382B'
  $mdPanel.Margin = (New-Object System.Windows.Thickness 0, 7, 0, 0)
  $sp.Children.Add($mdPanel) | Out-Null

  $foot = New-Object System.Windows.Controls.TextBlock
  $foot.Text = "依据下方 $n 段原文作答，编号对应下面的卡片，请核对行号"
  $foot.FontSize = 9.5
  $foot.Foreground = (New-Brush '#93A096')
  $foot.Margin = (New-Object System.Windows.Thickness 0, 8, 0, 0)
  $foot.TextWrapping = 'Wrap'
  $sp.Children.Add($foot) | Out-Null

  $border.Child = $sp
  return $border
}

# 生成放到独立 runspace 里跑，否则 7B 模型回一个字要十几秒，整个浮窗会僵住
function Start-KbAnswer([string]$q, $hits, $list) {
  $a = $script:LlmCfg.answer
  $ctxInfo = Build-LlmContext $hits
  if ($ctxInfo.n -le 0) { return $false }
  $sys = @'
你是本地知识库的阅读助手，只做"把已检索到的原文整理成答案"这一件事。
规则：
1. 只能依据用户给出的片段作答，不许使用片段以外的任何知识，不许补充片段里没有的细节。
2. 片段不足以回答时，直接回复「知识库里没有找到能回答这个问题的内容」，不要猜测，也不要给方向性建议。
3. 回答中每个事实后面必须标注来源编号，如 [1]；编号只能来自给出的片段。
5. 可以用简单 markdown：加粗、无序列表、小标题；原文是表格时可以用竖线表格（表头一行，第二行 | --- |），不要合并单元格、不要嵌套表格。
4. 用简洁的书面中文，不要复述问题，不要写"根据片段""以下是"这类开场。
'@
  $usr = "片段：`n`n$($ctxInfo.ctx)`n`n问题：$q"
  $bodyObj = @{
    model       = [string]$a.model
    messages    = @(
      @{ role = 'system'; content = $sys },
      @{ role = 'user'; content = $usr }
    )
    temperature = 0.15
    max_tokens  = [int]$a.maxTokens
    stream      = $false
  }
  $body = ($bodyObj | ConvertTo-Json -Depth 8 -Compress)
  $ep = Get-ChatEndpoint ([string]$a.baseUrl)
  $key = [string]$a.apiKey

  if ($script:LlmPs) { try { $script:LlmPs.Stop(); $script:LlmPs.Dispose() } catch { }; $script:LlmPs = $null; $script:LlmAsync = $null }
  $ps = [PowerShell]::Create()
  [void]$ps.AddScript({
      param($ep, $body, $key)
      $h = @{ 'Content-Type' = 'application/json; charset=utf-8'; 'Accept' = 'application/json' }
      if ($key) { $h['Authorization'] = "Bearer $key" }
      $b = [System.Text.Encoding]::UTF8.GetBytes($body)
      $r = Invoke-RestMethod -Method Post -Uri $ep -Body $b -Headers $h -TimeoutSec 120
      $c = $null
      try { $c = [string]$r.choices[0].message.content } catch { }
      if (-not $c) { throw '返回里没有 choices[0].message.content，确认这是 OpenAI 兼容的 /chat/completions' }
      return $c
    }).AddArgument($ep).AddArgument($body).AddArgument($key)
  $script:LlmPs = $ps
  try {
    $script:LlmAsync = $ps.BeginInvoke()
  } catch {
    Write-PetLog "llm: 启动失败 $($_.Exception.Message)"
    $script:LlmPs = $null
    return $false
  }
  $script:LlmStart = Get-Date
  $script:LlmN = [int]$ctxInfo.n
  $script:LlmBusy = $true
  $script:KbAnswerList = $list
  $script:LlmPoll.Start()
  Write-PetLog "llm: start ep=$ep model=$($a.model) ctx=$($ctxInfo.n)"
  return $true
}

# 一次性滚动修正：等布局跑完再拉回顶部，否则 ScrollViewer 会把刚插入的答案卡留在视口外
$script:KbScrollFix = New-Object System.Windows.Threading.DispatcherTimer
$script:KbScrollFix.Interval = [TimeSpan]::FromMilliseconds(260)
$script:KbScrollFix.Add_Tick({
    $script:KbScrollFix.Stop()
    try {
      if (-not $script:KbWin) { return }
      $sc = $script:KbWin.FindName('KbScroll')
      if (-not $sc) { return }
      $sc.UpdateLayout()
      $sc.ScrollToVerticalOffset(0)
      Write-PetLog "kb: 结果已滚回顶部"
    } catch { }
  })

$script:LlmPoll = New-Object System.Windows.Threading.DispatcherTimer
$script:LlmPoll.Interval = [TimeSpan]::FromMilliseconds(400)
$script:LlmPoll.Add_Tick({
    if (-not $script:LlmAsync) { $script:LlmPoll.Stop(); return }
    if (-not $script:LlmAsync.IsCompleted) {
      if ($script:LlmStart -and ((Get-Date) - $script:LlmStart).TotalSeconds -gt 150) {
        $script:LlmPoll.Stop()
        try { $script:LlmPs.Stop(); $script:LlmPs.Dispose() } catch { }
        $script:LlmPs = $null
        $script:LlmAsync = $null
        $script:LlmBusy = $false
        Set-KbStatus '答案生成超时（150 秒）已放弃，下面仍是检索结果'
        Write-PetLog 'llm: timeout'
      }
      return
    }
    $script:LlmPoll.Stop()
    $txt = $null
    $err = $null
    try {
      $out = $script:LlmPs.EndInvoke($script:LlmAsync)
      if ($out -and $out.Count -gt 0) { $txt = [string]$out[0] }
    } catch { $err = $_.Exception.Message }
    try {
      $se = $script:LlmPs.Streams.Error
      if ($se -and $se.Count -gt 0) { $err = [string]$se[0].ToString() }
    } catch { }
    try { $script:LlmPs.Dispose() } catch { }
    $script:LlmPs = $null
    $script:LlmAsync = $null
    $script:LlmBusy = $false
    if ([string]::IsNullOrWhiteSpace($txt)) {
      Set-KbStatus ('答案生成失败：' + (Get-LlmErrText $err))
      Write-PetLog "llm: fail $err"
      return
    }
    try {
      $card = New-KbAnswerCard ($txt.Trim()) ([string]$script:LlmCfg.answer.model) $script:LlmN
      if ($script:KbAnswerList) { $script:KbAnswerList.Children.Insert(0, $card) | Out-Null }
      # 布局是异步的，这一帧滚不动（实测答案卡会被顶到视口上方 400px），
      # 交给一次性 timer 在下一条消息里滚到顶
      if ($script:KbScrollFix) { $script:KbScrollFix.Stop(); $script:KbScrollFix.Start() }
    } catch { Write-PetLog "llm: 渲染失败 $($_.Exception.Message)" }
    Set-KbStatus "命中 $(@($script:KbLastHits).Count) 条 · 答案已生成（喂了 $($script:LlmN) 段）"
    Write-PetLog "llm: done len=$($txt.Length) ctx=$($script:LlmN)"
  })

# ---------- 拖动 / 点击 ----------
$script:dragging = $false
$script:suppressShow = $false
$script:dragMoved = $false
$script:dragStartX = 0
$script:dragStartY = 0
$script:winStartL = 0
$script:winStartT = 0

$win.Add_MouseLeftButtonDown({
  param($s, $e)
  $p = [System.Windows.Forms.Cursor]::Position
  $script:dragStartX = $p.X
  $script:dragStartY = $p.Y
  $script:winStartL = $win.Left
  $script:winStartT = $win.Top
  $script:dragging = $true
  $script:dragMoved = $false
  Write-PetLog "down at $($p.X),$($p.Y) win=$($win.Left),$($win.Top)"
})

$win.Add_MouseMove({
  param($s, $e)
  if (-not $script:dragging) { return }
  # 左键已经松开了（Up 被子控件吃掉、或在窗口外松开），当场结束拖动，
  # 否则窗口会一直黏着鼠标跑
  if ([System.Windows.Input.Mouse]::LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) {
    $script:dragging = $false
    return
  }
  $p = [System.Windows.Forms.Cursor]::Position
  $dx = $p.X - $script:dragStartX
  $dy = $p.Y - $script:dragStartY
  # 先过阈值才真的搬窗口：手点一下常抖 3~8px，无条件搬会让人误以为"宠物黏在鼠标上"
  if (-not $script:dragMoved -and ([Math]::Abs($dx) + [Math]::Abs($dy)) -gt 10) { $script:dragMoved = $true }
  if ($script:dragMoved) {
    $win.Left = $script:winStartL + $dx
    $win.Top = $script:winStartT + $dy
  }
})

# 关键：handledEventsToo=$true。宠物/照片/面板行在 Up 里都设了 e.Handled=$true，
# 普通订阅收不到，dragging 会卡死在 true —— 表现就是"点一下，宠物就黏在鼠标上"
$onWindowUp = [System.Windows.Input.MouseButtonEventHandler]{
  param($s, $e)
  if (-not $script:dragging) { return }
  $script:dragging = $false
  try { [void]$win.ReleaseMouseCapture() } catch { }
  Write-PetLog "up moved=$($script:dragMoved) win=$($win.Left),$($win.Top)"
  if ($script:dragMoved) {
    $script:followOn = $false
    $followText.Text = '手动摆放'
    try { Keep-OnScreen } catch { }
    Save-Config
  }
}
$win.AddHandler([System.Windows.UIElement]::MouseLeftButtonUpEvent, $onWindowUp, $true)

# 兜底看门狗：捕获也可能丢（切窗口、锁屏、别的程序抢焦点），
# 每 120ms 查一次真实按键状态，松开就立刻结束拖动
$dragWatch = New-Object System.Windows.Threading.DispatcherTimer
$dragWatch.Interval = [TimeSpan]::FromMilliseconds(120)
$dragWatch.Add_Tick({
  if (-not $script:dragging) { return }
  if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) { return }
  $script:dragging = $false
  try { [void]$win.ReleaseMouseCapture() } catch { }
  Write-PetLog "drag watchdog released moved=$($script:dragMoved)"
  if ($script:dragMoved) {
    $script:followOn = $false
    $followText.Text = '手动摆放'
    try { Keep-OnScreen } catch { }
    Save-Config
  }
})
$dragWatch.Start()

# 鼠标滑出窗口时若已松开左键，也复位
$win.Add_MouseLeave({
  param($s, $e)
  if ([System.Windows.Input.Mouse]::LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) {
    $script:dragging = $false
  }
})

# 点照片 → 打开详情
$photo.Add_MouseLeftButtonUp({
  param($s, $e)
  if ($script:dragMoved) { return }
  $e.Handled = $true
  Write-PetLog 'click photo'
  Open-Current
})

# 点宠物 → 展开/收起设置面板
$pet.Add_MouseLeftButtonUp({
  param($s, $e)
  if ($script:dragMoved) { return }
  $e.Handled = $true
  Write-PetLog 'click pet'
  if ($panelView.Visibility -eq 'Visible') {
    Show-Panel $false
  } else {
    Show-Panel $true
  }
})

# 面板各项
$win.FindName('RowCarousel').Add_MouseLeftButtonUp({
  param($s, $e)
  if ($script:dragMoved) { return }
  $e.Handled = $true
  Write-PetLog 'click RowCarousel'
  Set-Carousel (-not $script:carouselOn)
})

# 景区卡片 开 / 关（关了只留宠物，头顶小标签继续轮播）
$win.FindName('RowCard').Add_MouseLeftButtonUp({
  param($s, $e)
  if ($script:dragMoved) { return }
  $e.Handled = $true
  Write-PetLog 'click RowCard'
  Set-ShowCard (-not $script:showCard)
})

# 知识库：收起设置面板，打开本地知识库窗口
$win.FindName('RowKb').Add_MouseLeftButtonUp({
  param($s, $e)
  if ($script:dragMoved) { return }
  $e.Handled = $true
  Write-PetLog 'click RowKb'
  Show-Panel $false
  Show-KbWindow
})

$win.FindName('PickQiqi').Add_MouseLeftButtonUp({
  param($s, $e); if ($script:dragMoved) { return }; $e.Handled = $true
  Apply-Pet 'mingqiqi'; Play-Pose 'wave'; Write-PetLog 'click PickQiqi'
})
$win.FindName('PickLingling').Add_MouseLeftButtonUp({
  param($s, $e); if ($script:dragMoved) { return }; $e.Handled = $true
  Apply-Pet 'minglingling'; Play-Pose 'wave'; Write-PetLog 'click PickLingling'
})
$win.FindName('PickBaobao').Add_MouseLeftButtonUp({
  param($s, $e); if ($script:dragMoved) { return }; $e.Handled = $true
  Apply-Pet 'mingbaobao'; Play-Pose 'wave'; Write-PetLog 'click PickBaobao'
})

$win.FindName('RowFollow').Add_MouseLeftButtonUp({
  param($s, $e)
  if ($script:dragMoved) { return }
  $e.Handled = $true
  $script:followOn = -not $script:followOn
  $followText.Text = if ($script:followOn) { '跟随 WorkBuddy' } else { '手动摆放' }
  if (-not $script:followOn) { Save-Config }
})

$win.FindName('RowOpen').Add_MouseLeftButtonUp({
  param($s, $e)
  if ($script:dragMoved) { return }
  $e.Handled = $true
  Open-Current
})

# 点「关闭浮窗」：存位置 → 停掉所有计时器 → 关窗口 → 结束进程
# Down 里执行（自绘 Border 在 Down 设 Handled 后 Up 就不再到达），Up 只吃事件
$quitBtn = $win.FindName('BtnQuit')
if ($quitBtn) {
  $quitBtn.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    Write-PetLog 'quit: 收到关闭按钮点击'
    Exit-Pet
  })
  $quitBtn.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true })
  $quitBtn.Add_MouseEnter({ param($s, $e)
      $s.Background = (New-Brush '#F7D9CD')
      $s.BorderBrush = (New-Brush '#E7BCA7')
    })
  $quitBtn.Add_MouseLeave({ param($s, $e)
      $s.Background = (New-Brush '#FBEFEC')
      $s.BorderBrush = (New-Brush '#EFD3C8')
    })
}

function Exit-Pet {
  try { Save-Config } catch { }
  Write-PetLog 'exit: 用户点「关闭浮窗」，进程结束'
  foreach ($t in @($script:KbPoll, $script:lineTimer, $script:actTimer, $script:kbInit, $script:repaint)) {
    try { if ($t) { $t.Stop() } } catch { }
  }
  try { if ($script:KbWin -and $script:KbWin.IsVisible) { $script:KbWin.Close() } } catch { }
  try { $win.Close() } catch { }
  try { $script:InstMutex.ReleaseMutex() } catch { }
  Start-Sleep -Milliseconds 80
  [System.Environment]::Exit(0)
}

# ---------- 位置 ----------
function Set-AlwaysOnTop {
  try {
    $h = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    if ($h -eq [IntPtr]::Zero) { return }
    [void][Native.Win]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0002 -bor 0x0001 -bor 0x0010)
  } catch { }
}

# 换尺寸之后必须重新夹一下位置：精简态 252 宽，设置面板 560 宽，
# 贴在屏幕最右边展开就会往外顶 308px，结果面板被裁、宠物整个跑到屏外。
function Keep-OnScreen {
  try {
    if ($null -eq $win) { return }
    # WPF 的 Left/Top/Width 是 DIP，Screen.WorkingArea 是物理像素，先换算
    $sx = 1.0; $sy = 1.0
    try {
      $sr = [System.Windows.PresentationSource]::FromVisual($win)
      if ($sr -and $sr.CompositionTarget) {
        $m = $sr.CompositionTarget.TransformToDevice
        if ($m.M11 -gt 0) { $sx = [double]$m.M11 }
        if ($m.M22 -gt 0) { $sy = [double]$m.M22 }
      }
    } catch { }
    $cw = [double]$win.Width * $sx
    $ch = [double]$win.Height * $sy
    $pl = [double]$win.Left * $sx
    $pt = [double]$win.Top * $sy
    $scr = $null
    try {
      $scr = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point ([int]($pl + 16)), ([int]($pt + 16))))
    } catch { }
    if (-not $scr) { $scr = [System.Windows.Forms.Screen]::PrimaryScreen }
    $wa = $scr.WorkingArea
    $nl = $pl
    $nt = $pt
    if ($nl + $cw -gt $wa.Right) { $nl = [double]$wa.Right - $cw }
    if ($nl -lt $wa.Left) { $nl = [double]$wa.Left }
    if ($nt + $ch -gt $wa.Bottom) { $nt = [double]$wa.Bottom - $ch }
    if ($nt -lt $wa.Top) { $nt = [double]$wa.Top }
    if ([Math]::Abs($nl - $pl) -gt 0.5 -or [Math]::Abs($nt - $pt) -gt 0.5) {
      $win.Left = $nl / $sx
      $win.Top = $nt / $sy
      Write-PetLog ("keep: $([int]$pl),$([int]$pt) -> $([int]$nl),$([int]$nt) size=$([int]$cw)x$([int]$ch)")
    }
  } catch { }
}

function Update-Position {
  if ($script:dragging) { return }
  # 选文件夹对话框期间浮窗被临时藏起来，别让定时器又把它 Show 出来挡住对话框
  if ($script:suppressShow) { return }
  $rect = Get-WorkBuddyRect
  if ($script:posLog % 50 -eq 0) {
    $tail = if ($rect) { "workbuddy=$($rect.Right),$($rect.Bottom)" } else { 'workbuddy=null' }
    Write-PetLog "pos tick follow=$($script:followOn) $tail win=$($win.Left),$($win.Top) vis=$($win.IsVisible)"
  }
  $script:posLog++
  if (-not $script:followOn) {
    if (-not $win.IsVisible) { $win.Show() }
    Set-AlwaysOnTop
    Sync-KbPosition
    return
  }
  $cw = [double]$win.Width
  $ch = [double]$win.Height
  if (-not $rect) {
    # WorkBuddy 最小化或没开：贴到桌面右下角，别让宠物消失
    $area = [System.Windows.SystemParameters]::WorkArea
    $win.Left = [double]($area.Right - $cw - 24)
    $win.Top = [double]($area.Bottom - $ch - 40)
    if (-not $win.IsVisible) { $win.Show() }
    Set-AlwaysOnTop
    Sync-KbPosition
    return
  }
  $win.Left = [double]($rect.Right - $cw - 20)
  $win.Top = [double]($rect.Bottom - $ch - 96)
  if (-not $win.IsVisible) { $win.Show() }
  Set-AlwaysOnTop
  Sync-KbPosition
}

# 浮窗移动/换尺寸后，知识库窗口跟着重新贴边，别被宠物压住
function Sync-KbPosition {
  if (-not $script:KbWin) { return }
  if (-not $script:KbWin.IsVisible) { return }
  try { Reposition-KbWindow } catch { }
}

Update-Position 3>$null
$followTimer = New-Object System.Windows.Threading.DispatcherTimer
$followTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$followTimer.Add_Tick({ try { Update-Position } catch { } })
$followTimer.Start()

# 设置面板里的三只小头像（预览和实机都要先填好）
foreach ($b in @(@('ThumbQiqi', 'mingqiqi'), @('ThumbLingling', 'minglingling'), @('ThumbBaobao', 'mingbaobao'))) {
  $img = $win.FindName($b[0])
  $img.Source = Load-Bmp (Join-Path $Frames "$($b[1])-idle.png")
}

# ---------- 预览 ----------
if ($Preview) {
  $script:idx = 0
  Apply-Item $items[0]
  $idle = Load-Bmp (Join-Path $Frames "$($script:petId)-idle.png")
  if ($idle) { $pet.Source = $idle }
  $card.Opacity = 1
  $pw = $W
  $ph = $H
  if ($Compact) {
    $script:showCard = $false
    $card.Visibility = 'Collapsed'
    $bubble.Visibility = 'Visible'
    $bubble.Opacity = 1
    $bubbleText.Text = [string]$shortItems[0].text
    $bubbleDot.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#43A047'))
    $pet.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $pet.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    $pet.Margin = New-Object System.Windows.Thickness 0, 0, 4, 8
    $pw = 252
    $ph = 300
  }
  if ($PreviewPanel) {
    # 预览设置面板，而不是景点卡片
    $win.FindName('CardView').Visibility = 'Collapsed'
    $win.FindName('PanelView').Visibility = 'Visible'
    $ph = 396
  }
  $win.Width = $pw; $win.Height = $ph
  $win.Show(); $win.UpdateLayout(); $win.Hide()
  $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ($pw*2), ($ph*2), 192, 192, ([System.Windows.Media.PixelFormats]::Pbgra32)
  $visual = $win.Content
  $visual.Measure((New-Object System.Windows.Size $pw, $ph))
  $visual.Arrange((New-Object System.Windows.Rect 0, 0, $pw, $ph))
  $visual.UpdateLayout()
  $rtb.Render($visual)
  $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $out = if ($OutFile) { $OutFile } else { Join-Path $PSScriptRoot 'preview.png' }
  $fs = [System.IO.File]::Create($out)
  $enc.Save($fs); $fs.Close()
  Write-Output "预览已生成：$out"
  return
}

# ---------- 显示 ----------
Apply-Pet $script:petId
Update-Chip
$followText.Text = if ($script:followOn) { '跟随 WorkBuddy' } else { '手动摆放' }
Apply-Layout

# 上次是手动摆放，就回到上次的位置
if (-not $script:followOn -and $null -ne $script:savedLeft -and $null -ne $script:savedTop) {
  $win.Left = [double]$script:savedLeft
  $win.Top = [double]$script:savedTop
}

$win.Show()
$win.UpdateLayout()
$win.InvalidateVisual()
Write-PetLog ("show: pet=$($script:petId) carousel=$($script:carouselOn) follow=$($script:followOn) pos=$([int]$win.Left),$([int]$win.Top)")

# 启动时先摸一遍已绑定的库，后面增量自查要用
try { Get-KbRoots | Out-Null } catch { }
# 每 10 分钟自查一次：文件改过了就后台重建索引，不然问到的还是旧答案
$kbWatchTimer = New-Object System.Windows.Threading.DispatcherTimer
$kbWatchTimer.Interval = [TimeSpan]::FromMinutes(10)
$kbWatchTimer.Add_Tick({ try { Invoke-KbRefresh } catch { } })
$kbWatchTimer.Start()

# 全局热键：Ctrl+Alt+K 直接打开知识库，不用一层层点面板
Add-Type -Namespace HotKey -Name Reg -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
'@
$script:HotMods = 0x0001 -bor 0x0002   # MOD_ALT | MOD_CONTROL
$script:HotVk = 0x4B                  # 'K'
$script:HotOk = $false
try {
  $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  $script:HotOk = [HotKey.Reg]::RegisterHotKey($hwnd, 1, $script:HotMods, $script:HotVk)
  Write-PetLog "hotkey Ctrl+Alt+K -> $($script:HotOk)"
  if ($script:HotOk) {
    $hkScript = {
      param($h, $msg, $w, $l, $handled)
      if ($msg -eq 0x0312) {
        # 一定要吞掉内部输出，否则返回值和 IntPtr 混成数组，hook 会报转换错误
        try { Show-KbWindow | Out-Null } catch { Write-PetLog "hotkey err: $($_.Exception.Message)" }
        Write-PetLog 'hotkey Ctrl+Alt+K'
      }
      return [IntPtr]::Zero
    }
    $src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
    [void]$src.AddHook([System.Windows.Interop.HwndSourceHook]$hkScript)
  }
} catch { Write-PetLog "hotkey setup failed: $($_.Exception.Message)" }
$win.Add_Closed({ try { [void][HotKey.Reg]::UnregisterHotKey(0, 1) } catch { } })

# 首帧之后再读一次知识库状态，别拖慢浮窗出现
Update-KbChip
$kbInit = New-Object System.Windows.Threading.DispatcherTimer
$kbInit.Interval = [TimeSpan]::FromMilliseconds(700)
$kbInit.Add_Tick({
  $script:kbInit.Stop()
  try { Get-KbRoots | Out-Null } catch { }
})
$script:kbInit = $kbInit
$kbInit.Start()

# 扩展样式：不抢焦点 + 工具窗口（不进 Alt+Tab）；不再整窗穿透，改成按区域命中
Add-Type -Namespace Ex -Name Style -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
'@
$hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
if ($hwnd -ne [IntPtr]::Zero) {
  $GWL_EXSTYLE = -20
  $WS_EX_NOACTIVATE = 0x08000000
  $WS_EX_TOOLWINDOW = 0x00000080
  $st = [Ex.Style]::GetWindowLong($hwnd, $GWL_EXSTYLE)
  $st = $st -bor $WS_EX_NOACTIVATE -bor $WS_EX_TOOLWINDOW
  # 确保没有 WS_EX_TRANSPARENT，否则鼠标消息根本到不了窗口
  $st = $st -band (-bnot 0x00000020)
  [void][Ex.Style]::SetWindowLong($hwnd, $GWL_EXSTYLE, $st)
  # 改过扩展样式必须让系统重新算一遍窗口框架，否则分层窗口（AllowsTransparency）
  # 在某些环境（典型是 Windows PowerShell 5.1 起的进程）里会合成成全透明、什么都不画。
  # SWP_FRAMECHANGED|NOMOVE|NOSIZE|NOZORDER
  [void][Native.Win]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0020 -bor 0x0002 -bor 0x0001 -bor 0x0004)
  $win.UpdateLayout()
  $win.InvalidateVisual()
  # 再兜一层：200ms 后强制重画一次（首帧时序在某些机器上还是空）
  $repaint = New-Object System.Windows.Threading.DispatcherTimer
  $repaint.Interval = [TimeSpan]::FromMilliseconds(200)
  $repaint.Add_Tick({
    $script:repaint.Stop()
    try { $win.InvalidateVisual(); $win.UpdateLayout() } catch { }
    $h2 = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    if ($h2 -ne [IntPtr]::Zero) { [void][Native.Win]::SetWindowPos($h2, [IntPtr]::Zero, 0, 0, 0, 0, 0x0020 -bor 0x0002 -bor 0x0001 -bor 0x0004) }
  })
  $script:repaint = $repaint
  $repaint.Start()
}

# 只在"卡片"和"宠物"范围内接收鼠标，其余交给下面窗口（输入框照样能点）
$src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
if ($src) {
  $src.AddHook({
    param($h, $msg, $wParam, $lParam, $handled)
    if ($msg -eq 0x0084) {
      $v = $lParam.ToInt64()
      $sx = [int]($v -band 0xFFFF); if ($sx -ge 32768) { $sx -= 65536 }
      $sy = [int](($v -shr 16) -band 0xFFFF); if ($sy -ge 32768) { $sy -= 65536 }
      $rx = $sx - [int]$win.Left
      $ry = $sy - [int]$win.Top
      $cw = [int]$win.Width
      $ch = [int]$win.Height
      if ($script:showCard) {
        $hitCard = ($rx -ge 8 -and $rx -le 302 -and $ry -ge 0 -and $ry -le $ch)
        $hitPet = ($rx -ge 320 -and $rx -le $cw -and $ry -ge 50 -and $ry -le $ch)
      } else {
        # 精简模式：整块小窗都可点（标签 + 宠物），不留穿透缝
        $hitCard = $false
        $hitPet = ($rx -ge 4 -and $rx -le ($cw - 4) -and $ry -ge 0 -and $ry -le $ch)
      }
      if ($hitCard -or $hitPet) { $handled = $true; return [IntPtr]::new(1) }   # HTCLIENT
      $handled = $true; return [IntPtr]::new(-1)                                 # HTTRANSPARENT
    }
    return [IntPtr]::Zero
  })
}

# 未处理异常兜底：记日志，别让浮窗消失
$win.Dispatcher.add_UnhandledException({
  param($s, $e)
  Write-PetLog ('未处理异常: ' + $e.Exception.Message)
  $e.Handled = $true
})

$breathe.Begin($pet)
Show-NextLine
if ($script:carouselOn) { $lineTimer.Start() }
$script:actTimer.Start()
[System.Windows.Threading.Dispatcher]::Run()
