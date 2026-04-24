<#
.SYNOPSIS
  Fabric Pipeline (pl-sql-to-lakehouse) の作成・実行スクリプト

.DESCRIPTION
  GUI で OPDG コネクションを 2 件作成した後、このスクリプトを実行します。
  コネクション ID を引数に渡すと pipeline_sql_kv_def.json のプレースホルダを置換し
  Fabric API 経由で Pipeline を作成・実行します。

.PARAMETER KvWebConnId
  KV 用 OPDG Web コネクションの ID (Fabric ポータル → Manage Connections → コネクション詳細 URL の末尾)

.PARAMETER SqlConnId
  SQL Server 用 OPDG コネクションの ID (同上)

.PARAMETER LakehouseId
  コピー先 Lakehouse の Artifact ID (既定: lh_pipeline の ID)

.PARAMETER RunPipeline
  $true の場合、作成後すぐに Pipeline を実行して結果を確認する (既定: $true)

.EXAMPLE
  .\create_sql_pipeline.ps1 `
    -KvWebConnId  "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -SqlConnId    "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$KvWebConnId,

    [Parameter(Mandatory=$true)]
    [string]$SqlConnId,

    [string]$LakehouseId    = "<YOUR_LAKEHOUSE_ID>",       # Lakehouse の Artifact ID
    [string]$WorkspaceId    = "<YOUR_WORKSPACE_ID>",        # Fabric Workspace ID
    [string]$PipelineName   = "pl-sql-to-lakehouse",
    [string]$PipelineDefJson= "pipeline_sql_kv_def.json",
    [bool]  $RunPipeline    = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#-----------------------------------------------------------------------
# 0. Fabric アクセストークン取得
#-----------------------------------------------------------------------
Write-Host "[1/4] Acquiring Fabric access token..."
$tok = az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv
$h   = @{
    Authorization  = "Bearer $tok"
    "Content-Type" = "application/json"
}

#-----------------------------------------------------------------------
# 1. Pipeline 定義の読み込みとプレースホルダ置換
#-----------------------------------------------------------------------
Write-Host "[2/4] Building pipeline definition..."
$pipeJsonRaw = Get-Content -Raw $PipelineDefJson

$pipeJson = $pipeJsonRaw `
    -replace "__CONN_ID_KV_WEB_OPDG__", $KvWebConnId `
    -replace "__CONN_ID_SQL_OPDG__",    $SqlConnId `
    -replace "__LAKEHOUSE_ARTIFACT_ID__", $LakehouseId `
    -replace "__WORKSPACE_ID__",          $WorkspaceId

# JSON 構文確認
$pipeJsonRaw | ConvertFrom-Json | Out-Null  # original parse check
Write-Host "  -> Pipeline JSON built OK"

#-----------------------------------------------------------------------
# 2. Pipeline 作成 (or 上書き)
#-----------------------------------------------------------------------
Write-Host "[3/4] Creating Fabric Data Pipeline ($PipelineName)..."

# 既存 Pipeline を確認して削除
$existing = Invoke-RestMethod `
    -Uri     "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/dataPipelines" `
    -Headers $h `
    -ErrorAction SilentlyContinue

if ($existing -and $existing.value) {
    $dup = $existing.value | Where-Object { $_.displayName -eq $PipelineName }
    if ($dup) {
        Write-Host "  -> Deleting existing pipeline: $($dup.id)"
        Invoke-RestMethod `
            -Method  Delete `
            -Uri     "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/dataPipelines/$($dup.id)" `
            -Headers $h | Out-Null
        Start-Sleep 5
    }
}

$b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pipeJson))
$body = @{
    displayName = $PipelineName
    description = "OPDG 経由で KV PE から SQL 認証情報を取得し、SQL PE から Lakehouse にデータをコピー"
    definition  = @{
        parts = @(
            @{
                path        = "pipeline-content.json"
                payload     = $b64
                payloadType = "InlineBase64"
            }
        )
    }
} | ConvertTo-Json -Depth 8

$resp = Invoke-WebRequest `
    -Method  Post `
    -Uri     "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/dataPipelines" `
    -Headers $h `
    -Body    $body `
    -UseBasicParsing

Write-Host "  -> Status: $($resp.StatusCode)"

$pipeId = $null
if ($resp.StatusCode -eq 201) {
    $pipeId = ($resp.Content | ConvertFrom-Json).id
    Write-Host "  -> Pipeline ID: $pipeId"
} else {
    # 202 Accepted with LRO
    $loc = $resp.Headers.Location
    if ($loc -is [array]) { $loc = $loc[0] }
    Write-Host "  -> LRO: $loc"
    do {
        Start-Sleep 5
        $st = Invoke-RestMethod $loc -Headers $h
        Write-Host "  -> lro=$($st.status)"
    } while ($st.status -in @("Running","NotStarted"))

    $result = Invoke-RestMethod "$loc/result" -Headers $h
    $pipeId = $result.id
    Write-Host "  -> Pipeline ID: $pipeId"
}

if (-not $pipeId) {
    Write-Error "Pipeline creation failed. Check response above."
    exit 1
}

# Pipeline ID を保存
$pipeId | Set-Content "sql_pipeline_id.txt"
Write-Host "  -> Pipeline ID saved to sql_pipeline_id.txt"

#-----------------------------------------------------------------------
# 3. Pipeline 実行 (オプション)
#-----------------------------------------------------------------------
if (-not $RunPipeline) {
    Write-Host "`n===== DONE (Pipeline not executed - set -RunPipeline `$true to run) ====="
    exit 0
}

Write-Host "[4/4] Running pipeline $PipelineName..."
$runResp = Invoke-WebRequest `
    -Method  Post `
    -Uri     "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$pipeId/jobs/instances?jobType=Pipeline" `
    -Headers $h `
    -Body    "{}" `
    -UseBasicParsing

Write-Host "  -> Run Status: $($runResp.StatusCode)"
$runLoc = $runResp.Headers.Location
if ($runLoc -is [array]) { $runLoc = $runLoc[0] }
Write-Host "  -> Polling: $runLoc"

$finalStatus = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep 20
    $st = Invoke-RestMethod $runLoc -Headers $h
    $errCode = ""
    if ($st.PSObject.Properties.Name -contains "failureReason" -and $st.failureReason) {
        if ($st.failureReason.PSObject.Properties.Name -contains "errorCode") {
            $errCode = $st.failureReason.errorCode
        }
    }
    Write-Host "  -> [$i] status=$($st.status) failure=$errCode"
    if ($st.status -in @("Completed","Failed","Cancelled")) {
        $finalStatus = $st.status
        $st | ConvertTo-Json -Depth 8
        break
    }
}

if ($finalStatus -eq "Completed") {
    Write-Host "`n===== PIPELINE SUCCEEDED ====="
    Write-Host ""
    Write-Host "Verifying Lakehouse table..."
    $stoTok = az account get-access-token --resource "https://storage.azure.com/" --query accessToken -o tsv
    $h2 = @{
        Authorization  = "Bearer $stoTok"
        "x-ms-version" = "2023-08-03"
    }
    $lhBase = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$LakehouseId"
    try {
        $tables = Invoke-RestMethod "$lhBase/Tables?resource=filesystem&recursive=false" -Headers $h2
        Write-Host "Tables in Lakehouse:"
        $tables | ConvertTo-Json -Depth 3
    } catch {
        Write-Host "Note: Direct OneLake query for Tables may require different path. Check Fabric Portal."
    }
} else {
    Write-Host "`n===== PIPELINE $finalStatus ====="
    Write-Host "Check Fabric Portal for details."
}
