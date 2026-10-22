# 요약: 클라우드(GitHub Actions) 예약 게시 일꾼. 5분마다 깨어나 "시각이 된 예약"을 인스타 릴스 -> 스레드 순서로 올린다.
#       (PC의 09_도구\자동게시.ps1 과 같은 순서·같은 API. 모양만 클라우드용으로 단순화)
# 놓는 곳: 보관함(monggeul-videos)의 scripts/cloud-publish.ps1  (PowerShell 5.1 / 7 모두 동작)
# 인자: -Mode run(기본, 올리기) | check(읽기 전용 점검) / -Mock -RepoDir 폴더 (모의: 인터넷 요청 없이 폴더 안 파일로만 시험)
# 열쇠(Secrets)는 환경변수로만 받는다: INSTAGRAM_TOKEN THREADS_TOKEN INSTAGRAM_USER_ID THREADS_USER_ID (+ 자동 제공 GITHUB_TOKEN, GITHUB_REPOSITORY)
# 규칙: 비밀 값은 어디에도 출력·저장하지 않는다. 이 파일은 UTF-8 BOM 필수.
param(
    [string]$Mode = 'run',
    [switch]$Mock,
    [string]$RepoDir = '',
    [string]$FailAt = '',
    [string]$NowUtc = ''      # 모의 시험 전용: 지금 시각을 흉내 (예: 2026-10-22T13:00:00)
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$LateLimitMin = 60
$Expected = if ($env:EXPECTED_ACCOUNT) { $env:EXPECTED_ACCOUNT.ToLower() } else { 'monggeul.town' }
$Repo = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { 'monggeul-town/monggeul-videos' }
$Branch = if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { 'main' }
if ($Mock) {
    if (-not $RepoDir) { throw '모의 모드에는 -RepoDir 이 필요해요.' }
    $Base = [System.IO.Path]::GetFullPath($RepoDir)
    # 가짜 열쇠 (진짜 값이 아님)
    $env:INSTAGRAM_TOKEN = 'DRYRUN-FAKE-INSTAGRAM-TOKEN-0000'
    $env:THREADS_TOKEN = 'DRYRUN-FAKE-THREADS-TOKEN-00000'
    $env:GITHUB_TOKEN = 'DRYRUN-FAKE-GITHUB-TOKEN-0000'
} else {
    $Base = Split-Path -Parent $PSScriptRoot
}
$SchedDir = Join-Path $Base 'schedules'
$ResDir = Join-Path $Base 'results'
$script:Alert = $false
$script:Log = @()
$script:MockCount = @{}
$script:Sha = @{}

# ---------- 도우미 ----------
function Get-Now { if ($NowUtc) { return [datetime]::SpecifyKind([datetime]::Parse($NowUtc), 'Utc') } else { return [datetime]::UtcNow } }
function Hide-Secrets {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($k in @('INSTAGRAM_TOKEN', 'THREADS_TOKEN', 'GITHUB_TOKEN')) {
        $v = [string](Get-Item -LiteralPath ('Env:' + $k) -ErrorAction SilentlyContinue).Value
        if ($v.Length -ge 6) { $Text = $Text.Replace($v, '***') }
    }
    return [regex]::Replace($Text, 'access_token=[^&\s"]+', 'access_token=***')
}
function ConvertTo-Hash {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
        return $h
    }
    if ($Obj -is [System.Array]) { return @($Obj | ForEach-Object { ConvertTo-Hash $_ }) }
    return $Obj
}
function Read-Json { param([string]$Text) if ([string]::IsNullOrWhiteSpace($Text)) { return $null }; return (ConvertTo-Hash (ConvertFrom-Json $Text)) }
function Write-Msg { param([string]$M) $line = '[' + (Get-Now).ToString('HH:mm:ss') + 'Z] ' + (Hide-Secrets $M); Write-Host $line }
function New-Err {
    param([string]$Message, [string]$Code = '', [int]$Http = 0)
    $ex = New-Object System.Exception((Hide-Secrets $Message))
    $ex.Data['code'] = $Code; $ex.Data['http'] = $Http
    return $ex
}
function Wait-Sec { param([int]$S) if ($Mock) { Start-Sleep -Milliseconds 50 } else { Start-Sleep -Seconds $S } }
function ConvertTo-Form {
    param([hashtable]$Form)
    $pairs = @()
    foreach ($k in $Form.Keys) { $pairs += ([System.Uri]::EscapeDataString([string]$k) + '=' + [System.Uri]::EscapeDataString([string]$Form[$k])) }
    return ($pairs -join '&')
}

# ---------- 인터넷 호출 (모의면 가짜 응답) ----------
function Mock-Api {
    param([string]$Method, [string]$Url)
    $ok = { param($j) return @{ Status = 200; Json = $j; Text = '' } }
    $c = { param($k) if (-not $script:MockCount.ContainsKey($k)) { $script:MockCount[$k] = 0 }; $script:MockCount[$k]++; return $script:MockCount[$k] }
    if ($Url -match '^https://api\.github\.com/repos/[^/]+/[^/]+$') { return (& $ok ([pscustomobject]@{ private = $false; default_branch = 'main' })) }
    if ($Url -match '^https://raw\.githubusercontent\.com/') { return (& $ok $null) }
    if ($Url -match '^https://graph\.instagram\.com/me\?') { return (& $ok ([pscustomobject]@{ user_id = '1784140000000001'; username = 'monggeul.town' })) }
    if ($Url -match '^https://graph\.threads\.net/me\?') { return (& $ok ([pscustomobject]@{ id = '2600000000000001'; username = 'monggeul.town' })) }
    if ($Url -match '^https://graph\.instagram\.com/[^/]+/media_publish') {
        if ($FailAt -eq 'ig_publish_noresp') { throw (New-Err -Message '모의: 응답 없음' -Http 0) }
        if ($FailAt -eq 'ig_publish') { throw (New-Err -Message '모의 실패 (ig_publish)' -Code 'MOCK' -Http 400) }
        return (& $ok ([pscustomobject]@{ id = 'mock_ig_media_1' }))
    }
    if ($Url -match '^https://graph\.instagram\.com/[^/]+/media\?') { return (& $ok ([pscustomobject]@{ data = @() })) }
    if ($Url -match '^https://graph\.instagram\.com/[^/]+/media$') {
        if ($FailAt -eq 'ig_container') { throw (New-Err -Message '모의 실패 (ig_container)' -Code 'MOCK' -Http 400) }
        return (& $ok ([pscustomobject]@{ id = 'mock_ig_container_1' }))
    }
    if ($Url -match '^https://graph\.instagram\.com/mock_ig_container_1') {
        $n = & $c 'igpoll'
        return (& $ok ([pscustomobject]@{ status_code = $(if ($n -lt 2) { 'IN_PROGRESS' } else { 'FINISHED' }) }))
    }
    if ($Url -match '^https://graph\.instagram\.com/mock_ig_media_1') { return (& $ok ([pscustomobject]@{ permalink = 'https://example.com/dryrun/instagram-reel' })) }
    if ($Url -match '^https://graph\.threads\.net/[^/]+/threads_publish') {
        if ($FailAt -eq 'th_publish') { throw (New-Err -Message '모의 실패 (th_publish)' -Code 'MOCK' -Http 400) }
        return (& $ok ([pscustomobject]@{ id = 'mock_th_media_1' }))
    }
    if ($Url -match '^https://graph\.threads\.net/[^/]+/threads\?') { return (& $ok ([pscustomobject]@{ data = @() })) }
    if ($Url -match '^https://graph\.threads\.net/[^/]+/threads$') { return (& $ok ([pscustomobject]@{ id = 'mock_th_container_1' })) }
    if ($Url -match '^https://graph\.threads\.net/mock_th_container_1') { return (& $ok ([pscustomobject]@{ status = 'FINISHED' })) }
    if ($Url -match '^https://graph\.threads\.net/mock_th_media_1') { return (& $ok ([pscustomobject]@{ permalink = 'https://example.com/dryrun/threads-post' })) }
    throw (New-Err -Message "모의 모드: 알 수 없는 주소 ($Method)" -Code 'MOCK')
}
function Call-Api {
    param([string]$Method = 'GET', [string]$Url, [hashtable]$Form, [hashtable]$Headers, [string]$JsonBody, [int]$TimeoutSec = 60, [string]$OutFile = '')
    $uri = $Url
    if ($Form -and $Method -eq 'GET') { $uri = $Url + $(if ($Url.Contains('?')) { '&' } else { '?' }) + (ConvertTo-Form $Form) }
    if ($Mock) { return (Mock-Api -Method $Method -Url $uri) }
    $p = @{ Method = $Method; TimeoutSec = $TimeoutSec; ErrorAction = 'Stop'; Uri = $uri }
    if ($PSVersionTable.PSVersion.Major -lt 6) { $p['UseBasicParsing'] = $true }
    if ($Headers) { $p['Headers'] = $Headers }
    if ($Form -and $Method -ne 'GET') { $p['Body'] = (ConvertTo-Form $Form); $p['ContentType'] = 'application/x-www-form-urlencoded' }
    if ($JsonBody) { $p['Body'] = $Utf8.GetBytes($JsonBody); $p['ContentType'] = 'application/json; charset=utf-8' }
    if ($OutFile) { $p['OutFile'] = $OutFile }
    try { $r = Invoke-WebRequest @p }
    catch {
        $http = 0; $msg = ''; $code = ''
        try { if ($_.Exception.Response) { $http = [int]$_.Exception.Response.StatusCode } } catch {}
        try {
            $raw = ''
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $raw = [string]$_.ErrorDetails.Message }
            if ($raw) {
                $ej = $raw | ConvertFrom-Json
                if ($ej.error) {
                    $msg = [string]$ej.error.message; $code = [string]$ej.error.code
                    if ($ej.error.error_subcode) { $code = "$code/$($ej.error.error_subcode)" }
                } elseif ($ej.message) { $msg = [string]$ej.message }
            }
        } catch {}
        if (-not $msg) { $msg = [string]$_.Exception.Message }
        throw (New-Err -Message $msg -Code $code -Http $http)
    }
    if ($OutFile) { return @{ Status = [int]$r.StatusCode; Json = $null; Text = '' } }
    $text = ''
    try {
        if ($r.RawContentStream) { $text = $Utf8.GetString($r.RawContentStream.ToArray()) } else { $text = [string]$r.Content }
    } catch { $text = [string]$r.Content }
    $json = $null
    if ($text) { try { $json = $text | ConvertFrom-Json } catch {} }
    return @{ Status = [int]$r.StatusCode; Json = $json; Text = $text; Headers = $r.Headers }
}
function Call-ApiRead {
    param([string]$Url, [hashtable]$Form, [hashtable]$Headers)
    $last = $null
    for ($i = 1; $i -le 3; $i++) {
        try { return (Call-Api -Method GET -Url $Url -Form $Form -Headers $Headers -TimeoutSec 40) }
        catch {
            $last = $_
            $h = [int]$_.Exception.Data['http']
            if ($h -ne 0 -and $h -lt 500) { throw }
            if ($i -lt 3) { Wait-Sec (2 * $i) }
        }
    }
    throw $last
}
function Test-Ambiguous { param($E) $h = 0; if ($E.Exception.Data['http']) { $h = [int]$E.Exception.Data['http'] }; return ($h -eq 0 -or $h -ge 500) }

# ---------- 보관함 파일 (결과 저장). 모의면 폴더에 직접 ----------
function Get-GhHeaders { return @{ Authorization = "Bearer $($env:GITHUB_TOKEN)"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'monggeul-cloud-publisher'; 'X-GitHub-Api-Version' = '2022-11-28' } }
function Load-Result {
    param([string]$Id)
    if ($Mock) {
        $p = Join-Path $ResDir "$Id.json"
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        return (Read-Json ([System.IO.File]::ReadAllText($p, $Utf8)))
    }
    try {
        $r = Call-Api -Method GET -Url "https://api.github.com/repos/$Repo/contents/results/$Id.json" -Headers (Get-GhHeaders) -TimeoutSec 30
        $script:Sha[$Id] = [string]$r.Json.sha
        $bytes = [Convert]::FromBase64String(([string]$r.Json.content) -replace '\s', '')
        return (Read-Json ($Utf8.GetString($bytes)))
    } catch { if ([int]$_.Exception.Data['http'] -eq 404) { return $null }; throw }
}
function Save-Result {
    param([string]$Id, $Res)
    $Res['updatedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $json = $Res | ConvertTo-Json -Depth 10
    if ($Mock) {
        if (-not (Test-Path -LiteralPath $ResDir)) { New-Item -ItemType Directory -Force -Path $ResDir | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $ResDir "$Id.json"), $json, $Utf8)
        return
    }
    if (-not $script:Sha.ContainsKey($Id)) { try { Load-Result $Id | Out-Null } catch {} }
    $body = [ordered]@{ message = "result $Id ($($Res['state']))"; content = [Convert]::ToBase64String($Utf8.GetBytes($json)) }
    if ($script:Sha.ContainsKey($Id) -and $script:Sha[$Id]) { $body['sha'] = $script:Sha[$Id] }
    $put = Call-Api -Method PUT -Url "https://api.github.com/repos/$Repo/contents/results/$Id.json" -Headers (Get-GhHeaders) -JsonBody ($body | ConvertTo-Json -Compress) -TimeoutSec 60
    $script:Sha[$Id] = [string]$put.Json.content.sha
}

# ---------- 쉬운 한국어 오류 ----------
function Get-Friendly {
    param([string]$Step, [string]$Message, [string]$Code, [int]$Http)
    $m = "$Message $Code"
    if ($Code -match '2207052' -or $m -match 'could not be fetched|media could not') { return '인스타가 영상을 가져가지 못했어요. 영상 주소(GitHub)를 메타가 열지 못한 것 같아요.' }
    if ($Code -match '^190' -or $Http -eq 401 -or $m -match 'access token|OAuth|expired') { return '열쇠(토큰)가 만료됐거나 맞지 않아요. 비밀 파일의 새 토큰 값을 GitHub Secrets에 다시 붙여넣어 주세요(클라우드 안내서).' }
    if ($Code -match '^(4|17|32|613)(/|$)' -or $Http -eq 429) { return '메타가 요청이 너무 많다고 잠시 막았어요. 시간을 바꿔 다시 예약해 주세요.' }
    if ($Code -match '^10(/|$)|^200(/|$)|^3(/|$)' -or $Http -eq 403) { return '권한이 부족해요. 메타 앱 권한(게시 권한)을 확인해야 해요.' }
    if ($Http -eq 0) { return '인터넷 연결이 잠깐 끊겼거나 서버가 응답하지 않았어요.' }
    return '올리는 중 문제가 생겼어요. GitHub 보관함 Actions 탭의 실행 기록과 results 폴더를 확인해 주세요.'
}
function Get-ErrInfo {
    param($E, [string]$Step)
    $ex = $E.Exception
    $msg = Hide-Secrets ([string]$ex.Message)
    $code = [string]$ex.Data['code']
    $http = 0; if ($ex.Data['http']) { $http = [int]$ex.Data['http'] }
    return [ordered]@{ step = $Step; message = $msg; code = $code; http = $http; friendly = (Get-Friendly $Step $msg $code $http) }
}
function Test-Recent {
    param([string]$Ts)
    try {
        $t = [regex]::Replace($Ts, '([+-])(\d\d)(\d\d)$', '$1$2:$3')
        $dt = [datetimeoffset]::Parse($t)
        return (((Get-Now) - $dt.UtcDateTime).TotalMinutes -lt 30)
    } catch { return $false }
}
function Test-SameStart {
    param([string]$A, [string]$B)
    $a1 = ($A -replace '\s', ''); $b1 = ($B -replace '\s', '')
    if ($a1.Length -lt 10 -or $b1.Length -lt 10) { return $false }
    $n = [math]::Min(15, [math]::Min($a1.Length, $b1.Length))
    return ($a1.Substring(0, $n) -eq $b1.Substring(0, $n))
}

# ---------- 점검 모드 (읽기 전용 GET만) ----------
function Run-Check {
    $items = [ordered]@{}
    foreach ($k in @('INSTAGRAM_TOKEN', 'THREADS_TOKEN')) { $items[$k] = [bool](Get-Item -LiteralPath ('Env:' + $k) -ErrorAction SilentlyContinue).Value }
    foreach ($k in @('INSTAGRAM_USER_ID', 'THREADS_USER_ID')) { $items[$k] = [bool](Get-Item -LiteralPath ('Env:' + $k) -ErrorAction SilentlyContinue).Value }
    $acc = [ordered]@{}
    foreach ($pl in @('instagram', 'threads')) {
        try {
            if ($pl -eq 'instagram') { $r = Call-ApiRead -Url 'https://graph.instagram.com/me' -Form @{ fields = 'user_id,username'; access_token = $env:INSTAGRAM_TOKEN } }
            else { $r = Call-ApiRead -Url 'https://graph.threads.net/me' -Form @{ fields = 'id,username'; access_token = $env:THREADS_TOKEN } }
            $un = ([string]$r.Json.username).ToLower()
            if ($un -eq $Expected) { $acc[$pl] = [ordered]@{ ok = $true; message = "OK (@$un)" } }
            else { $acc[$pl] = [ordered]@{ ok = $false; message = "다른 계정(@$un)의 토큰이에요." } }
        } catch { $acc[$pl] = [ordered]@{ ok = $false; message = (Get-Friendly 'check' ([string]$_.Exception.Message) ([string]$_.Exception.Data['code']) ([int]$_.Exception.Data['http'])) } }
    }
    $repoOk = $true; $repoMsg = 'OK'
    try { $r = Call-ApiRead -Url "https://api.github.com/repos/$Repo" -Headers (Get-GhHeaders); if ($r.Json.private -eq $true) { $repoOk = $false; $repoMsg = '보관함이 비공개(Private)예요. 공개여야 해요.' } }
    catch { $repoOk = $false; $repoMsg = '보관함을 읽지 못했어요.' }
    $allOk = ($items['INSTAGRAM_TOKEN'] -and $items['THREADS_TOKEN'] -and $acc['instagram'].ok -and $acc['threads'].ok -and $repoOk)
    $res = [ordered]@{ kind = 'check'; ok = [bool]$allOk; checkedAt = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ'); secretsPresent = $items; accounts = $acc; repo = [ordered]@{ ok = $repoOk; message = $repoMsg }; mock = [bool]$Mock }
    Save-Result '_check' $res
    Write-Msg ('점검 결과: ' + $(if ($allOk) { '모두 OK' } else { '확인 필요 (results/_check.json 참고)' }))
    if (-not $allOk) { $script:Alert = $true }
}

# ---------- 계정 확인 ----------
function Get-Acct {
    param([string]$Pl)
    if ($Pl -eq 'instagram') {
        $r = Call-ApiRead -Url 'https://graph.instagram.com/me' -Form @{ fields = 'user_id,username'; access_token = $env:INSTAGRAM_TOKEN }
        $id = [string]$env:INSTAGRAM_USER_ID
        if (-not $id) { $id = [string]$r.Json.user_id; if (-not $id) { $id = [string]$r.Json.id } }
    } else {
        $r = Call-ApiRead -Url 'https://graph.threads.net/me' -Form @{ fields = 'id,username'; access_token = $env:THREADS_TOKEN }
        $id = [string]$env:THREADS_USER_ID
        if (-not $id) { $id = [string]$r.Json.id }
    }
    $un = ([string]$r.Json.username).ToLower()
    if ($Expected -and $un -ne $Expected) { throw (New-Err -Message "토큰이 다른 계정(@$un)의 것이에요. 올리지 않고 멈췄어요." -Code 'ACCOUNT') }
    if (-not $id) { $id = 'me' }
    return $id
}

function Add-Log { param($Res, [string]$M) $Res['log'] = @($Res['log']) + ('[' + (Get-Now).ToString('HH:mm:ss') + 'Z] ' + (Hide-Secrets $M)); if ($Res['log'].Count -gt 50) { $Res['log'] = @($Res['log'] | Select-Object -Last 50) }; Write-Msg $M }
function Get-Step { param($Res, [string]$N) if (-not $Res['steps'].Contains($N)) { $Res['steps'][$N] = [ordered]@{ status = 'pending' } }; return $Res['steps'][$N] }

# ---------- 인스타 ----------
function Step-Instagram {
    param($Sch, $Res, [string]$RawUrl)
    $s = Get-Step $Res 'instagram'
    if ($s['status'] -eq 'done') { return }
    if ($s['status'] -eq 'uncertain') { throw (New-Err -Message '인스타 게시 결과가 불확실해서 잠겨 있어요. 앱에서 확인해 주세요.') }
    $caption = [string]$Sch['igText']
    $tok = $env:INSTAGRAM_TOKEN
    $id = Get-Acct 'instagram'
    $base = "https://graph.instagram.com/$id"
    # 이전 실행이 "게시 호출" 도중 끊겼으면 올라갔는지 먼저 확인 (중복 방지)
    if ($s['status'] -eq 'publishing') {
        Add-Log $Res '인스타: 이전 실행이 게시 도중 끊김 - 최근 게시물에서 확인'
        $found = $null
        try {
            $lst = Call-ApiRead -Url "$base/media" -Form @{ fields = 'id,caption,permalink,timestamp'; limit = '5'; access_token = $tok }
            foreach ($it in @($lst.Json.data)) { if ($it -and (Test-SameStart ([string]$it.caption) $caption) -and (Test-Recent ([string]$it.timestamp))) { $found = $it; break } }
        } catch {}
        if ($found) { $s['status'] = 'done'; $s['mediaId'] = [string]$found.id; $s['permalink'] = [string]$found.permalink; Save-Result $Sch['id'] $Res; return }
        $s['status'] = 'uncertain'; $s['error'] = [ordered]@{ friendly = '인스타에 올라갔는지 확실하지 않아요. 인스타 앱에서 직접 확인해 주세요. (중복 게시를 막으려고 자동 재시도는 잠가 두었어요)' }
        Save-Result $Sch['id'] $Res
        throw (New-Err -Message '인스타 게시 결과가 불확실해요.')
    }
    $s['status'] = 'running'; $s['error'] = $null
    $reuse = $false
    if ($s['containerId'] -and $s['containerStatus'] -notin @('ERROR', 'EXPIRED') -and $s['containerCreatedAt']) {
        try { if (((Get-Now) - [datetime]::Parse([string]$s['containerCreatedAt']).ToUniversalTime()).TotalHours -lt 20) { $reuse = $true } } catch {}
    }
    if (-not $reuse) {
        $c = Call-Api -Method POST -Url "$base/media" -Form @{ media_type = 'REELS'; video_url = $RawUrl; caption = $caption; share_to_feed = 'true'; access_token = $tok } -TimeoutSec 90
        if (-not $c.Json.id) { throw (New-Err -Message '인스타가 컨테이너 번호를 주지 않았어요.') }
        $s['containerId'] = [string]$c.Json.id; $s['containerStatus'] = 'IN_PROGRESS'
        $s['containerCreatedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
        Save-Result $Sch['id'] $Res
    }
    $finished = $false
    for ($n = 1; $n -le 6; $n++) {
        if ($n -eq 1) { Wait-Sec 20 } else { Wait-Sec 60 }
        $st = Call-ApiRead -Url ('https://graph.instagram.com/' + $s['containerId']) -Form @{ fields = 'status_code,status'; access_token = $tok }
        $code = [string]$st.Json.status_code
        $s['containerStatus'] = $code
        if ($code -eq 'FINISHED') { $finished = $true; break }
        if ($code -eq 'ERROR') { throw (New-Err -Message ('인스타가 영상을 처리하지 못했어요. ' + [string]$st.Json.status) -Code 'IG_ERROR') }
        if ($code -eq 'EXPIRED') { throw (New-Err -Message '인스타 컨테이너가 만료됐어요.' -Code 'IG_EXPIRED') }
    }
    if (-not $finished) { throw (New-Err -Message '5분이 지나도 인스타 처리가 끝나지 않았어요. 시간을 바꿔 다시 예약하면 만든 컨테이너를 이어서 써요.' -Code 'IG_SLOW') }
    # 게시 직전에 "게시 중" 표시를 먼저 저장 (끊겨도 다음 실행이 중복 게시하지 않게)
    $s['status'] = 'publishing'
    Save-Result $Sch['id'] $Res
    $mediaId = $null
    try {
        $p = Call-Api -Method POST -Url "$base/media_publish" -Form @{ creation_id = $s['containerId']; access_token = $tok } -TimeoutSec 90
        $mediaId = [string]$p.Json.id
    } catch {
        if (-not (Test-Ambiguous $_)) { $s['status'] = 'failed'; throw }
        Add-Log $Res '인스타: 게시 응답이 불분명 - 최근 게시물에서 확인'
        Wait-Sec 5
        $found = $null
        try {
            $lst = Call-ApiRead -Url "$base/media" -Form @{ fields = 'id,caption,permalink,timestamp'; limit = '5'; access_token = $tok }
            foreach ($it in @($lst.Json.data)) { if ($it -and (Test-SameStart ([string]$it.caption) $caption) -and (Test-Recent ([string]$it.timestamp))) { $found = $it; break } }
        } catch {}
        if ($found) { $mediaId = [string]$found.id; $s['permalink'] = [string]$found.permalink }
        else {
            $s['status'] = 'uncertain'
            $s['error'] = Get-ErrInfo $_ 'instagram'
            $s['error']['friendly'] = '인스타에 올라갔는지 확실하지 않아요. 인스타 앱에서 직접 확인해 주세요. (중복 게시를 막으려고 자동 재시도는 잠가 두었어요)'
            Save-Result $Sch['id'] $Res
            throw
        }
    }
    $s['mediaId'] = $mediaId; $s['status'] = 'done'; $s['publishedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Save-Result $Sch['id'] $Res
    try { $pl = Call-ApiRead -Url "https://graph.instagram.com/$mediaId" -Form @{ fields = 'permalink'; access_token = $tok }; if ($pl.Json.permalink) { $s['permalink'] = [string]$pl.Json.permalink } } catch {}
    Add-Log $Res '인스타 게시 완료'
    Save-Result $Sch['id'] $Res
}

# ---------- 스레드 ----------
function Step-Threads {
    param($Sch, $Res, [string]$RawUrl)
    $s = Get-Step $Res 'threads'
    if ($s['status'] -eq 'done') { return }
    if ($s['status'] -eq 'uncertain') { throw (New-Err -Message '스레드 게시 결과가 불확실해서 잠겨 있어요. 앱에서 확인해 주세요.') }
    $text = [string]$Sch['thText']
    $tok = $env:THREADS_TOKEN
    $id = Get-Acct 'threads'
    $base = "https://graph.threads.net/$id"
    if ($s['status'] -eq 'publishing') {
        Add-Log $Res '스레드: 이전 실행이 게시 도중 끊김 - 최근 글에서 확인'
        $found = $null
        try {
            $lst = Call-ApiRead -Url "$base/threads" -Form @{ fields = 'id,text,permalink,timestamp'; limit = '5'; access_token = $tok }
            foreach ($it in @($lst.Json.data)) { if ($it -and (Test-SameStart ([string]$it.text) $text) -and (Test-Recent ([string]$it.timestamp))) { $found = $it; break } }
        } catch {}
        if ($found) { $s['status'] = 'done'; $s['mediaId'] = [string]$found.id; $s['permalink'] = [string]$found.permalink; Save-Result $Sch['id'] $Res; return }
        $s['status'] = 'uncertain'; $s['error'] = [ordered]@{ friendly = '스레드에 올라갔는지 확실하지 않아요. 스레드 앱에서 직접 확인해 주세요. (중복 게시를 막으려고 자동 재시도는 잠가 두었어요)' }
        Save-Result $Sch['id'] $Res
        throw (New-Err -Message '스레드 게시 결과가 불확실해요.')
    }
    $s['status'] = 'running'; $s['error'] = $null
    $reuse = $false
    if ($s['containerId'] -and $s['containerStatus'] -notin @('ERROR', 'EXPIRED') -and $s['containerCreatedAt']) {
        try { if (((Get-Now) - [datetime]::Parse([string]$s['containerCreatedAt']).ToUniversalTime()).TotalHours -lt 20) { $reuse = $true } } catch {}
    }
    if (-not $reuse) {
        $c = Call-Api -Method POST -Url "$base/threads" -Form @{ media_type = 'VIDEO'; video_url = $RawUrl; text = $text; access_token = $tok } -TimeoutSec 90
        if (-not $c.Json.id) { throw (New-Err -Message '스레드가 컨테이너 번호를 주지 않았어요.') }
        $s['containerId'] = [string]$c.Json.id; $s['containerStatus'] = 'IN_PROGRESS'
        $s['containerCreatedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
        Save-Result $Sch['id'] $Res
    }
    Wait-Sec 30
    for ($n = 1; $n -le 8; $n++) {
        $code = ''
        try { $st = Call-ApiRead -Url ('https://graph.threads.net/' + $s['containerId']) -Form @{ fields = 'status,error_message'; access_token = $tok }; $code = [string]$st.Json.status } catch { break }
        $s['containerStatus'] = $code
        if ($code -eq 'FINISHED' -or [string]::IsNullOrEmpty($code)) { break }
        if ($code -eq 'ERROR') { throw (New-Err -Message ('스레드가 영상을 처리하지 못했어요. ' + [string]$st.Json.error_message) -Code 'TH_ERROR') }
        if ($code -eq 'EXPIRED') { throw (New-Err -Message '스레드 컨테이너가 만료됐어요.' -Code 'TH_EXPIRED') }
        Wait-Sec 15
    }
    $s['status'] = 'publishing'
    Save-Result $Sch['id'] $Res
    $mediaId = $null
    try {
        $p = Call-Api -Method POST -Url "$base/threads_publish" -Form @{ creation_id = $s['containerId']; access_token = $tok } -TimeoutSec 90
        $mediaId = [string]$p.Json.id
    } catch {
        if (-not (Test-Ambiguous $_)) { $s['status'] = 'failed'; throw }
        Add-Log $Res '스레드: 게시 응답이 불분명 - 최근 글에서 확인'
        Wait-Sec 5
        $found = $null
        try {
            $lst = Call-ApiRead -Url "$base/threads" -Form @{ fields = 'id,text,permalink,timestamp'; limit = '5'; access_token = $tok }
            foreach ($it in @($lst.Json.data)) { if ($it -and (Test-SameStart ([string]$it.text) $text) -and (Test-Recent ([string]$it.timestamp))) { $found = $it; break } }
        } catch {}
        if ($found) { $mediaId = [string]$found.id; $s['permalink'] = [string]$found.permalink }
        else {
            $s['status'] = 'uncertain'
            $s['error'] = Get-ErrInfo $_ 'threads'
            $s['error']['friendly'] = '스레드에 올라갔는지 확실하지 않아요. 스레드 앱에서 직접 확인해 주세요. (중복 게시를 막으려고 자동 재시도는 잠가 두었어요)'
            Save-Result $Sch['id'] $Res
            throw
        }
    }
    $s['mediaId'] = $mediaId; $s['status'] = 'done'; $s['publishedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Save-Result $Sch['id'] $Res
    try { $pl = Call-ApiRead -Url "https://graph.threads.net/$mediaId" -Form @{ fields = 'permalink'; access_token = $tok }; if ($pl.Json.permalink) { $s['permalink'] = [string]$pl.Json.permalink } } catch {}
    Add-Log $Res '스레드 게시 완료'
    Save-Result $Sch['id'] $Res
}

# ---------- 영상 확인 (예약 때 PC가 적어 둔 지문과 보관함 영상이 같은지) ----------
function Test-Video {
    param($Sch)
    $rel = [string]$Sch['video']
    if ($rel -notmatch '^videos/EP-\d{3}\.mp4$') { throw (New-Err -Message '영상 경로가 올바르지 않아요.') }
    $want = ([string]$Sch['videoSha256']).ToLower()
    if (-not $want) { throw (New-Err -Message '예약 파일에 영상 지문이 없어요.') }
    if ($Mock) {
        $p = Join-Path $Base ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $p)) { throw (New-Err -Message '보관함에 영상이 없어요.') }
        $got = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower()
    } else {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('v_' + [guid]::NewGuid().ToString('N') + '.mp4')
        try {
            $h = Get-GhHeaders; $h['Accept'] = 'application/vnd.github.raw+json'
            Call-Api -Method GET -Url "https://api.github.com/repos/$Repo/contents/$rel" -Headers $h -TimeoutSec 300 -OutFile $tmp | Out-Null
            $got = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($got -ne $want) { throw (New-Err -Message '보관함의 영상이 예약할 때의 영상과 달라요. 안전을 위해 올리지 않고 멈췄어요.' -Code 'HASH') }
    if ($Mock) { return "https://raw.githubusercontent.com/$Repo/$Branch/$rel" }
    $raw = "https://raw.githubusercontent.com/$Repo/$Branch/$rel"
    for ($i = 1; $i -le 4; $i++) { try { Call-Api -Method HEAD -Url $raw -TimeoutSec 30 | Out-Null; break } catch { if ($i -eq 4) { throw }; Wait-Sec 3 } }
    return $raw
}

# ---------- 예약 하나 처리 ----------
function Process-Schedule {
    param($Sch)
    $id = [string]$Sch['id']
    if ($id -notmatch '^SCH-\d{14}(-\d+)?$') { return }
    if ([string]$Sch['executor'] -ne 'cloud') { return }       # PC 예약은 건드리지 않음
    if ([string]$Sch['status'] -ne 'scheduled') { return }     # 취소 등
    $attempt = 1; if ($Sch['attempt']) { $attempt = [int]$Sch['attempt'] }
    $when = $null
    # PowerShell 7(클라우드)의 ConvertFrom-Json은 날짜 글자를 DateTime으로 바꿔 버린다 -> 글자/날짜 둘 다 받는다 (2026-10-22 첫 실제 시험에서 조용히 건너뛴 원인)
    $sa = $Sch['scheduledAt']
    try {
        if ($sa -is [datetime]) { $when = [datetime]::SpecifyKind($sa, 'Unspecified').AddHours(-9) }
        else { $when = [datetime]::ParseExact([string]$sa, 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture).AddHours(-9) }
    } catch { Write-Msg "예약 $id 시각을 읽지 못했어요: $sa"; return }
    $now = Get-Now
    if ($when -gt $now) { return }
    $late = ($now - $when).TotalMinutes
    $res = Load-Result $id
    $resumed = $false
    if ($res) {
        $ra = 0; if ($res['attempt']) { $ra = [int]$res['attempt'] }
        if ($ra -ge $attempt) {
            if ([string]$res['state'] -ne 'running') { return }   # 이미 끝난 시도 (done/failed/missed/...) -> 다시 하지 않음
            # 이전 실행이 끊김 -> 단계 기록을 보고 이어서 (최대 3번)
            $rc = 0; if ($res['resumes']) { $rc = [int]$res['resumes'] }
            if ($rc -ge 3) { $res['state'] = 'failed'; $res['error'] = [ordered]@{ friendly = '클라우드 작업이 여러 번 중간에 끊겼어요. 인스타·스레드 앱에서 올라갔는지 확인해 주세요.' }; $res['finishedAt'] = $now.ToString('yyyy-MM-ddTHH:mm:ssZ'); Save-Result $id $res; $script:Alert = $true; return }
            $res['resumes'] = $rc + 1; $resumed = $true
        } else {
            # 새 시도: 이미 끝난(done/uncertain) 단계는 이어받고, 나머지는 처음부터
            $res['attempt'] = $attempt; $res['state'] = 'running'; $res['error'] = $null; $res['resumes'] = 0
            foreach ($t in @('instagram', 'threads')) {
                $so = $res['steps'][$t]
                if ($so -and $so['status'] -in @('failed', 'running')) { $so['status'] = 'pending' }
            }
        }
    } else {
        $res = [ordered]@{ kind = 'result'; executor = 'cloud'; scheduleId = $id; ep = [string]$Sch['ep']; attempt = $attempt; state = 'running'; steps = [ordered]@{}; log = @(); mock = [bool]$Mock; resumes = 0 }
    }
    if (-not $resumed -and $late -gt $LateLimitMin) {
        $res['state'] = 'missed'
        $res['error'] = [ordered]@{ friendly = ('예약 시각보다 ' + [int]$late + '분 늦게 확인돼서(60분 초과) 올리지 않았어요. 시간을 바꿔 다시 예약하거나 직접 올려 주세요.'); message = 'late' }
        $res['finishedAt'] = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-Log $res "예약 시각 $([int]$late)분 초과 - 올리지 않음"
        Save-Result $id $res
        $script:Alert = $true
        return
    }
    $res['startedAt'] = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    if (-not $res['startedAtKst']) { $res['startedAtKst'] = $now.AddHours(9).ToString('yyyy-MM-ddTHH:mm:ss') }
    Save-Result $id $res     # "올리는 중" 표시 먼저 (이후 실행이 같은 예약을 또 시작하지 않게)
    $targets = @(@($Sch['targets']) | Where-Object { $_ -in @('instagram', 'threads') })
    $failed = @()
    $raw = $null
    try {
        $need = $false
        foreach ($t in $targets) { $so = Get-Step $res $t; if ($so['status'] -ne 'done') { $need = $true } }
        if ($need) { $raw = Test-Video $Sch }
    } catch {
        $res['state'] = 'failed'; $res['error'] = Get-ErrInfo $_ 'video'
        $res['finishedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
        $res['error']['friendly'] = [string]$res['error']['message']
        Save-Result $id $res; $script:Alert = $true; return
    }
    foreach ($t in $targets) {
        try {
            if ($t -eq 'instagram') { Step-Instagram $Sch $res $raw } else { Step-Threads $Sch $res $raw }
        } catch {
            $failed += $t
            $so = Get-Step $res $t
            if ($so['status'] -notin @('uncertain', 'done')) { $so['status'] = 'failed'; $so['error'] = Get-ErrInfo $_ $t }
            Add-Log $res ("실패: $t - " + [string]$_.Exception.Message)
            Save-Result $id $res
        }
    }
    $done = @($targets | Where-Object { $res['steps'][$_]['status'] -eq 'done' }).Count
    $unc = @($targets | Where-Object { $res['steps'][$_]['status'] -eq 'uncertain' }).Count
    if ($unc -gt 0) { $res['state'] = 'uncertain' }
    elseif ($done -eq $targets.Count) { $res['state'] = 'done' }
    elseif ($done -gt 0) { $res['state'] = 'partial' }
    else { $res['state'] = 'failed' }
    if ($res['state'] -ne 'done') {
        $first = $failed[0]; if (-not $first) { $first = $targets[0] }
        $res['error'] = [ordered]@{ step = $first; friendly = [string]$res['steps'][$first]['error']['friendly']; message = [string]$res['steps'][$first]['error']['message'] }
        $script:Alert = $true
    }
    $res['finishedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Add-Log $res ('끝: ' + $res['state'])
    Save-Result $id $res
}

# ---------- 본 흐름 ----------
Write-Msg "클라우드 예약 확인 시작 (mode=$Mode, mock=$([bool]$Mock))"
try {
    if ($Mode -eq 'check') { Run-Check }
    else {
        if (-not (Test-Path -LiteralPath $SchedDir)) { Write-Msg '예약 폴더가 없어요. 할 일 없음.' }
        else {
            $files = @(Get-ChildItem -LiteralPath $SchedDir -Filter 'SCH-*.json' -File | Sort-Object Name)
            Write-Msg ("예약 파일 " + $files.Count + "개 확인")
            foreach ($f in $files) {
                $sch = $null
                try { $sch = Read-Json ([System.IO.File]::ReadAllText($f.FullName, $Utf8)) } catch { Write-Msg ('읽지 못한 예약 파일: ' + $f.Name); continue }
                if (-not $sch) { continue }
                try { Process-Schedule $sch }
                catch {
                    Write-Msg ('예약 처리 중 문제 (' + $f.BaseName + '): ' + [string]$_.Exception.Message)
                    $script:Alert = $true
                    try {
                        $r = Load-Result ([string]$sch['id'])
                        if (-not $r) { $r = [ordered]@{ kind = 'result'; executor = 'cloud'; scheduleId = [string]$sch['id']; ep = [string]$sch['ep']; attempt = $(if ($sch['attempt']) { [int]$sch['attempt'] } else { 1 }); steps = [ordered]@{}; log = @() } }
                        if ([string]$r['state'] -in @('', 'running')) { $r['state'] = 'failed'; $r['error'] = Get-ErrInfo $_ 'cloud'; $r['finishedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ'); Save-Result ([string]$sch['id']) $r }
                    } catch {}
                }
            }
        }
    }
} catch {
    Write-Msg ('치명적 문제: ' + [string]$_.Exception.Message)
    $script:Alert = $true
}
if ($script:Alert) { Write-Msg '확인이 필요한 일이 있어요 (실패 알림용으로 이 실행을 실패로 표시합니다).'; exit 1 }
Write-Msg '끝'
exit 0
