param(
  [string]$EnvFile = ".env"
)

$script:Failures = 0
$script:Warnings = 0
$script:Passes = 0
$script:Skipped = 0

function Import-EnvFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }

  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith("#")) {
      continue
    }

    $idx = $line.IndexOf("=")
    if ($idx -lt 1) {
      continue
    }

    $name = $line.Substring(0, $idx).Trim()
    $value = $line.Substring($idx + 1).Trim()

    if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
      $value = $value.Substring(1, $value.Length - 2)
    }

    [Environment]::SetEnvironmentVariable($name, $value, "Process")
  }
}

function Normalize-V1Base {
  param([string]$BaseUrl)

  $trimmed = $BaseUrl.TrimEnd("/")
  if ($trimmed -match "/v\d+$") {
    return $trimmed
  }
  return "$trimmed/v1"
}

function Truncate-Text {
  param(
    [string]$Text,
    [int]$Limit = 280
  )

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ""
  }

  $singleLine = ($Text -replace "\s+", " ").Trim()
  if ($singleLine.Length -le $Limit) {
    return $singleLine
  }
  return $singleLine.Substring(0, $Limit)
}

function Test-OpenAICompatibleModels {
  param(
    [string]$Name,
    [string]$BaseUrl,
    [string]$ApiKey
  )

  if ([string]::IsNullOrWhiteSpace($BaseUrl) -or [string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host ("[SKIP] {0}: missing base url or api key." -f $Name)
    $script:Skipped++
    return
  }

  $v1Base = Normalize-V1Base -BaseUrl $BaseUrl
  $url = "$v1Base/models"
  $headers = @{ Authorization = "Bearer $ApiKey" }

  try {
    $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 35
    if ($null -ne $resp.data) {
      Write-Host "[PASS] ${Name}: HTTP 200, models endpoint reachable."
      $script:Passes++
    }
    else {
      Write-Host "[WARN] ${Name}: HTTP 200 but response does not include data."
      $script:Warnings++
    }
  }
  catch {
    $statusCode = ""
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $statusCode = "HTTP " + [int]$_.Exception.Response.StatusCode
    }
    $errorText = ""
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      $errorText = $_.ErrorDetails.Message
    }
    if ([string]::IsNullOrWhiteSpace($errorText)) {
      $errorText = $_.Exception.Message
    }

    if ($statusCode -match "^HTTP 4\d\d|^HTTP 5\d\d") {
      $script:Warnings++
      Write-Host "[WARN] ${Name}: $statusCode (endpoint reachable, API rejected request)."
      Write-Host "       response: $(Truncate-Text -Text $errorText)"

      if ($errorText -match "Settlement blocked|SETTLEMENT_UNKNOWN_MODEL") {
        Write-Host "       hint: network is reachable; this is a provider-side model/billing mapping issue."
      }
      elseif ($errorText -match "invalid api key" -and $BaseUrl -match "api\.minimax\.io") {
        Write-Host "       hint: this key may belong to Token Plan CN endpoint."
        Write-Host "       hint: try MINIMAX_BASE_URL=https://api.minimaxi.com"
      }
    }
    else {
      $script:Failures++
      Write-Host "[FAIL] ${Name}: $statusCode"
      Write-Host "       response: $(Truncate-Text -Text $errorText)"
    }
  }
}

function Test-OpenAICompatibleChat {
  param(
    [string]$Name,
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$Model
  )

  if ([string]::IsNullOrWhiteSpace($BaseUrl) -or [string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host ("[SKIP] {0}: missing base url or api key." -f $Name)
    $script:Skipped++
    return
  }

  if ([string]::IsNullOrWhiteSpace($Model)) {
    Write-Host ("[SKIP] {0}: missing model." -f $Name)
    $script:Skipped++
    return
  }

  $v1Base = Normalize-V1Base -BaseUrl $BaseUrl
  $url = "$v1Base/chat/completions"
  $headers = @{
    Authorization = "Bearer $ApiKey"
    "Content-Type" = "application/json"
  }
  $body = @{
    model = $Model
    messages = @(
      @{
        role = "user"
        content = "ping"
      }
    )
    max_tokens = 16
  } | ConvertTo-Json -Depth 8

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body -TimeoutSec 35
    if ($null -ne $resp.choices -or $null -ne $resp.id) {
      Write-Host "[PASS] ${Name}: HTTP 200, chat completion endpoint reachable."
      $script:Passes++
    }
    else {
      Write-Host "[WARN] ${Name}: HTTP 200 but response is missing expected fields."
      $script:Warnings++
    }
  }
  catch {
    $statusCode = ""
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      $statusCode = "HTTP " + [int]$_.Exception.Response.StatusCode
    }
    $errorText = ""
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
      $errorText = $_.ErrorDetails.Message
    }
    if ([string]::IsNullOrWhiteSpace($errorText)) {
      $errorText = $_.Exception.Message
    }

    if ($statusCode -match "^HTTP 4\d\d|^HTTP 5\d\d") {
      $script:Warnings++
      Write-Host "[WARN] ${Name}: $statusCode (endpoint reachable, API rejected request)."
      Write-Host "       response: $(Truncate-Text -Text $errorText)"

      if ($errorText -match "Settlement blocked|SETTLEMENT_UNKNOWN_MODEL") {
        Write-Host "       hint: network is reachable; this is a provider-side model/billing mapping issue."
      }
      elseif ($errorText -match "model_not_found|unknown model") {
        Write-Host "       hint: model may be unavailable for this provider/account."
      }
    }
    else {
      $script:Failures++
      Write-Host "[FAIL] ${Name}: $statusCode"
      Write-Host "       response: $(Truncate-Text -Text $errorText)"
    }
  }
}

Import-EnvFile -Path $EnvFile

Write-Host "Running LLM API connectivity checks..."
Write-Host ""

if ([string]::IsNullOrWhiteSpace($env:AICM_MODEL)) {
  $env:AICM_MODEL = "gpt-5.3-codex"
}

Test-OpenAICompatibleChat `
  -Name "AICodeMirror(Chat Completions)" `
  -BaseUrl $env:AICM_BASE_URL `
  -ApiKey $env:AICM_API_KEY `
  -Model $env:AICM_MODEL

if ([string]::IsNullOrWhiteSpace($env:MINIMAX_BASE_URL)) {
  $env:MINIMAX_BASE_URL = "https://api.minimaxi.com"
}

Test-OpenAICompatibleModels `
  -Name "MiniMax(OpenAI-Compatible)" `
  -BaseUrl $env:MINIMAX_BASE_URL `
  -ApiKey $env:MINIMAX_API_KEY

Write-Host ""
Write-Host "Summary: pass=$($script:Passes) warn=$($script:Warnings) network_fail=$($script:Failures) skip=$($script:Skipped)"

if ($script:Failures -eq 0) {
  Write-Host "Network connectivity check passed."
  if ($script:Warnings -gt 0) {
    Write-Host "There are API-level warnings (key/model/plan), but network path is reachable."
  }
  exit 0
}

Write-Host "Network connectivity check failed: $($script:Failures) endpoint(s) unreachable."
exit 1
