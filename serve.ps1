param([int]$Port = 18926)
Set-Location $PSScriptRoot
$root = $PSScriptRoot

# WT saves 目录（固定位置，跨用户可用）
$WT_USER = $env:USERPROFILE
$WT_SAVES = Join-Path $WT_USER 'Documents\My Games\WarThunder\Saves\127406542\production\UserSights\all_tanks'
Write-Host "WT saves dir: $WT_SAVES"
if (-not (Test-Path $WT_SAVES)) {
    Write-Host "WARN: WT saves dir not found, deploy API will fail until WT launches once"
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Host "Serving $root on http://127.0.0.1:$Port/"

function Get-Mime([string]$path) {
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -eq '.html') { return 'text/html; charset=utf-8' }
    if ($ext -eq '.htm')  { return 'text/html; charset=utf-8' }
    if ($ext -eq '.js')   { return 'application/javascript; charset=utf-8' }
    if ($ext -eq '.mjs')  { return 'application/javascript; charset=utf-8' }
    if ($ext -eq '.cjs')  { return 'application/javascript; charset=utf-8' }
    if ($ext -eq '.css')  { return 'text/css; charset=utf-8' }
    if ($ext -eq '.json') { return 'application/json; charset=utf-8' }
    if ($ext -eq '.wasm') { return 'application/wasm' }
    if ($ext -eq '.onnx') { return 'application/octet-stream' }
    if ($ext -eq '.png')  { return 'image/png' }
    if ($ext -eq '.jpg' -or $ext -eq '.jpeg') { return 'image/jpeg' }
    if ($ext -eq '.svg')  { return 'image/svg+xml' }
    if ($ext -eq '.ico')  { return 'image/x-icon' }
    return 'application/octet-stream'
}

function Write-Json($res, $obj) {
    $json = $obj | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $res.ContentType = 'application/json; charset=utf-8'
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

while ($listener.IsListening) {
    try {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    $res.Headers['Access-Control-Allow-Origin'] = '*'
    $res.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    $res.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
    
    $url = $req.Url.LocalPath
    if ($url -eq '/') { $url = '/wt-sight-studio.html' }
    
    # === API: POST /api/deploy  ===
    # Body: JSON { "name": "sight_1.blk", "data": "base64..." }
    if ($url -eq '/api/deploy' -and $req.HttpMethod -eq 'POST') {
        try {
            $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
            $body = $reader.ReadToEnd()
            $reader.Close()
            $json = $body | ConvertFrom-Json
            $name = $json.name
            $b64 = $json.data
            
            # 安全校验：文件名不能有路径分隔符
            if ($name -match '[/\\]' -or $name -match '\.\.') {
                Write-Json $res @{ ok=$false; err='Invalid filename' }
                continue
            }
            if (-not $name.EndsWith('.blk')) { $name += '.blk' }
            
            $bytes = [System.Convert]::FromBase64String($b64)
            
            # 确保 WT saves 目录存在
            if (-not (Test-Path $WT_SAVES)) {
                New-Item -ItemType Directory -Path $WT_SAVES -Force | Out-Null
            }
            
            $dest = Join-Path $WT_SAVES $name
            [System.IO.File]::WriteAllBytes($dest, $bytes)
            Write-Host "DEPLOY: $name ($($bytes.Length)B) -> $dest"
            Write-Json $res @{ ok=$true; path=$dest; size=$bytes.Length }
        } catch {
            Write-Host "DEPLOY ERROR: $($_.Exception.Message)"
            Write-Json $res @{ ok=$false; err=$_.Exception.Message }
        }
        $res.Close()
        continue
    }
    
    # === API: POST /api/launch (启动 WT) ===
    if ($url -eq '/api/launch' -and $req.HttpMethod -eq 'POST') {
        try {
            $wtExe = Get-ChildItem 'C:\' -Filter 'warthunder.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($wtExe) {
                Start-Process $wtExe.FullName
                Write-Host "LAUNCH: $($wtExe.FullName)"
                Write-Json $res @{ ok=$true; path=$wtExe.FullName }
            } else {
                # 尝试 Steam
                $steam = Get-ChildItem 'C:\' -Filter 'War Thunder.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($steam) {
                    Start-Process $steam.FullName
                    Write-Host "LAUNCH (Steam): $($steam.FullName)"
                    Write-Json $res @{ ok=$true; path=$steam.FullName }
                } else {
                    Write-Json $res @{ ok=$false; err='warthunder.exe not found' }
                }
            }
        } catch {
            Write-Json $res @{ ok=$false; err=$_.Exception.Message }
        }
        $res.Close()
        continue
    }
    
    # === API: GET /api/saves  ===
    if ($url -eq '/api/saves') {
        if (Test-Path $WT_SAVES) {
            $files = Get-ChildItem $WT_SAVES -Filter '*.blk' | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object {
                @{ name=$_.Name; size=$_.Length; mtime=$_.LastWriteTime.ToString('s') }
            }
            Write-Json $res @{ ok=$true; dir=$WT_SAVES; files=$files }
        } else {
            Write-Json $res @{ ok=$false; err='WT saves dir not found'; dir=$WT_SAVES }
        }
        $res.Close()
        continue
    }
    
    # === OPTIONS preflight ===
    if ($req.HttpMethod -eq 'OPTIONS') {
        $res.StatusCode = 204
        $res.Close()
        continue
    }
    
    # === 静态文件服务 ===
    $file = Join-Path $root $url.TrimStart('/')
    if ((Test-Path $file -PathType Leaf) -and -not (Test-Path $file -PathType Container)) {
        $mime = Get-Mime $file
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $res.ContentType = $mime
        $res.ContentLength64 = $bytes.Length
        if ($mime -match 'text/html|javascript|text/css') {
            $res.Headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
            $res.Headers['Pragma'] = 'no-cache'
            $res.Headers['Expires'] = '0'
        }
        if ($req.HttpMethod -ne 'HEAD') {
            try {
                $res.OutputStream.Write($bytes, 0, $bytes.Length)
            } catch {
                Write-Host "WARN client disconnected: $url ($($_.Exception.Message))"
            }
        }
        Write-Host "$($req.HttpMethod) $url -> $mime ($($bytes.Length)B)"
    } else {
        $res.StatusCode = 404
        try {
            $sw = New-Object System.IO.StreamWriter($res.OutputStream)
            $sw.Write("Not Found: $url")
            $sw.Close()
        } catch {}
        Write-Host "404 $url"
    }
    $res.Close()
    } catch {
        # 单个请求出错（含客户端取消下载/断连）绝不杀服务器进程
        Write-Host "REQ ERROR: $($_.Exception.Message)"
        try { $res.Close() } catch {}
    }
}
