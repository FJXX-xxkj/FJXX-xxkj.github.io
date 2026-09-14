# FJXX Auto Tunnel - keep a Cloudflare quick tunnel alive and publish its URL to GitHub.
# ASCII only. Runs as SYSTEM at startup.

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$Exe        = 'C:\cloudflared\cloudflared.exe.exe'
$WorkDir    = 'C:\cloudflared'
$OutLog     = Join-Path $WorkDir 'cf-out.log'
$ErrLog     = Join-Path $WorkDir 'cf-err.log'
$MainLog    = Join-Path $WorkDir 'tunnel-service.log'
$UrlFile    = Join-Path $WorkDir 'current-url.txt'
$PanUrlFile = 'C:\inetpub\wwwroot\pan\tunnel-url.txt'
$TokenFile  = Join-Path $WorkDir 'github-token.txt'
$Owner      = 'FJXX-xxkj'
$Repo       = 'FJXX-xxkj.github.io'
$RepoPath   = 'tunnel.json'
$Branch     = 'main'
$LocalUrl   = 'http://localhost:80'

function Log([string]$msg) {
  $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $msg
  try {
    if ((Test-Path -LiteralPath $MainLog) -and ((Get-Item -LiteralPath $MainLog).Length -gt 2MB)) {
      Remove-Item -LiteralPath $MainLog -Force -ErrorAction SilentlyContinue
    }
  } catch { }
  try { Add-Content -LiteralPath $MainLog -Value $line -Encoding UTF8 } catch { }
}

function Publish-Url([string]$url) {
  if (-not (Test-Path -LiteralPath $TokenFile)) { Log 'publish skip: token file missing'; return $false }
  $token = ''
  try { $token = (Get-Content -LiteralPath $TokenFile -Raw).Trim() } catch { }
  if ([string]::IsNullOrWhiteSpace($token)) { Log 'publish skip: token empty'; return $false }

  $api = 'https://api.github.com/repos/' + $Owner + '/' + $Repo + '/contents/' + $RepoPath
  $headers = @{
    Authorization = 'Bearer ' + $token
    'User-Agent'  = 'fjxx-tunnel'
    Accept        = 'application/vnd.github+json'
  }
  $payload = @{
    url     = $url
    updated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    host    = $env:COMPUTERNAME
  } | ConvertTo-Json -Compress

  for ($i = 1; $i -le 6; $i++) {
    try {
      $sha = $null
      try {
        $cur = Invoke-RestMethod -Uri ($api + '?ref=' + $Branch) -Headers $headers -Method Get -TimeoutSec 25
        if ($cur.sha) { $sha = $cur.sha }
      } catch { }
      $body = @{
        message = 'tunnel url auto update'
        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        branch  = $Branch
      }
      if ($sha) { $body.sha = $sha }
      Invoke-RestMethod -Uri $api -Headers $headers -Method Put -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 25 | Out-Null
      Log ('published to github: ' + $url)
      return $true
    } catch {
      Log ('publish failed (try ' + $i + '/6): ' + $_.Exception.Message)
      Start-Sleep -Seconds 15
    }
  }
  return $false
}

function Save-Url([string]$url) {
  try { Set-Content -LiteralPath $UrlFile -Value $url -Encoding ASCII } catch { }
  try { Set-Content -LiteralPath $PanUrlFile -Value $url -Encoding ASCII } catch { }
}

function Read-TunnelUrl {
  $txt = ''
  foreach ($f in @($OutLog, $ErrLog)) {
    try {
      if (Test-Path -LiteralPath $f) { $txt += [string](Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
    } catch { }
  }
  $m = [regex]::Match($txt, 'https://[a-z0-9-]+\.trycloudflare\.com')
  if ($m.Success) { return $m.Value }
  return $null
}

while ($true) {
  Log '---- service loop start ----'

  try { Get-Process -Name 'cloudflared*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch { }
  Start-Sleep -Seconds 3
  try { Remove-Item -LiteralPath $OutLog, $ErrLog -Force -ErrorAction SilentlyContinue } catch { }

  if (-not (Test-Path -LiteralPath $Exe)) {
    $alt = @('C:\Program Files (x86)\cloudflared\cloudflared.exe', 'C:\Program Files\cloudflared\cloudflared.exe') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($alt) { $Exe = $alt; Log ('using alternate exe: ' + $alt) }
  }
  if (-not (Test-Path -LiteralPath $Exe)) {
    Log ('exe not found: ' + $Exe + ' ; retry in 5 min')
    Start-Sleep -Seconds 300
    continue
  }

  Log 'starting cloudflared quick tunnel'
  $p = $null
  try {
    $p = Start-Process -FilePath $Exe -ArgumentList 'tunnel', '--url', $LocalUrl, '--no-autoupdate' -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -WindowStyle Hidden -PassThru
  } catch {
    Log ('start failed: ' + $_.Exception.Message)
    Start-Sleep -Seconds 30
    continue
  }

  $url = $null
  for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep -Seconds 1
    $url = Read-TunnelUrl
    if ($url) { break }
    try { if ($p.HasExited) { break } } catch { break }
  }

  if ($url) {
    Log ('tunnel url: ' + $url)
    Save-Url $url
  } else {
    Log 'tunnel url not detected within 90s'
  }

  $published = $false
  $lastTry = (Get-Date).AddMinutes(-10)
  while ($true) {
    try { if ($p.HasExited) { break } } catch { break }
    Start-Sleep -Seconds 30
    if ((-not $published) -and $url) {
      if (((Get-Date) - $lastTry).TotalMinutes -ge 5) {
        $lastTry = Get-Date
        $published = Publish-Url $url
      }
    }
  }

  Log 'tunnel process exited, restart in 10s'
  Start-Sleep -Seconds 10
}
