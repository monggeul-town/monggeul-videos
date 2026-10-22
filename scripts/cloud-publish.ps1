# 요약: 클라우드(GitHub Actions) 예약 게시 일꾼. 깨어나 "시각이 된 예약"을 인스타 릴스 -> 스레드 순서로 올린다.
#       (PC의 09_도구\자동게시.ps1 과 같은 순서·같은 API. 모양만 클라우드용으로 단순화)
#       -Wait(5분 간격 실행에서 켜짐): 앞으로 3시간 안에 시각이 되는 예약이 있으면 끝내지 않고 기다렸다가 그 시각(약 20초 전 시작 -> 정각 게시)에 올린다.
#       기다리는 동안 예약 파일을 1~2분마다 다시 읽어 취소·시간 변경을 반영하고, 결과 파일에 "waiting"(심장박동 5분마다)을 적어 다른 실행이 건너뛰게 한다.
# 놓는 곳: 보관함(monggeul-videos)의 scripts/cloud-publish.ps1  (PowerShell 5.1 / 7 모두 동작)
# 인자: -Mode run(기본, 올리기) | check(읽기 전용 점검) / -Wait / -Mock -RepoDir 폴더 (모의: 인터넷 요청 없이 폴더 안 파일로만 시험)
# 열쇠(Secrets)는 환경변수로만 받는다: INSTAGRAM_TOKEN THREADS_TOKEN INSTAGRAM_USER_ID THREADS_USER_ID (+ 자동 제공 GITHUB_TOKEN, GITHUB_REPOSITORY)
# 규칙: 비밀 값은 어디에도 출력·저장하지 않는다. 이 파일은 UTF-8 BOM 필수.
# PowerShell 7 주의(2026-10-22 사고): ConvertFrom-Json 이 날짜처럼 생긴 글자를 DateTime 으로 바꾼다 -> JSON을 읽는 곳은 모두 Read-Json/ConvertTo-Hash 를 거쳐
#       날짜를 다시 글자로 되돌린다(ConvertTo-Hash). 날짜 계산은 ConvertTo-Utc 로만 한다. (모의 시험은 -SimPs7 로 PS7 동작을 흉내)
param(
    [string]$Mode = 'run',
    [switch]$Mock,
    [string]$RepoDir = '',
    [string]$FailAt = '',
    [string]$NowUtc = '',     # 모의 시험 전용: 지금 시각을 흉내 (예: 2026-10-22T13:00:00). 모의에서는 기다리는 시간도 "가상 시계"로 흘러간다
    [switch]$Wait,            # 앞으로 WaitWindowMin 분 안의 예약을 미리 와서 기다림
    [string]$RunId = '',
    [switch]$SimPs7,          # 모의 시험 전용: PowerShell 7 의 날짜 자동 변환을 흉내
    [string]$MockEvents = '', # 모의 시험 전용: 기다리는 동안 일어날 일(취소·시간 변경·끊김·예약 추가)을 적은 JSON 파일
    [int]$WaitWindowMin = 180,
    [int]$DeadlineMin = 185,  # 이 실행이 "새로 기다리기 시작"할 수 있는 한도(시작 후 분). 워크플로 제한시간(240분)보다 충분히 짧게
    [int]$PollSec = 90,
    [int]$LeadSec = 20        # 인스타 컨테이너 준비(약 20초)를 감안해 이만큼 먼저 시작 -> 게시가 정각 무렵
)
$ErrorActionPreference = 'Stop'
if (-not $RunId) { $RunId = $(if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID + '-' + $env:GITHUB_RUN_ATTEMPT } else { [guid]::NewGuid().ToString('N').Substring(0, 8) }) }
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
$script:ClockBase = $null; $script:Virt = 0.0
$script:Mine = @{}        # 내가 "waiting" 표시를 해 둔 예약: id -> @{ attempt; hbAt }
$script:Finished = @{}    # 이 실행에서 더는 볼 필요 없는 예약 (id|attempt)
$script:NoWait = @{}      # 기다리지 않기로 한 예약 (id|attempt)
$script:SchCache = @{}    # 보관함 예약 파일 읽기 캐시 (파일 이름 -> @{ sha; sch })
$script:Events = @()
function Get-Now {
    if ($Mock) {
        # 모의: 가상 시계 (기다리면 시간이 흐른 것으로 친다 - 실제로는 기다리지 않음)
        if (-not $script:ClockBase) { $script:ClockBase = $(if ($NowUtc) { [datetime]::SpecifyKind([datetime]::Parse($NowUtc, [System.Globalization.CultureInfo]::InvariantCulture), 'Utc') } else { [datetime]::UtcNow }) }
        return $script:ClockBase.AddSeconds($script:Virt)
    }
    return [datetime]::UtcNow
}
# 어떤 모양(글자·DateTime·+0900 등)이든 UTC 시각으로. 못 읽으면 $null  (PS7 이 JSON 날짜를 DateTime 으로 바꿔도 안전)
function ConvertTo-Utc {
    param($V)
    if ($null -eq $V -or [string]$V -eq '') { return $null }
    try {
        if ($V -is [datetime]) { if ($V.Kind -eq 'Unspecified') { return [datetime]::SpecifyKind($V, 'Utc') }; return $V.ToUniversalTime() }
        $t = [regex]::Replace(([string]$V).Trim(), '([+-])(\d\d)(\d\d)$', '$1$2:$3')
        return ([datetimeoffset]::Parse($t, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)).UtcDateTime
    } catch { return $null }
}
# DateTime 이 JSON 에서 들어왔을 때 글자로 되돌림: 시간대 없는 값(한국시간 예약 등)은 그대로, 시간대 있던 값은 UTC 'Z' 글자
function Format-DateValue {
    param([datetime]$D)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($D.Kind -eq 'Unspecified') { return $D.ToString('yyyy-MM-ddTHH:mm:ss', $inv) }
    return $D.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss', $inv) + 'Z'
}
# 모의 시험용: PowerShell 7 의 ConvertFrom-Json 이 날짜 모양 글자를 DateTime 으로 바꾸는 것을 흉내 (Z/오프셋 있으면 Local 종류, 없으면 종류 없음)
function Sim-Ps7 {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in @($Obj.PSObject.Properties)) { $p.Value = (Sim-Ps7 $p.Value) }
        return $Obj
    }
    if ($Obj -is [System.Array]) { return , @($Obj | ForEach-Object { Sim-Ps7 $_ }) }
    if ($Obj -is [string] -and $Obj -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$') {
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        if ($Obj -match '(Z|[+-]\d{2}:?\d{2})$') {
            $t = [regex]::Replace($Obj, '([+-])(\d\d)(\d\d)$', '$1$2:$3')
            return ([datetimeoffset]::Parse($t, $inv)).LocalDateTime
        }
        return [datetime]::Parse($Obj, $inv)
    }
    return $Obj
}
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
    if ($Obj -is [datetime]) { return (Format-DateValue $Obj) }     # PS7: 날짜로 바뀐 값을 다시 글자로
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
        return $h
    }
    if ($Obj -is [System.Array]) { return @($Obj | ForEach-Object { ConvertTo-Hash $_ }) }
    return $Obj
}
# JSON 글 -> 해시. 날짜는 항상 글자 (PS5.1 / PS7 같은 결과)
function Read-Json {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $o = ConvertFrom-Json $Text
    if ($SimPs7) { $o = Sim-Ps7 $o }
    return (ConvertTo-Hash $o)
}
function Write-Msg { param([string]$M) $line = '[' + (Get-Now).ToString('HH:mm:ss') + 'Z] ' + (Hide-Secrets $M); Write-Host $line }
function New-Err {
    param([string]$Message, [string]$Code = '', [int]$Http = 0)
    $ex = New-Object System.Exception((Hide-Secrets $Message))
    $ex.Data['code'] = $Code; $ex.Data['http'] = $Http
    return $ex
}
function Wait-Sec {
    param([int]$S)
    if ($Mock) { $script:Virt += $S; Start-Sleep -Milliseconds 5; Apply-MockEvents } else { Start-Sleep -Seconds $S }
}
# 모의 시험 전용: 가상 시간이 흐르다가 정해 둔 때가 되면 보관함 예약 파일을 바꾼다(PC 쪽에서 취소·시간 변경·예약 추가를 한 것처럼) 또는 실행을 갑자기 끊는다
function Apply-MockEvents {
    foreach ($e in $script:Events) {
        if ($e['done']) { continue }
        if ($script:Virt -lt [double]$e['atSec']) { continue }
        $e['done'] = $true
        $act = [string]$e['action']
        $pth = Join-Path $SchedDir ([string]$e['id'] + '.json')
        if ($act -eq 'kill') { Write-Msg '[모의] 실행이 갑자기 끊김'; exit 77 }
        if ($act -eq 'add') { if (-not (Test-Path -LiteralPath $SchedDir)) { New-Item -ItemType Directory -Force -Path $SchedDir | Out-Null }; [System.IO.File]::WriteAllText((Join-Path $SchedDir ([string]$e['schedule']['id'] + '.json')), ($e['schedule'] | ConvertTo-Json -Depth 10), $Utf8); Write-Msg ('[모의] 예약 추가 ' + [string]$e['schedule']['id']); continue }
        $cur = Read-Json ([System.IO.File]::ReadAllText($pth, $Utf8))
        if ($act -eq 'cancel') { $cur['status'] = 'cancelled' }
        if ($act -eq 'retime') { $cur['scheduledAt'] = [string]$e['newWhen']; $cur['status'] = 'scheduled'; $cur['attempt'] = $(if ($cur['attempt']) { [int]$cur['attempt'] + 1 } else { 2 }) }
        [System.IO.File]::WriteAllText($pth, ($cur | ConvertTo-Json -Depth 10), $Utf8)
        Write-Msg ('[모의] ' + $act + ' ' + [string]$e['id'])
    }
}
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
    if ($text) { try { $json = Read-Json $text } catch {} }     # 날짜가 글자로 유지되도록 Read-Json 을 거침 (PS7)
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
    param($Ts)
    $dt = ConvertTo-Utc $Ts
    if ($null -eq $dt) { return $false }
    return (((Get-Now) - $dt).TotalMinutes -lt 30)
}
# 결과 파일의 심장박동이 최근(기본 15분 안)인지
function Test-Fresh {
    param($Ts, [int]$Min = 15)
    $dt = ConvertTo-Utc $Ts
    if ($null -eq $dt) { return $false }
    return (((Get-Now) - $dt).TotalMinutes -lt $Min)
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
        $cd = ConvertTo-Utc $s['containerCreatedAt']
        if ($cd -and ((Get-Now) - $cd).TotalHours -lt 20) { $reuse = $true }
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
        $cd = ConvertTo-Utc $s['containerCreatedAt']
        if ($cd -and ((Get-Now) - $cd).TotalHours -lt 20) { $reuse = $true }
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
# 예약 시각(한국시간 글자 또는 PS7 이 바꾼 DateTime)을 UTC 로. 못 읽으면 $null  (2026-10-22 첫 실제 시험에서 PS7 이 날짜로 바꿔 조용히 건너뛴 원인을 고친 곳)
function Get-When {
    param($Sch)
    $sa = $Sch['scheduledAt']
    try {
        if ($sa -is [datetime]) { return [datetime]::SpecifyKind($sa, 'Unspecified').AddHours(-9) }
        $fmts = [string[]]@('yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm')
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact(([string]$sa).Trim(), $fmts, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $d.AddHours(-9) }
    } catch {}
    return $null
}
# 새 시도(시간 변경 등): 이미 끝난(done/uncertain) 단계는 이어받고, 나머지는 처음부터
function Reset-ForNewAttempt {
    param($Res, [int]$Attempt)
    $Res['attempt'] = $Attempt; $Res['state'] = 'running'; $Res['error'] = $null; $Res['resumes'] = 0
    foreach ($t in @('instagram', 'threads')) {
        $so = $Res['steps'][$t]
        if ($so -and $so['status'] -in @('failed', 'running')) { $so['status'] = 'pending' }
    }
}
# 반환: 'notdue' | 'finished'(이미 끝난 시도) | 'skipped'(다른 실행이 기다리는 중 등) | 'processed'(이번에 처리함)
function Process-Schedule {
    param($Sch)
    $id = [string]$Sch['id']
    if ($id -notmatch '^SCH-\d{14}(-\d+)?$') { return 'finished' }
    if ([string]$Sch['executor'] -ne 'cloud') { return 'finished' }       # PC 예약은 건드리지 않음
    if ([string]$Sch['status'] -ne 'scheduled') { return 'finished' }     # 취소 등
    $attempt = 1; if ($Sch['attempt']) { $attempt = [int]$Sch['attempt'] }
    $when = Get-When $Sch
    if ($null -eq $when) {
        # 조용히 건너뛰면 안 된다 -> 알림(빨간 X)
        Write-Msg ("예약 $id 시각을 읽지 못했어요: " + [string]$Sch['scheduledAt'])
        $script:Alert = $true
        return 'finished'
    }
    $now = Get-Now
    if ($when.AddSeconds(-$LeadSec) -gt $now) { return 'notdue' }     # 아직 (LeadSec 전부터 시작)
    $late = ($now - $when).TotalMinutes
    $res = Load-Result $id
    $resumed = $false
    $waitedByMe = $false
    if ($res) {
        $ra = 0; if ($res['attempt']) { $ra = [int]$res['attempt'] }
        if ($ra -ge $attempt) {
            $stt = [string]$res['state']
            if ($stt -in @('waiting', 'released')) {
                # 미리 와서 기다리던 표시: 내 것이면 이어서, 다른 실행이 최근까지 기다리던 것이면 건드리지 않고, 심장박동이 끊긴 것이면 이어받는다
                if ($stt -eq 'waiting' -and [string]$res['waitRun'] -eq $RunId) { $waitedByMe = $true }
                elseif ($stt -eq 'waiting' -and (Test-Fresh ([string]$res['heartbeat']))) { return 'skipped' }
                $res['state'] = 'running'; $res['error'] = $null
                if ($script:Mine.ContainsKey($id)) { $script:Mine.Remove($id) }
            } elseif ($stt -ne 'running') { return 'finished' }   # 이미 끝난 시도 (done/failed/missed/...) -> 다시 하지 않음
            else {
                # 이전 실행이 끊김 -> 단계 기록을 보고 이어서 (최대 3번)
                $rc = 0; if ($res['resumes']) { $rc = [int]$res['resumes'] }
                if ($rc -ge 3) { $res['state'] = 'failed'; $res['error'] = [ordered]@{ friendly = '클라우드 작업이 여러 번 중간에 끊겼어요. 인스타·스레드 앱에서 올라갔는지 확인해 주세요.' }; $res['finishedAt'] = $now.ToString('yyyy-MM-ddTHH:mm:ssZ'); Save-Result $id $res; $script:Alert = $true; return 'processed' }
                $res['resumes'] = $rc + 1; $resumed = $true
            }
        } else {
            Reset-ForNewAttempt $res $attempt
            if ($script:Mine.ContainsKey($id)) { $script:Mine.Remove($id) }
        }
    } else {
        $res = [ordered]@{ kind = 'result'; executor = 'cloud'; scheduleId = $id; ep = [string]$Sch['ep']; attempt = $attempt; state = 'running'; steps = [ordered]@{}; log = @(); mock = [bool]$Mock; resumes = 0 }
    }
    foreach ($k in @('waitRun', 'heartbeat', 'waitingSince')) { if ($res.Contains($k)) { $res.Remove($k) } }
    # 60분 늦음 규칙: 미리 와서 기다린 경우(내가 기다리던 것)와 이어서 하는 경우에는 적용하지 않는다
    if (-not $resumed -and -not $waitedByMe -and $late -gt $LateLimitMin) {
        $res['state'] = 'missed'
        $res['error'] = [ordered]@{ friendly = ('예약 시각보다 ' + [int]$late + '분 늦게 확인돼서(60분 초과) 올리지 않았어요. 시간을 바꿔 다시 예약하거나 직접 올려 주세요.'); message = 'late' }
        $res['finishedAt'] = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Add-Log $res "예약 시각 $([int]$late)분 초과 - 올리지 않음"
        Save-Result $id $res
        $script:Alert = $true
        return 'processed'
    }
    if ($waitedByMe) { Add-Log $res ('미리 와서 기다렸다가 시각에 시작 (예약 시각 대비 ' + [int][math]::Round($late * 60) + '초)') }
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
        Save-Result $id $res; $script:Alert = $true; return 'processed'
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
    return 'processed'
}

# ---------- 예약 파일 읽기 (처음엔 내려받은 폴더, 기다리는 동안엔 보관함에서 다시) ----------
# 반환: @( @{ name; sch } ... )  /  못 읽으면 던짐 (호출한 쪽이 이전 목록을 유지)
function Get-ScheduleSnapshot {
    param([bool]$Remote)
    $out = @()
    if ($Mock -or -not $Remote) {
        if (-not (Test-Path -LiteralPath $SchedDir)) { return @() }
        foreach ($f in @(Get-ChildItem -LiteralPath $SchedDir -Filter 'SCH-*.json' -File | Sort-Object Name)) {
            try { $s = Read-Json ([System.IO.File]::ReadAllText($f.FullName, $Utf8)) } catch { Write-Msg ('읽지 못한 예약 파일: ' + $f.Name); continue }
            if ($s) { $out += , @{ name = $f.Name; sch = $s } }
        }
        return $out
    }
    try { $lst = Call-ApiRead -Url "https://api.github.com/repos/$Repo/contents/schedules" -Headers (Get-GhHeaders) }
    catch { if ([int]$_.Exception.Data['http'] -eq 404) { return @() }; throw }
    foreach ($e in @($lst.Json)) {
        $nm = [string]$e['name']
        if ($nm -notmatch '^SCH-.*\.json$' -or [string]$e['type'] -ne 'file') { continue }
        $sha = [string]$e['sha']
        $c = $script:SchCache[$nm]
        if (-not $c -or $c.sha -ne $sha) {
            try {
                $r = Call-ApiRead -Url "https://api.github.com/repos/$Repo/contents/schedules/$nm" -Headers (Get-GhHeaders)
                $bytes = [Convert]::FromBase64String(([string]$r.Json['content']) -replace '\s', '')
                $s = Read-Json ($Utf8.GetString($bytes).TrimStart([char]0xFEFF))
            } catch { Write-Msg ('읽지 못한 예약 파일: ' + $nm); continue }
            $c = @{ sha = $sha; sch = $s }
            $script:SchCache[$nm] = $c
        }
        if ($c.sch) { $out += , @{ name = $nm; sch = $c.sch } }
    }
    return $out
}

# 예약 하나를 처리 (실패해도 다른 예약에 영향 없게)
function Invoke-Process {
    param($Sch)
    try { return (Process-Schedule $Sch) }
    catch {
        Write-Msg ('예약 처리 중 문제 (' + [string]$Sch['id'] + '): ' + [string]$_.Exception.Message)
        $script:Alert = $true
        try {
            $r = Load-Result ([string]$Sch['id'])
            if (-not $r) { $r = [ordered]@{ kind = 'result'; executor = 'cloud'; scheduleId = [string]$Sch['id']; ep = [string]$Sch['ep']; attempt = $(if ($Sch['attempt']) { [int]$Sch['attempt'] } else { 1 }); steps = [ordered]@{}; log = @() } }
            if ([string]$r['state'] -in @('', 'running', 'waiting', 'released')) { $r['state'] = 'failed'; $r['error'] = Get-ErrInfo $_ 'cloud'; $r['finishedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ'); Save-Result ([string]$Sch['id']) $r }
        } catch {}
        return 'processed'
    }
}

# ---------- 미리 와서 기다리기 ----------
# 반환: 'ok'(내가 기다리는 중으로 표시함) | 'other'(다른 실행이 기다리는 중) | 'terminal'(이미 끝났거나 올리는 중)
function Mark-Waiting {
    param($Sch, $When)
    $id = [string]$Sch['id']
    $att = 1; if ($Sch['attempt']) { $att = [int]$Sch['attempt'] }
    $m = $script:Mine[$id]
    if ($m -and [int]$m.attempt -eq $att -and (((Get-Now) - $m.hbAt).TotalMinutes -lt 5)) { return 'ok' }    # 심장박동은 5분마다만
    $res = Load-Result $id
    if ($res) {
        $ra = 0; if ($res['attempt']) { $ra = [int]$res['attempt'] }
        if ($ra -ge $att) {
            $st = [string]$res['state']
            if ($st -eq 'waiting') {
                if ([string]$res['waitRun'] -ne $RunId -and (Test-Fresh ([string]$res['heartbeat']))) { return 'other' }
            } elseif ($st -ne 'released') { return 'terminal' }
        } else { Reset-ForNewAttempt $res $att }
    } else {
        $res = [ordered]@{ kind = 'result'; executor = 'cloud'; scheduleId = $id; ep = [string]$Sch['ep']; attempt = $att; state = 'waiting'; steps = [ordered]@{}; log = @(); mock = [bool]$Mock; resumes = 0 }
    }
    $nowZ = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $first = (-not $m)
    $res['state'] = 'waiting'; $res['waitRun'] = $RunId; $res['heartbeat'] = $nowZ
    if (-not $res['waitingSince'] -or $first) { $res['waitingSince'] = $nowZ }
    $res['waitingFor'] = [string]$Sch['scheduledAt']
    if ($first) { Add-Log $res ('미리 와서 기다리는 중 (예약 ' + [string]$Sch['scheduledAt'] + ' 한국시간)') }
    Save-Result $id $res
    $script:Mine[$id] = @{ attempt = $att; hbAt = (Get-Now) }
    return 'ok'
}
# 내가 해 둔 waiting 표시 중 지금 기다리는 예약(KeepId)이 아닌 것은 풀어 준다 (취소·시간 변경·끝날 때). 이미 시각이 돼서 올린 것은 건드리지 않음
function Release-Waits {
    param([string]$KeepId = '')
    foreach ($id in @($script:Mine.Keys)) {
        if ($id -eq $KeepId) { continue }
        try {
            $r = Load-Result $id
            if ($r -and [string]$r['state'] -eq 'waiting' -and [string]$r['waitRun'] -eq $RunId) {
                $r['state'] = 'released'; $r['releasedAt'] = (Get-Now).ToString('yyyy-MM-ddTHH:mm:ssZ')
                Add-Log $r '기다리기를 멈췄어요 (예약이 취소·변경됐거나 이 실행이 끝남)'
                Save-Result $id $r
            }
        } catch { Write-Msg ('waiting 표시를 풀지 못했어요: ' + $id) }
        $script:Mine.Remove($id)
    }
}

function Run-Publish {
    $start = Get-Now
    $deadline = $start.AddMinutes($DeadlineMin)
    $snap = Get-ScheduleSnapshot $false
    Write-Msg ('예약 파일 ' + @($snap).Count + '개 확인')
    $remoteFails = 0; $round = 0; $lastMsg = $null
    while ($true) {
        $round++
        $cloud = @()
        foreach ($it in @($snap)) {
            $s = $it.sch
            $sid = [string]$s['id']
            if ($sid -notmatch '^SCH-\d{14}(-\d+)?$' -or [string]$s['executor'] -ne 'cloud' -or [string]$s['status'] -ne 'scheduled') { continue }
            $att = 1; if ($s['attempt']) { $att = [int]$s['attempt'] }
            $key = "$sid|$att"
            if ($script:Finished.ContainsKey($key)) { continue }
            $cloud += , @{ sch = $s; key = $key; when = (Get-When $s) }
        }
        # 시각을 읽지 못한 것은 Process-Schedule 이 알림을 남긴다 (한 번만)
        foreach ($c in @($cloud | Where-Object { $null -eq $_.when })) { Invoke-Process $c.sch | Out-Null; $script:Finished[$c.key] = $true }
        $cloud = @($cloud | Where-Object { $null -ne $_.when } | Sort-Object { $_.when })
        # 1) 시각이 된 것 (시간 순서대로)
        foreach ($c in $cloud) {
            if ($script:Finished.ContainsKey($c.key)) { continue }
            if ($c.when.AddSeconds(-$LeadSec) -gt (Get-Now)) { continue }
            $r = Invoke-Process $c.sch
            if ($r -in @('finished', 'processed')) { $script:Finished[$c.key] = $true }
        }
        if (-not $Wait) { break }
        # 2) 앞으로 WaitWindowMin 분 안에 시각이 되는 다음 예약 -> 기다릴 곳 정하기
        $now = Get-Now
        $target = $null
        foreach ($c in $cloud) {
            if ($script:Finished.ContainsKey($c.key)) { continue }
            $startAt = $c.when.AddSeconds(-$LeadSec)
            if ($startAt -le $now) { continue }                          # 이미 시각이 된 것(다른 실행이 처리 중 등)은 위에서 봤음
            if (($c.when - $now).TotalMinutes -gt $WaitWindowMin) { break }   # 시간 순서라 뒤는 더 멀다
            if ($startAt -gt $deadline) { break }                        # 이 실행의 기다리기 한도를 넘김 -> 다음 실행이 이어받음
            if ($script:NoWait.ContainsKey($c.key)) { continue }
            $m = Mark-Waiting $c.sch $c.when
            if ($m -eq 'ok') { $target = $c; break }
            $script:NoWait[$c.key] = $m
            Write-Msg ('기다리지 않음: ' + [string]$c.sch['id'] + ' (' + $m + ')')
        }
        Release-Waits $(if ($target) { [string]$target.sch['id'] } else { '' })
        if (-not $target) { break }
        $secs = [int][math]::Ceiling(($target.when.AddSeconds(-$LeadSec) - (Get-Now)).TotalSeconds)
        $sleep = [math]::Min($PollSec, [math]::Max(1, $secs))
        if ($null -eq $lastMsg -or ((Get-Now) - $lastMsg).TotalMinutes -ge 10) {
            Write-Msg ('기다리는 중: ' + [string]$target.sch['id'] + ' (' + [string]$target.sch['scheduledAt'] + ' 한국시간, 약 ' + [int]($secs / 60) + '분 남음)')
            $lastMsg = Get-Now
        }
        Wait-Sec $sleep
        # 3) 기다리는 동안 바뀐 것(취소·시간 변경·새 예약)을 보관함에서 다시 읽는다
        try { $snap = Get-ScheduleSnapshot $true; $remoteFails = 0 }
        catch {
            $remoteFails++
            Write-Msg ('예약 파일을 다시 읽지 못했어요 (' + $remoteFails + '번째): ' + [string]$_.Exception.Message)
            if ($remoteFails -ge 4) { Write-Msg '계속 읽지 못해 기다리기를 멈춰요 (다음 실행이 이어받아요).'; $script:Alert = $true; break }
        }
    }
    Release-Waits ''
}

# ---------- 본 흐름 ----------
Write-Msg "클라우드 예약 확인 시작 (mode=$Mode, mock=$([bool]$Mock))"
try {
    if ($Mock -and $MockEvents) { $script:Events = @(Read-Json ([System.IO.File]::ReadAllText($MockEvents, $Utf8))) }
    if ($Mode -eq 'check') { Run-Check }
    else { Run-Publish }
} catch {
    Write-Msg ('치명적 문제: ' + [string]$_.Exception.Message)
    $script:Alert = $true
    try { Release-Waits '' } catch {}
}
if ($script:Alert) { Write-Msg '확인이 필요한 일이 있어요 (실패 알림용으로 이 실행을 실패로 표시합니다).'; exit 1 }
Write-Msg '끝'
exit 0
