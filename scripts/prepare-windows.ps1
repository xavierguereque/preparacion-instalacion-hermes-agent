<#
=============================================================================
  Preparación para Hermes Agent · Windows
  Diagnostica, instala solo lo que falta y reanuda donde se quedó.

  Uso (PowerShell, sin necesidad de Administrador):
    irm https://raw.githubusercontent.com/xavierguereque/preparacion-instalacion-hermes-agent/main/scripts/prepare-windows.ps1 | iex
  Con opciones:
    & ([scriptblock]::Create((irm <URL>))) -CheckOnly
  Doble clic:
    windows\Preparar-Hermes.bat

  Compatible con Windows PowerShell 5.1 y PowerShell 7+.
=============================================================================
#>
param(
  [switch]$CheckOnly,
  [switch]$Yes,
  [switch]$NoHermes,
  [switch]$Reset,
  [switch]$NoColor
)

$PrepVersion      = '1.0.0'
$HermesInstallUrl = 'https://hermes-agent.nousresearch.com/install.ps1'
if ($env:HERMES_PREP_YES -eq '1')        { $Yes = $true }
if ($env:HERMES_PREP_CHECK_ONLY -eq '1') { $CheckOnly = $true }
if ($env:HERMES_PREP_NO_HERMES -eq '1')  { $NoHermes = $true }

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'   # acelera Invoke-WebRequest en PS 5.1
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# Forzar TLS 1.2 en esta sesión (PS 5.1 a veces arranca solo con TLS 1.0)
$script:TlsWasOn = $true
try {
  $sp = [Net.ServicePointManager]::SecurityProtocol
  if (($sp -ne 0) -and (($sp -band [Net.SecurityProtocolType]::Tls12) -eq 0)) {
    $script:TlsWasOn = $false
    [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12
  }
} catch {}

# =============================================================================
#  UI
# =============================================================================
$script:IsTty = -not [Console]::IsOutputRedirected
$Fancy = ($env:WT_SESSION -or $PSVersionTable.PSVersion.Major -ge 7)
function C([int]$code) { return [string][char]$code }
if ($Fancy) {
  $G_OK = C 0x2714; $G_WARN = C 0x26A0; $G_ERR = C 0x2716; $G_SKIP = C 0x21B7; $G_TODO = C 0x2022
  $SpinFrames = @(0x280B,0x2819,0x2839,0x2838,0x283C,0x2834,0x2826,0x2827,0x2807,0x280F) | ForEach-Object { C $_ }
} else {
  $G_OK = C 0x221A; $G_WARN = '!'; $G_ERR = C 0x00D7; $G_SKIP = '>'; $G_TODO = '*'
  $SpinFrames = @('|','/','-','\')
}
$B_FULL = C 0x2588; $B_EMPTY = C 0x2591
$H_LINE = C 0x2550; $V_LINE = C 0x2551; $C_TL = C 0x2554; $C_TR = C 0x2557; $C_BL = C 0x255A; $C_BR = C 0x255D
$Ellipsis = C 0x2026; $Dash = C 0x2014

$StateDir  = Join-Path $env:LOCALAPPDATA 'hermes-prep'
$StateFile = Join-Path $StateDir 'state'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# Log de cada ejecución en Descargas\hermes-prep-logs (para compartirlo si algo falla)
function Get-DownloadsDir {
  try {
    $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
    if ($p) { $p = [Environment]::ExpandEnvironmentVariables($p); if (Test-Path $p) { return $p } }
  } catch {}
  return (Join-Path $HOME 'Downloads')
}
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir   = Join-Path (Get-DownloadsDir) 'hermes-prep-logs'
$LogFile  = Join-Path $LogDir "hermes-prep-$RunStamp.log"
try {
  New-Item -ItemType Directory -Force -Path $LogDir -ErrorAction Stop | Out-Null
  Add-Content -Path $LogFile -Value '' -Encoding UTF8 -ErrorAction Stop
} catch {
  $LogDir = $StateDir; $LogFile = Join-Path $StateDir "hermes-prep-$RunStamp.log"
}

function W([string]$text, [string]$color = '') {
  if ($NoColor -or -not $color) { Write-Host -NoNewline $text } else { Write-Host -NoNewline $text -ForegroundColor $color }
}
function WL([string]$text = '', [string]$color = '') { W $text $color; Write-Host '' }
function Log([string]$m) { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 }

function Pad([string]$s, [int]$w) {
  if ($null -eq $s) { $s = '' }
  if ($s.Length -gt $w) { return $s.Substring(0, $w - 1) + $Ellipsis }
  return $s.PadRight($w)
}
function ConsoleWidth { try { return [Math]::Max(60, $Host.UI.RawUI.WindowSize.Width - 1) } catch { return 100 } }
function ClearLine { if ($script:IsTty) { W ("`r" + (' ' * (ConsoleWidth)) + "`r") } }

function Write-Bar([int]$done, [int]$total, [int]$w = 28) {
  if ($total -le 0) { $total = 1 }
  $fill = [int][Math]::Floor($done * $w / $total)
  W ($B_FULL * $fill) 'Green'
  W ($B_EMPTY * ($w - $fill)) 'DarkGray'
}
function Pct([int]$d, [int]$t) { if ($t -le 0) { return 100 }; return [Math]::Floor($d * 100 / $t) }

function Show-Banner([string]$title) {
  $w = 56
  WL ''
  WL (' ' + $C_TL + ($H_LINE * $w) + $C_TR) 'Cyan'
  W (' ' + $V_LINE + ' ') 'Cyan'; W (Pad $title ($w - 2)) 'White'; WL (' ' + $V_LINE) 'Cyan'
  WL (' ' + $C_BL + ($H_LINE * $w) + $C_BR) 'Cyan'
}
function Show-Section([string]$t, [string]$sub = '') { WL ''; W (' ' + $t + ' ') 'Magenta'; WL $sub 'DarkGray' }

$script:CurPos = 1; $script:CurTotal = 1; $script:CurLabel = ''

function Draw-Progress([int]$pos, [int]$total, [string]$frame, [string]$label, [string]$action, [string]$secs = '') {
  if (-not $script:IsTty) { return }
  $done = [Math]::Max(0, $pos - 1)
  W ("`r" + (' ' * (ConsoleWidth)) + "`r")
  W (" [{0}/{1}] " -f $pos, $total) 'White'
  W ($frame + ' ') 'Cyan'
  W ((Pad $label 18) + ' ')
  W ((Pad $action 26) + '  ') 'DarkGray'
  Write-Bar $done $total 20
  W (" {0,3}% " -f (Pct $done $total)) 'White'
  if ($secs) { W ($secs + 's') 'DarkGray' }
}

# Show-Row <ok|done|skip|update|missing|warn|fail> <etiqueta> <versión> <mensaje>
function Show-Row([string]$st, [string]$label, [string]$ver, [string]$msg) {
  switch ($st) {
    'ok'      { $g = $G_OK;   $c = 'Green';  $t = 'LISTO' }
    'done'    { $g = $G_OK;   $c = 'Green';  $t = 'LISTO' }
    'skip'    { $g = $G_SKIP; $c = 'Green';  $t = 'OMITIDO' }
    'update'  { $g = $G_WARN; $c = 'Yellow'; $t = 'ACTUALIZAR' }
    'missing' { $g = $G_TODO; $c = 'Yellow'; $t = 'FALTA' }
    'warn'    { $g = $G_WARN; $c = 'Yellow'; $t = 'AVISO' }
    default   { $g = $G_ERR;  $c = 'Red';    $t = 'ERROR' }
  }
  if (-not $ver) { $ver = $Dash }
  Log ("[{0}] {1} | {2} | {3}" -f $t, $label, $ver, $msg)
  ClearLine
  W ('   ' + $g + ' ' + (Pad $t 10) + ' ') $c
  W ((Pad $label 22) + ' ')
  W ((Pad $ver 16) + ' ') 'DarkGray'
  WL $msg
}

function Ask-Yes([string]$q) {
  if ($Yes) { W ' ? ' 'Cyan'; W "$q "; WL '[S/n] s (-Yes)' 'DarkGray'; return $true }
  W ' ? ' 'Cyan'; W "$q "; W '[S/n] ' 'DarkGray'
  $a = Read-Host
  return ($a -eq '' -or $a -match '^(s|si|sí|y|yes)$')
}

# Ejecuta un programa externo con spinner; la salida va al log.
function Invoke-Spin([string]$action, [string]$file, [string[]]$argList) {
  Log ("RUN: {0} {1}" -f $file, ($argList -join ' '))
  $out = Join-Path $StateDir 'last.out'; $err = Join-Path $StateDir 'last.err'
  try {
    $p = Start-Process -FilePath $file -ArgumentList $argList -NoNewWindow -PassThru `
         -RedirectStandardOutput $out -RedirectStandardError $err
  } catch { Log "ERROR al iniciar: $_"; return 1 }
  $null = $p.Handle   # necesario para leer ExitCode en PS 5.1
  $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
  if (-not $script:IsTty) { WL ("   ... {0}: {1}" -f $script:CurLabel, $action) }
  while (-not $p.HasExited) {
    Draw-Progress $script:CurPos $script:CurTotal $SpinFrames[$i % $SpinFrames.Count] $script:CurLabel $action ([int]$sw.Elapsed.TotalSeconds)
    $i++; Start-Sleep -Milliseconds 120
  }
  $p.WaitForExit()
  foreach ($f in @($out, $err)) { if (Test-Path $f) { Get-Content $f -ErrorAction SilentlyContinue | Add-Content -Path $LogFile -Encoding UTF8 } }
  $rc = $p.ExitCode; if ($null -eq $rc) { $rc = 0 }
  Log "RC=$rc"
  return $rc
}

function Show-LogPath {
  WL ''
  W '   Log de esta ejecución: ' 'White'; WL $LogFile
  WL '   (si algo falló, comparte este archivo para diagnosticarlo)' 'DarkGray'
  WL ''
}

function Write-SystemInfo {
  $lines = @('--- Sistema ---')
  try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $lines += "SO: $($os.Caption) $($os.Version) build $($os.BuildNumber)" } catch { $lines += "SO: $([Environment]::OSVersion.VersionString)" }
  $lines += "Arquitectura: $($script:Arch) · PowerShell: $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
  $lines += "Usuario: $env:USERNAME · Admin: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
  $lines += "Opciones: CheckOnly=$CheckOnly Yes=$Yes NoHermes=$NoHermes · TLS previo: $($script:TlsWasOn)"
  $lines += "PATH: $env:Path"
  $lines += "--- Estado previo ($StateFile) ---"
  if (Test-Path $StateFile) { $lines += Get-Content $StateFile -Encoding UTF8 } else { $lines += '(sin estado previo)' }
  $lines += '---------------'
  Add-Content -Path $LogFile -Value $lines -Encoding UTF8
}

function Ver-Ge([string]$a, [string]$b) {
  try { return ([version]($a -replace '[^0-9.].*$','')) -ge ([version]$b) } catch { return $false }
}
function First-Version([string]$s) { $m = [regex]::Match([string]$s, '\d+(\.\d+)+'); if ($m.Success) { return $m.Value }; return '' }
function Has([string]$cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $links   = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
  $env:Path = ($machine, $user, $links -join ';')
}

# --- Estado persistente (key=value) ---
function Get-State([string]$k) {
  if (-not (Test-Path $StateFile)) { return '' }
  $line = Get-Content $StateFile -Encoding UTF8 | Where-Object { $_ -like "$k=*" } | Select-Object -Last 1
  if ($line) { return $line.Substring($k.Length + 1) }; return ''
}
function Set-State([string]$k, [string]$v) {
  $lines = @()
  if (Test-Path $StateFile) { $lines = @(Get-Content $StateFile -Encoding UTF8 | Where-Object { $_ -notlike "$k=*" }) }
  $lines += "$k=$v"
  Set-Content -Path $StateFile -Value $lines -Encoding UTF8
}

# =============================================================================
#  Requisitos de Windows
# =============================================================================
$Reqs = @(
  @{ Id = 'os';        Label = 'Windows';               Req = $true  },
  @{ Id = 'psver';     Label = 'PowerShell';            Req = $true  },
  @{ Id = 'tls';       Label = 'TLS 1.2';               Req = $true  },
  @{ Id = 'execpol';   Label = 'Política de ejecución'; Req = $true  },
  @{ Id = 'disk';      Label = 'Espacio en disco';      Req = $true  },
  @{ Id = 'net';       Label = 'Conexión a internet';   Req = $true  },
  @{ Id = 'winget';    Label = 'winget';                Req = $true  },
  @{ Id = 'longpaths'; Label = 'Rutas largas';          Req = $true  },
  @{ Id = 'vcredist';  Label = 'VC++ Redistributable';  Req = $false },
  @{ Id = 'git';       Label = 'Git';                   Req = $true  },
  @{ Id = 'node';      Label = 'Node.js + npm';         Req = $true  },
  @{ Id = 'python';    Label = 'Python 3.11+';          Req = $false },
  @{ Id = 'rg';        Label = 'ripgrep';               Req = $false },
  @{ Id = 'ffmpeg';    Label = 'FFmpeg';                Req = $false }
)
$NodeMin = 20; $PyMin = '3.11'; $GitMin = '2.25'; $DiskMinGB = 5; $DiskFailGB = 3

$script:Arch = 'AMD64'
try { $script:Arch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE } catch {}
$script:WgArch = 'x64'; if ($script:Arch -eq 'ARM64') { $script:WgArch = 'arm64' }

function Chk([string]$s, [string]$v, [string]$m) { $script:CS = $s; $script:CV = $v; $script:CM = $m }

function Check_os {
  $build = [Environment]::OSVersion.Version.Build
  $name = 'Windows'
  try { $name = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption -replace 'Microsoft ','' } catch {}
  if ($script:Arch -eq 'x86') { Chk 'fail' "$name x86" 'Windows de 32 bits no está soportado'; return }
  if ($build -lt 17763) { Chk 'fail' "build $build" 'se requiere Windows 10 1809 o superior'; return }
  Chk 'ok' "build $build $($script:Arch)" $name
}
function Check_psver {
  $v = $PSVersionTable.PSVersion
  if ($v -ge [version]'5.1') { Chk 'ok' "$($v.Major).$($v.Minor)" $PSVersionTable.PSEdition }
  else { Chk 'fail' "$v" 'actualiza a Windows PowerShell 5.1 (WMF 5.1)' }
}
function Check_tls {
  if ($script:TlsWasOn) { Chk 'ok' '' 'ya activo' } else { Chk 'ok' '' 'activado para esta sesión' }
}
function Get-EffectivePolicy {
  foreach ($scope in 'MachinePolicy','UserPolicy','CurrentUser','LocalMachine') {
    $p = Get-ExecutionPolicy -Scope $scope
    if ($p -ne 'Undefined') { return @{ Policy = [string]$p; Scope = $scope } }
  }
  return @{ Policy = 'Restricted'; Scope = 'predeterminada' }
}
function Check_execpol {
  $e = Get-EffectivePolicy
  if ($e.Policy -in @('RemoteSigned','Unrestricted','Bypass')) { Chk 'ok' $e.Policy "ámbito: $($e.Scope)"; return }
  if ($e.Scope -in @('MachinePolicy','UserPolicy')) { Chk 'fail' $e.Policy 'fijada por directiva de grupo; pide a TI RemoteSigned'; return }
  Chk 'update' $e.Policy 'npm.ps1 fallará; se cambiará a RemoteSigned (tu usuario)'
}
function Check_disk {
  $gb = 0
  try { $d = (Split-Path $env:LOCALAPPDATA -Qualifier).TrimEnd(':'); $gb = [Math]::Floor((Get-PSDrive $d).Free / 1GB) } catch {}
  if ($gb -lt $DiskFailGB)    { Chk 'fail' "$gb GB libres" "se necesitan al menos $DiskMinGB GB" }
  elseif ($gb -lt $DiskMinGB) { Chk 'warn' "$gb GB libres" "poco espacio; se recomiendan $DiskMinGB GB" }
  else                        { Chk 'ok'   "$gb GB libres" 'suficiente' }
}
function Test-Url([string]$h) {
  try { Invoke-WebRequest -Uri "https://$h" -Method Head -UseBasicParsing -TimeoutSec 12 | Out-Null; return $true }
  catch { if ($_.Exception.Response) { return $true }; return $false }
}
function Check_net {
  $bad = @()
  foreach ($h in 'github.com','raw.githubusercontent.com','hermes-agent.nousresearch.com') { if (-not (Test-Url $h)) { $bad += $h } }
  $ok = 3 - $bad.Count
  if ($bad.Count -eq 0) { Chk 'ok' '3/3 sitios' 'github y hermes accesibles' }
  elseif (($bad -join ' ') -match 'github') { Chk 'fail' "$ok/3 sitios" ("sin acceso a: " + ($bad -join ', ') + ' (revisa proxy/antivirus)') }
  else { Chk 'warn' "$ok/3 sitios" ("sin acceso a: " + ($bad -join ', ')) }
}
function Check_winget {
  if (Has 'winget') { Chk 'ok' (First-Version (& winget --version 2>$null)) 'ya instalado' }
  else { Chk 'missing' '' 'se intentará registrar "App Installer"' }
}
function Check_longpaths {
  $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
  if ($v -eq 1) { Chk 'ok' 'activadas' 'evita "Filename too long"' }
  else { Chk 'missing' 'desactivadas' 'se activarán (pedirá permiso de Administrador)' }
}
function Check_vcredist {
  $keys = @("HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$($script:WgArch)",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\$($script:WgArch)")
  foreach ($k in $keys) {
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if ($p -and $p.Installed -eq 1) { Chk 'ok' (First-Version $p.Version) 'ya instalado'; return }
  }
  Chk 'missing' '' 'se instalará'
}
function Check_git {
  if (-not (Has 'git')) { Chk 'missing' '' 'se instalará'; return }
  $v = First-Version (& git --version 2>$null)
  if (Ver-Ge $v $GitMin) { Chk 'ok' $v 'ya instalado' } else { Chk 'update' $v "versión menor a $GitMin" }
}
function Check_node {
  if (-not (Has 'node')) { Chk 'missing' '' 'se instalará Node.js LTS'; return }
  $v = First-Version (& node -v 2>$null)
  $major = 0; try { $major = [int]($v.Split('.')[0]) } catch {}
  $npmv = ''
  if (Has 'npm.cmd') { $npmv = First-Version (& npm.cmd -v 2>$null) }
  if ($major -lt $NodeMin) { Chk 'update' $v "menor a v$NodeMin"; return }
  if (-not $npmv) { Chk 'update' $v 'npm no responde'; return }
  Chk 'ok' $v "npm $npmv"
}
function Find-Python {
  $best = ''; $src = ''
  $cands = @()
  if (Has 'py') { $cands += ,@('py', '-3') }
  Get-Command python, python3 -All -ErrorAction SilentlyContinue |
    Where-Object { $_.Source -notmatch 'WindowsApps' } |
    ForEach-Object { $cands += ,@($_.Source, '') }
  foreach ($c in $cands) {
    try {
      if ($c[1]) { $out = & $c[0] $c[1] --version 2>&1 } else { $out = & $c[0] --version 2>&1 }
      $v = First-Version ([string]$out)
      if ($v -and (-not $best -or -not (Ver-Ge $best $v))) { $best = $v; $src = Split-Path $c[0] -Leaf }
    } catch {}
  }
  return @{ V = $best; Src = $src }
}
function Check_python {
  $p = Find-Python
  if (-not $p.V) { Chk 'missing' '' 'se instalará (el alias de Microsoft Store no cuenta)'; return }
  if (Ver-Ge $p.V $PyMin) { Chk 'ok' $p.V $p.Src } else { Chk 'update' $p.V "versión menor a $PyMin" }
}
function Check_rg {
  if (Has 'rg') { Chk 'ok' (First-Version (& rg --version 2>$null | Select-Object -First 1)) 'ya instalado' } else { Chk 'missing' '' 'se instalará' }
}
function Check_ffmpeg {
  if (Has 'ffmpeg') { Chk 'ok' (First-Version (& ffmpeg -version 2>$null | Select-Object -First 1)) 'ya instalado' } else { Chk 'missing' '' 'se instalará' }
}

# =============================================================================
#  Instaladores (devuelven $true si el paso terminó sin error)
# =============================================================================
function Winget-Install([string]$id, [string[]]$extra = @()) {
  if (-not (Has 'winget')) { $script:CM = 'requiere winget, que no está disponible'; return $false }
  $wg = (Get-Command winget).Source
  $args2 = @('install', '--id', $id, '-e', '--source', 'winget', '--silent',
             '--accept-package-agreements', '--accept-source-agreements') + $extra
  $rc = Invoke-Spin "winget install $id" $wg $args2
  Refresh-Path
  # 0 = ok · -1978335189 / -1978335135 = ya instalado / sin actualización
  return ($rc -eq 0 -or $rc -eq -1978335189 -or $rc -eq -1978335135)
}

function Install_os     { return $false }
function Install_psver  { return $false }
function Install_tls    { return $true }
function Install_disk   { return $false }
function Install_net    { return $false }
function Install_execpol {
  Draw-Progress $script:CurPos $script:CurTotal $SpinFrames[0] $script:CurLabel 'Set-ExecutionPolicy RemoteSigned'
  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue
  return $true
}
function Install_winget {
  Draw-Progress $script:CurPos $script:CurTotal $SpinFrames[0] $script:CurLabel 'registrando App Installer'
  try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch { Log "Add-AppxPackage: $_" }
  Refresh-Path
  $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
  if (-not (Has 'winget')) {
    $script:CM = 'instala "App Installer" desde Microsoft Store (ms-windows-store://pdp/?productid=9NBLGGH4NNS1)'
    return $false
  }
  return $true
}
function Install_longpaths {
  ClearLine
  W '   '; W $G_TODO 'Cyan'; WL ' Windows pedirá permiso de Administrador para activar las rutas largas.'
  $cmd = "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -Type DWord"
  try {
    $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
         -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -ErrorAction Stop
  } catch { $script:CM = 'se canceló el permiso de Administrador'; Log "longpaths: $_"; return $false }
  if (Has 'git') { & git config --global core.longpaths true 2>$null }
  Set-State 'step_longpaths' 'pending_restart'
  return $true
}
function Install_vcredist { return (Winget-Install "Microsoft.VCRedist.2015+.$($script:WgArch)") }
function Install_git {
  $ok = Winget-Install 'Git.Git'
  if (Has 'git') { & git config --global core.longpaths true 2>$null }
  return $ok
}
function Install_node   { return (Winget-Install 'OpenJS.NodeJS.LTS') }
function Install_python {
  if (Winget-Install 'Python.Python.3.12' @('--scope', 'user')) { return $true }
  return (Winget-Install 'Python.Python.3.12')
}
function Install_rg     { return (Winget-Install 'BurntSushi.ripgrep.MSVC') }
function Install_ffmpeg { return (Winget-Install 'Gyan.FFmpeg') }

# =============================================================================
#  Motor: diagnóstico → instalación → verificación
# =============================================================================
$script:Res = @{}

function Run-Diagnosis([string]$title) {
  $n = $Reqs.Count
  Show-Section $title "($n verificaciones)"
  for ($i = 0; $i -lt $n; $i++) {
    $r = $Reqs[$i]
    $script:CurPos = $i + 1; $script:CurTotal = $n; $script:CurLabel = $r.Label
    Draw-Progress ($i + 1) $n $SpinFrames[0] $r.Label "revisando$Ellipsis"
    & ("Check_" + $r.Id)
    $script:Res[$r.Id] = @{ S = $script:CS; V = $script:CV; M = $script:CM }
    Show-Row $script:CS $r.Label $script:CV $script:CM
  }
  if ($script:IsTty) { W '   '; Write-Bar $n $n 40; WL (" $n/$n") 'White' }
}
function Count-Status([string]$s) { return @($Reqs | Where-Object { $script:Res[$_.Id].S -eq $s }).Count }
function Get-Blockers { return @($Reqs | Where-Object { $_.Req -and ($script:Res[$_.Id].S -notin @('ok','warn')) }) }

function Show-DiagSummary {
  WL ''
  W '   Resultado: '
  W ("{0} listos" -f (Count-Status 'ok')) 'Green'; W ' · '
  W ("{0} por actualizar" -f (Count-Status 'update')) 'Yellow'; W ' · '
  W ("{0} por instalar" -f (Count-Status 'missing')) 'Yellow'; W ' · '
  W ("{0} avisos" -f (Count-Status 'warn')) 'Yellow'; W ' · '
  WL ("{0} bloqueantes" -f (Count-Status 'fail')) 'Red'
}

function Show-ResumeNotice {
  $st = Get-State 'run_status'; $last = Get-State 'last_step'
  if ($st -notin @('running','interrupted','incomplete') -or -not $last) { return }
  $lbl = $last; foreach ($r in $Reqs) { if ($r.Id -eq $last) { $lbl = $r.Label } }
  WL ''
  W (" $G_WARN Se detectó una ejecución anterior sin terminar") 'Yellow'
  WL (" en [{0}/{1}] {2} ({3})." -f (Get-State 'last_pos'), (Get-State 'last_total'), $lbl, (Get-State 'last_run'))
  WL '   Continuando desde ahí: lo que ya se instaló se omitirá.'
}

function Install-Pending {
  $pending = @($Reqs | Where-Object { $script:Res[$_.Id].S -in @('update','missing') })
  $total = $pending.Count; if ($total -eq 0) { return }
  Show-Section 'INSTALACIÓN' "(solo los $total pendientes)"
  Set-State 'run_status' 'running'
  Set-State 'last_run' (Get-Date -Format 'yyyy-MM-dd HH:mm')
  $pos = 0
  foreach ($r in $Reqs) {
    $res = $script:Res[$r.Id]
    if ($res.S -notin @('update','missing')) { Show-Row 'skip' $r.Label $res.V 'ya estaba listo'; continue }
    $pos++
    $script:CurPos = $pos; $script:CurTotal = $total; $script:CurLabel = $r.Label
    Set-State 'last_step' $r.Id; Set-State 'last_pos' $pos; Set-State 'last_total' $total
    Set-State ("step_" + $r.Id) 'running'
    Draw-Progress $pos $total $SpinFrames[0] $r.Label "preparando$Ellipsis"

    & ("Check_" + $r.Id)
    if ($script:CS -eq 'ok') {
      $script:Res[$r.Id] = @{ S = 'ok'; V = $script:CV; M = $script:CM }
      Set-State ("step_" + $r.Id) 'ok'
      Show-Row 'done' $r.Label $script:CV 'resuelto por un paso anterior'; continue
    }

    $script:CM = ''
    $okInst = & ("Install_" + $r.Id)
    $imsg = $script:CM
    & ("Check_" + $r.Id)
    if (-not $okInst -and $script:CS -ne 'ok' -and $imsg) { $script:CM = $imsg }
    $script:Res[$r.Id] = @{ S = $script:CS; V = $script:CV; M = $script:CM }
    if ($script:CS -in @('ok','warn')) {
      if ((Get-State ("step_" + $r.Id)) -ne 'pending_restart') { Set-State ("step_" + $r.Id) 'ok' }
      Show-Row 'done' $r.Label $script:CV 'instalado'
    } else {
      if ((Get-State ("step_" + $r.Id)) -ne 'pending_restart') { Set-State ("step_" + $r.Id) 'failed' }
      $script:Res[$r.Id].S = 'fail'
      $m = $script:CM; if (-not $m) { $m = 'falló la instalación' }
      Show-Row 'fail' $r.Label $script:CV "$m (ver log)"
      if ($script:IsTty -and (Test-Path $LogFile)) {
        Get-Content $LogFile -Tail 4 | ForEach-Object { WL ("        | " + $_) 'DarkGray' }
      }
    }
  }
  if ($script:IsTty) { W '   '; Write-Bar $total $total 40; WL ' 100%' 'White' }
}

function Start-HermesInstall {
  $exe = (Get-Process -Id $PID).Path
  $cmd = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; irm $HermesInstallUrl | iex"
  Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -NoNewWindow -Wait
}

function Main {
  if ($Reset) { Remove-Item $StateFile -ErrorAction SilentlyContinue; WL ' Estado reiniciado.' }
  Add-Content -Path $LogFile -Encoding UTF8 -Value ("===== {0} · hermes-prep {1} · Windows =====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PrepVersion)
  Write-SystemInfo
  Show-Banner "Preparación para Hermes Agent · Windows $($script:Arch)"
  WL ("   v$PrepVersion · log: $LogFile") 'DarkGray'

  Show-ResumeNotice
  Run-Diagnosis '1) DIAGNÓSTICO'
  Show-DiagSummary

  if ($CheckOnly) {
    WL ''; WL '   Modo -CheckOnly: no se instaló nada.'
    Log 'RESULTADO: check-only'; Show-LogPath
    if ((Get-Blockers).Count -eq 0) { return 0 } else { return 1 }
  }

  $hard = @($Reqs | Where-Object { $_.Req -and $script:Res[$_.Id].S -eq 'fail' })
  if ($hard.Count -gt 0) {
    WL ''; WL " $G_ERR Hay requisitos que el script no puede resolver solo:" 'Red'
    foreach ($r in $hard) { WL ("     • {0}: {1}" -f $r.Label, $script:Res[$r.Id].M) }
    WL '   Corrígelos y vuelve a ejecutar.'
    Set-State 'run_status' 'incomplete'
    Log 'RESULTADO: bloqueado'; Show-LogPath; return 1
  }

  $pending = (Count-Status 'update') + (Count-Status 'missing')
  if ($pending -gt 0) {
    WL ''
    if (-not (Ask-Yes "¿Instalar/actualizar los $pending pendientes?")) { WL '   Cancelado. No se instaló nada.'; Log 'RESULTADO: cancelado'; Show-LogPath; return 0 }
    Install-Pending
    Run-Diagnosis '2) VERIFICACIÓN FINAL'
  } else {
    WL ''; WL "   $G_OK Todo lo necesario ya estaba instalado." 'Green'
  }

  $blockers = Get-Blockers
  WL ''
  if ($blockers.Count -eq 0) {
    Set-State 'run_status' 'done'
    WL " $G_OK TODO LISTO: el equipo cumple los requisitos de Hermes Agent $G_OK" 'Green'
    if (((Count-Status 'warn') + (Count-Status 'fail')) -gt 0) { WL '   (Hay avisos en elementos recomendados; no impiden instalar.)' 'DarkGray' }
    if ((Get-State 'step_longpaths') -eq 'pending_restart') { WL '   Nota: si ves "Filename too long", cierra sesión de Windows y vuelve a entrar.' 'DarkGray' }
    WL ''
    if ($NoHermes) {
      WL "   Para instalar Hermes Agent:  irm $HermesInstallUrl | iex"
    } elseif (Ask-Yes '¿Instalar Hermes Agent ahora?') {
      Start-HermesInstall
      WL ''; WL '   Abre una ventana nueva de PowerShell para que el comando "hermes" quede disponible.' 'DarkGray'
    } else {
      WL "   Cuando quieras:  irm $HermesInstallUrl | iex"
    }
    Log 'RESULTADO: todo listo'; Show-LogPath
    return 0
  } else {
    Set-State 'run_status' 'incomplete'
    WL " $G_ERR Faltan requisitos obligatorios:" 'Red'
    foreach ($r in $blockers) { WL ("     • {0}: {1}" -f $r.Label, $script:Res[$r.Id].M) }
    WL '   Vuelve a ejecutar: continuará donde se quedó.'
    Log 'RESULTADO: faltan requisitos'; Show-LogPath
    return 1
  }
}

$script:Finished = $false
$code = 1
try {
  $code = @(Main)[-1]
  $script:Finished = $true
} finally {
  if (-not $script:Finished) {
    if ((Get-State 'run_status') -eq 'running') { Set-State 'run_status' 'interrupted' }
    WL ''
    WL (" $G_WARN Interrumpido en [{0}/{1}] {2}." -f $script:CurPos, $script:CurTotal, $script:CurLabel) 'Yellow'
    WL '   Vuelve a ejecutar el mismo comando para continuar desde ahí.'
    Log ("RESULTADO: interrumpido en " + $script:CurLabel); Show-LogPath
  }
}
# Solo salir con código cuando se ejecuta como archivo (con "irm | iex" cerraría la ventana)
if ($PSCommandPath) { exit $code }
