<#
.SYNOPSIS
    SharePoint Online → Document Intelligence → Cosmos DB サーバーレスシステム 一括デプロイスクリプト

.DESCRIPTION
    以下の Azure リソースを自動作成・設定する:
    1. リソースグループ
    2. Cosmos DB アカウント + データベース + コンテナ (ocr-data, processed-files)
    3. Document Intelligence
    4. Storage Account (Functions 用)
    5. Azure Functions (Flex Consumption / Python 3.11)
    6. Azure AD App Registration (Graph API 用)
    7. Managed Identity ロール割り当て
    8. Function App デプロイ

.PARAMETER SkipAppRegistration
    Azure AD App Registration をスキップする (既に作成済みの場合)
#>
param(
    [switch]$SkipAppRegistration
)

$ErrorActionPreference = "Stop"

# ═══════════════ 設定 ═══════════════════════════════════
$RESOURCE_GROUP    = "rg-<your-prefix>"
$LOCATION          = "westus3"
$ACCOUNT           = "<your-user>@<your-tenant>.onmicrosoft.com"

$COSMOS_ACCOUNT    = "cosmos-<your-prefix>"
$COSMOS_DB         = "semiconductor-db"
$COSMOS_CONTAINER_OCR = "ocr-data"
$COSMOS_CONTAINER_PROC = "processed-files"

$DOCINT_ACCOUNT    = "docint-<your-prefix>"
$STORAGE_ACCOUNT   = "sa<your-prefix>"
$FUNC_APP          = "func-<your-prefix>"

$APP_REG_NAME      = "app-<your-prefix>"

$SPO_SITE_URL      = "<your-tenant>.sharepoint.com:/sites/<your-site>"
$SPO_FOLDER        = "folder1"

# ═══════════════ 0. ログイン確認 ════════════════════════
Write-Host "`n=== 0. Azure ログイン確認 ===" -ForegroundColor Cyan
$accountInfo = az account show 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    Write-Host "Azure にログインしています..." -ForegroundColor Yellow
    az login --use-device-code
}
Write-Host "ログイン済み: $($accountInfo.user.name) / $($accountInfo.name)" -ForegroundColor Green

# ═══════════════ 1. リソースグループ ════════════════════
Write-Host "`n=== 1. リソースグループ作成 ===" -ForegroundColor Cyan
az group create --name $RESOURCE_GROUP --location $LOCATION --output table

# ═══════════════ 2. Cosmos DB ═══════════════════════════
Write-Host "`n=== 2. Cosmos DB アカウント作成 ===" -ForegroundColor Cyan
az cosmosdb create `
    --name $COSMOS_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --locations regionName=$LOCATION failoverPriority=0 isZoneRedundant=false `
    --default-consistency-level Session `
    --kind GlobalDocumentDB `
    --output table

Write-Host "  データベース作成..." -ForegroundColor Yellow
az cosmosdb sql database create `
    --account-name $COSMOS_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --name $COSMOS_DB `
    --output table

Write-Host "  ocr-data コンテナ作成..." -ForegroundColor Yellow
az cosmosdb sql container create `
    --account-name $COSMOS_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --database-name $COSMOS_DB `
    --name $COSMOS_CONTAINER_OCR `
    --partition-key-path "/filename" `
    --output table

Write-Host "  processed-files コンテナ作成..." -ForegroundColor Yellow
az cosmosdb sql container create `
    --account-name $COSMOS_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --database-name $COSMOS_DB `
    --name $COSMOS_CONTAINER_PROC `
    --partition-key-path "/fileId" `
    --output table

Write-Host "Cosmos DB 作成完了" -ForegroundColor Green

# ═══════════════ 3. Document Intelligence ═══════════════
Write-Host "`n=== 3. Document Intelligence 作成 ===" -ForegroundColor Cyan
az cognitiveservices account create `
    --name $DOCINT_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --kind FormRecognizer `
    --sku S0 `
    --location $LOCATION `
    --custom-domain $DOCINT_ACCOUNT `
    --output table
Write-Host "Document Intelligence 作成完了" -ForegroundColor Green

# ═══════════════ 4. Storage Account ═════════════════════
Write-Host "`n=== 4. Storage Account 作成 (Functions 用) ===" -ForegroundColor Cyan
az storage account create `
    --name $STORAGE_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --location $LOCATION `
    --sku Standard_LRS `
    --output table
Write-Host "Storage Account 作成完了" -ForegroundColor Green

# ═══════════════ 5. Azure Functions ═════════════════════
Write-Host "`n=== 5. Azure Functions 作成 ===" -ForegroundColor Cyan

# Flex Consumption を試み、ダメなら Consumption (Y1) にフォールバック
$funcCreated = $false
try {
    az functionapp create `
        --name $FUNC_APP `
        --resource-group $RESOURCE_GROUP `
        --storage-account $STORAGE_ACCOUNT `
        --flexconsumption-location $LOCATION `
        --runtime python `
        --runtime-version 3.11 `
        --output table
    $funcCreated = $true
    Write-Host "Azure Functions (Flex Consumption) 作成完了" -ForegroundColor Green
} catch {
    Write-Host "Flex Consumption 作成失敗。Consumption (Y1) で再試行..." -ForegroundColor Yellow
}

if (-not $funcCreated) {
    az functionapp create `
        --name $FUNC_APP `
        --resource-group $RESOURCE_GROUP `
        --storage-account $STORAGE_ACCOUNT `
        --consumption-plan-location $LOCATION `
        --runtime python `
        --runtime-version 3.11 `
        --os-type Linux `
        --functions-version 4 `
        --output table
    Write-Host "Azure Functions (Consumption Y1) 作成完了" -ForegroundColor Green
}

# System-assigned Managed Identity 有効化
Write-Host "  Managed Identity 有効化..." -ForegroundColor Yellow
az functionapp identity assign `
    --name $FUNC_APP `
    --resource-group $RESOURCE_GROUP `
    --output table

$FUNC_PRINCIPAL_ID = (az functionapp identity show `
    --name $FUNC_APP `
    --resource-group $RESOURCE_GROUP `
    --query principalId -o tsv)

Write-Host "  Principal ID: $FUNC_PRINCIPAL_ID" -ForegroundColor Green

# ═══════════════ 6. Managed Identity ロール割り当て ═════
Write-Host "`n=== 6. RBAC ロール割り当て ===" -ForegroundColor Cyan

# Cosmos DB - データ共同作成者
$COSMOS_SCOPE = (az cosmosdb show --name $COSMOS_ACCOUNT --resource-group $RESOURCE_GROUP --query id -o tsv)
Write-Host "  Cosmos DB ロール割り当て..." -ForegroundColor Yellow

# Cosmos DB built-in Data Contributor ロール
az cosmosdb sql role assignment create `
    --account-name $COSMOS_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --scope "/" `
    --principal-id $FUNC_PRINCIPAL_ID `
    --role-definition-id "00000000-0000-0000-0000-000000000002" `
    --output table 2>$null
Write-Host "  Cosmos DB Data Contributor 割り当て完了" -ForegroundColor Green

# Document Intelligence - Cognitive Services User
$DOCINT_SCOPE = (az cognitiveservices account show --name $DOCINT_ACCOUNT --resource-group $RESOURCE_GROUP --query id -o tsv)
az role assignment create `
    --assignee $FUNC_PRINCIPAL_ID `
    --role "Cognitive Services User" `
    --scope $DOCINT_SCOPE `
    --output table 2>$null
Write-Host "  Document Intelligence Cognitive Services User 割り当て完了" -ForegroundColor Green

# Storage Account - Storage Blob Data Owner (Functions ランタイム用)
$STORAGE_SCOPE = (az storage account show --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --query id -o tsv)
az role assignment create `
    --assignee $FUNC_PRINCIPAL_ID `
    --role "Storage Blob Data Owner" `
    --scope $STORAGE_SCOPE `
    --output table 2>$null
Write-Host "  Storage Blob Data Owner 割り当て完了" -ForegroundColor Green

# ═══════════════ 7. Azure AD App Registration ═══════════
if (-not $SkipAppRegistration) {
    Write-Host "`n=== 7. Azure AD App Registration (Graph API 用) ===" -ForegroundColor Cyan

    # アプリ作成
    $appJson = az ad app create --display-name $APP_REG_NAME --output json | ConvertFrom-Json
    $APP_ID = $appJson.appId
    $APP_OBJECT_ID = $appJson.id
    Write-Host "  App ID: $APP_ID" -ForegroundColor Green

    # Client Secret 作成
    $secretJson = az ad app credential reset `
        --id $APP_OBJECT_ID `
        --display-name "func-secret" `
        --years 2 `
        --output json | ConvertFrom-Json
    $CLIENT_SECRET = $secretJson.password
    $TENANT_ID = $secretJson.tenant
    Write-Host "  Tenant ID: $TENANT_ID" -ForegroundColor Green
    Write-Host "  Client Secret: (取得済み - 安全に保管してください)" -ForegroundColor Yellow

    # Service Principal 作成
    az ad sp create --id $APP_ID --output table 2>$null

    # Graph API 権限追加 (Sites.Read.All = アプリ許可)
    # Microsoft Graph の appId: 00000003-0000-0000-c000-000000000000
    # Sites.Read.All (Application): 332a536c-c7ef-4017-ab91-336970924f0d
    Write-Host "  Graph API 権限 (Sites.Read.All) 追加..." -ForegroundColor Yellow
    az ad app permission add `
        --id $APP_OBJECT_ID `
        --api 00000003-0000-0000-c000-000000000000 `
        --api-permissions 332a536c-c7ef-4017-ab91-336970924f0d=Role `
        --output table 2>$null

    # 管理者の同意を付与
    Write-Host "  管理者の同意を付与中..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    az ad app permission admin-consent --id $APP_OBJECT_ID 2>$null
    Write-Host "  Graph API 権限設定完了" -ForegroundColor Green

} else {
    Write-Host "`n=== 7. App Registration スキップ ===" -ForegroundColor Yellow
    $APP_ID = Read-Host "既存の App (Client) ID を入力"
    $CLIENT_SECRET = Read-Host "既存の Client Secret を入力"
    $TENANT_ID = Read-Host "Tenant ID を入力"
}

# ═══════════════ 8. Function App 設定 ═══════════════════
Write-Host "`n=== 8. Function App アプリケーション設定 ===" -ForegroundColor Cyan
az functionapp config appsettings set `
    --name $FUNC_APP `
    --resource-group $RESOURCE_GROUP `
    --settings `
        "DOCUMENT_INTELLIGENCE_ENDPOINT=https://$DOCINT_ACCOUNT.cognitiveservices.azure.com/" `
        "COSMOS_DB_ENDPOINT=https://$COSMOS_ACCOUNT.documents.azure.com:443/" `
        "COSMOS_DB_DATABASE=$COSMOS_DB" `
        "COSMOS_DB_CONTAINER=$COSMOS_CONTAINER_OCR" `
        "COSMOS_DB_PROCESSED_CONTAINER=$COSMOS_CONTAINER_PROC" `
        "SHAREPOINT_SITE_URL=$SPO_SITE_URL" `
        "SHAREPOINT_FOLDER_PATH=$SPO_FOLDER" `
        "GRAPH_CLIENT_ID=$APP_ID" `
        "GRAPH_CLIENT_SECRET=$CLIENT_SECRET" `
        "GRAPH_TENANT_ID=$TENANT_ID" `
    --output table
Write-Host "アプリケーション設定完了" -ForegroundColor Green

# ═══════════════ 9. Function App デプロイ ═══════════════
Write-Host "`n=== 9. Function App コードデプロイ ===" -ForegroundColor Cyan
$projectRoot = Split-Path -Parent $PSScriptRoot

Write-Host "  zip パッケージ作成中..." -ForegroundColor Yellow
$zipPath = Join-Path $env:TEMP "func-deploy-spo.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

# デプロイ対象ファイルを zip にまとめる
$deployFiles = @(
    (Join-Path $projectRoot "host.json"),
    (Join-Path $projectRoot "requirements.txt")
)
$functionAppDir = Join-Path $projectRoot "function_app"

# Compress-Archive で作成
$tempDeploy = Join-Path $env:TEMP "func-deploy-spo-temp"
if (Test-Path $tempDeploy) { Remove-Item $tempDeploy -Recurse -Force }
New-Item -ItemType Directory -Path $tempDeploy | Out-Null

Copy-Item (Join-Path $projectRoot "host.json") -Destination $tempDeploy
Copy-Item (Join-Path $projectRoot "requirements.txt") -Destination $tempDeploy
Copy-Item $functionAppDir -Destination (Join-Path $tempDeploy "function_app") -Recurse

Compress-Archive -Path "$tempDeploy\*" -DestinationPath $zipPath -Force
Remove-Item $tempDeploy -Recurse -Force

Write-Host "  デプロイ中..." -ForegroundColor Yellow
az functionapp deployment source config-zip `
    --resource-group $RESOURCE_GROUP `
    --name $FUNC_APP `
    --src $zipPath `
    --output table

Remove-Item $zipPath -Force
Write-Host "Function App デプロイ完了" -ForegroundColor Green

# ═══════════════ 完了サマリー ═══════════════════════════
Write-Host "`n" -NoNewline
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  デプロイ完了！" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "リソース一覧:" -ForegroundColor Cyan
Write-Host "  リソースグループ     : $RESOURCE_GROUP"
Write-Host "  Cosmos DB            : $COSMOS_ACCOUNT"
Write-Host "  Document Intelligence: $DOCINT_ACCOUNT"
Write-Host "  Storage Account      : $STORAGE_ACCOUNT"
Write-Host "  Azure Functions      : $FUNC_APP"
Write-Host "  App Registration     : $APP_REG_NAME (Client ID: $APP_ID)"
Write-Host ""
Write-Host "SharePoint 設定:" -ForegroundColor Cyan
Write-Host "  Site URL : $SPO_SITE_URL"
Write-Host "  Folder   : $SPO_FOLDER"
Write-Host ""
Write-Host "次のステップ:" -ForegroundColor Yellow
Write-Host "  1. SharePoint folder1 にドキュメントをアップロード"
Write-Host "  2. 5分後に自動処理されます"
Write-Host "  3. Cosmos DB でデータ確認: python tools\query_cosmos.py"
Write-Host ""
