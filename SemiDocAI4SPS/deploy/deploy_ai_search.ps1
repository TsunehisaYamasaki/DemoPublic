<#
.SYNOPSIS
    Azure AI Search + Azure OpenAI デプロイスクリプト
    Cosmos DB (ocr-data) → AI Search Index → RAG Agent → GPT-4o

.DESCRIPTION
    既存の Cosmos DB (semiconductor-db / ocr-data) に対して:
    1. Azure AI Search サービスを作成
    2. Azure OpenAI サービス + gpt-4o デプロイメントを作成
    3. AI Search Managed Identity に Cosmos DB 読み取りロールを割り当て
    4. データソース / インデックス / インデクサーを作成
    5. インデクサーを即時実行
#>
$ErrorActionPreference = "Stop"

# ═══════════════ 設定 ═══════════════════════════════════
$RESOURCE_GROUP    = "rg-<your-prefix>"
$LOCATION          = "eastus2"
$COSMOS_ACCOUNT    = "cosmos-<your-prefix>"
$COSMOS_DB         = "semiconductor-db"

$SEARCH_SERVICE    = "search-<your-prefix>"
$OPENAI_ACCOUNT    = "openai-<your-prefix>"
$OPENAI_DEPLOY     = "gpt-4o"
$OPENAI_MODEL      = "gpt-4o"
$OPENAI_CAPACITY   = 10   # 10K TPM (最小)
$EMBEDDING_DEPLOY  = "text-embedding-ada-002"
$EMBEDDING_MODEL   = "text-embedding-ada-002"

# ═══════════════ 0. ログイン確認 ════════════════════════
Write-Host "`n=== 0. Azure ログイン確認 ===" -ForegroundColor Cyan
$accountInfo = az account show 2>$null | ConvertFrom-Json
if (-not $accountInfo) {
    az login --use-device-code
    $accountInfo = az account show | ConvertFrom-Json
}
Write-Host "ログイン済み: $($accountInfo.user.name) / $($accountInfo.name)" -ForegroundColor Green
$SUBSCRIPTION_ID = $accountInfo.id

# ═══════════════ 1. Azure AI Search ════════════════════
Write-Host "`n=== 1. Azure AI Search サービス作成 ===" -ForegroundColor Cyan
az search service create `
    --name $SEARCH_SERVICE `
    --resource-group $RESOURCE_GROUP `
    --location $LOCATION `
    --sku basic `
    --identity-type SystemAssigned `
    --output table
Write-Host "AI Search 作成完了: $SEARCH_SERVICE" -ForegroundColor Green

# 管理キー取得
$SEARCH_ADMIN_KEY = az search admin-key show `
    --resource-group $RESOURCE_GROUP `
    --service-name $SEARCH_SERVICE `
    --query primaryKey -o tsv
$SEARCH_ENDPOINT = "https://$SEARCH_SERVICE.search.windows.net"
Write-Host "Endpoint: $SEARCH_ENDPOINT" -ForegroundColor Green

# ═══════════════ 2. Azure OpenAI ═══════════════════════
Write-Host "`n=== 2. Azure OpenAI サービス作成 ===" -ForegroundColor Cyan
az cognitiveservices account create `
    --name $OPENAI_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --kind OpenAI `
    --sku S0 `
    --location $LOCATION `
    --custom-domain $OPENAI_ACCOUNT `
    --output table
Write-Host "OpenAI 作成完了: $OPENAI_ACCOUNT" -ForegroundColor Green

# GPT-4o デプロイメント
Write-Host "  gpt-4o デプロイメント作成..." -ForegroundColor Yellow
az cognitiveservices account deployment create `
    --name $OPENAI_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --deployment-name $OPENAI_DEPLOY `
    --model-name $OPENAI_MODEL `
    --model-version "2024-11-20" `
    --model-format OpenAI `
    --sku-name GlobalStandard `
    --sku-capacity $OPENAI_CAPACITY `
    --output table
Write-Host "GPT-4o デプロイ完了" -ForegroundColor Green

# text-embedding-ada-002 デプロイメント (ベクトル化用)
Write-Host "  text-embedding-ada-002 デプロイメント作成..." -ForegroundColor Yellow
az cognitiveservices account deployment create `
    --name $OPENAI_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --deployment-name $EMBEDDING_DEPLOY `
    --model-name $EMBEDDING_MODEL `
    --model-version "2" `
    --model-format OpenAI `
    --sku-name Standard `
    --sku-capacity 120 `
    --output table
Write-Host "text-embedding-ada-002 デプロイ完了" -ForegroundColor Green

$OPENAI_ENDPOINT = "https://$OPENAI_ACCOUNT.openai.azure.com"

# ═══════════════ 3. RBAC ロール割り当て ═════════════════
Write-Host "`n=== 3. RBAC ロール割り当て ===" -ForegroundColor Cyan

# AI Search の Managed Identity Principal ID
$SEARCH_PRINCIPAL_ID = az search service show `
    --name $SEARCH_SERVICE `
    --resource-group $RESOURCE_GROUP `
    --query identity.principalId -o tsv
Write-Host "  AI Search Principal ID: $SEARCH_PRINCIPAL_ID" -ForegroundColor Green

# Cosmos DB Built-in Data Reader ロールを AI Search MI に割り当て
Write-Host "  Cosmos DB Data Reader → AI Search MI..." -ForegroundColor Yellow
az cosmosdb sql role assignment create `
    --account-name $COSMOS_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --scope "/" `
    --principal-id $SEARCH_PRINCIPAL_ID `
    --role-definition-id "00000000-0000-0000-0000-000000000001" `
    --output table 2>$null
Write-Host "  Cosmos DB Data Reader 割り当て完了" -ForegroundColor Green

# Cosmos DB Account Reader Role (ARM レベル — MI 接続に必要)
$COSMOS_SCOPE = az cosmosdb show --name $COSMOS_ACCOUNT --resource-group $RESOURCE_GROUP --query id -o tsv
Write-Host "  Cosmos DB Account Reader Role → AI Search MI..." -ForegroundColor Yellow
az role assignment create `
    --assignee $SEARCH_PRINCIPAL_ID `
    --role "Cosmos DB Account Reader Role" `
    --scope $COSMOS_SCOPE `
    --output table 2>$null
Write-Host "  Cosmos DB Account Reader Role 割り当て完了" -ForegroundColor Green

# 現在のユーザーに OpenAI User ロールを割り当て
$USER_OBJECT_ID = az ad signed-in-user show --query id -o tsv
$OPENAI_SCOPE = az cognitiveservices account show `
    --name $OPENAI_ACCOUNT `
    --resource-group $RESOURCE_GROUP `
    --query id -o tsv
Write-Host "  Cognitive Services OpenAI User → 現在のユーザー..." -ForegroundColor Yellow
az role assignment create `
    --assignee $USER_OBJECT_ID `
    --role "Cognitive Services OpenAI User" `
    --scope $OPENAI_SCOPE `
    --output table 2>$null
Write-Host "  OpenAI User 割り当て完了" -ForegroundColor Green

# AI Search にも OpenAI User ロールを割り当て (将来の統合用)
az role assignment create `
    --assignee $SEARCH_PRINCIPAL_ID `
    --role "Cognitive Services OpenAI User" `
    --scope $OPENAI_SCOPE `
    --output table 2>$null

# ═══════════════ 4. Cosmos DB 接続情報 (Managed Identity) ═
Write-Host "`n=== 4. Cosmos DB 接続情報取得 ===" -ForegroundColor Cyan
$COSMOS_MI_CONN_STR = "ResourceId=/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.DocumentDB/databaseAccounts/$COSMOS_ACCOUNT;Database=$COSMOS_DB;IdentityAuthType=AccessToken"
Write-Host "Cosmos DB MI 接続文字列を構成完了" -ForegroundColor Green

# ═══════════════ 5. AI Search データソース作成 ══════════
Write-Host "`n=== 5. AI Search データソース作成 ===" -ForegroundColor Cyan
$headers = @{
    "api-key"      = $SEARCH_ADMIN_KEY
    "Content-Type" = "application/json"
}

# ocr-data データソース (Managed Identity 認証)
$ocrDataSource = @{
    name        = "cosmosdb-ocr-data"
    type        = "cosmosdb"
    credentials = @{
        connectionString = $COSMOS_MI_CONN_STR
    }
    container   = @{
        name  = "ocr-data"
        query = $null
    }
    dataChangeDetectionPolicy = @{
        "@odata.type" = "#Microsoft.Azure.Search.HighWaterMarkChangeDetectionPolicy"
        highWaterMarkColumnName = "_ts"
    }
} | ConvertTo-Json -Depth 10

try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/datasources?api-version=2024-07-01" `
        -Method Post -Headers $headers -Body $ocrDataSource
    Write-Host "  cosmosdb-ocr-data データソース作成成功" -ForegroundColor Green
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  cosmosdb-ocr-data データソース既存 → 更新" -ForegroundColor Yellow
        Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/datasources/cosmosdb-ocr-data?api-version=2024-07-01" `
            -Method Put -Headers $headers -Body $ocrDataSource
    } else { throw }
}

# processed-files データソース (Managed Identity 認証)
$procDataSource = @{
    name        = "cosmosdb-processed-files"
    type        = "cosmosdb"
    credentials = @{
        connectionString = $COSMOS_MI_CONN_STR
    }
    container   = @{
        name  = "processed-files"
        query = $null
    }
    dataChangeDetectionPolicy = @{
        "@odata.type" = "#Microsoft.Azure.Search.HighWaterMarkChangeDetectionPolicy"
        highWaterMarkColumnName = "_ts"
    }
} | ConvertTo-Json -Depth 10

try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/datasources?api-version=2024-07-01" `
        -Method Post -Headers $headers -Body $procDataSource
    Write-Host "  cosmosdb-processed-files データソース作成成功" -ForegroundColor Green
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  cosmosdb-processed-files データソース既存 → 更新" -ForegroundColor Yellow
        Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/datasources/cosmosdb-processed-files?api-version=2024-07-01" `
            -Method Put -Headers $headers -Body $procDataSource
    } else { throw }
}

# ═══════════════ 6. AI Search インデックス作成 ══════════
Write-Host "`n=== 6. AI Search インデックス作成 ===" -ForegroundColor Cyan

# ocr-data インデックス (ベクトル化 + セマンティック構成)
$ocrIndexBody = @"
{
  "name": "ocr-data-index",
  "fields": [
    {"name": "id", "type": "Edm.String", "key": true, "searchable": false, "filterable": true},
    {"name": "filename", "type": "Edm.String", "searchable": true, "filterable": true, "sortable": true},
    {"name": "fileType", "type": "Edm.String", "searchable": true, "filterable": true},
    {"name": "department", "type": "Edm.String", "searchable": true, "filterable": true, "facetable": true},
    {"name": "source", "type": "Edm.String", "searchable": false, "filterable": true},
    {"name": "status", "type": "Edm.String", "searchable": false, "filterable": true},
    {"name": "content", "type": "Edm.String", "searchable": true, "filterable": false},
    {"name": "createdAt", "type": "Edm.String", "searchable": false, "filterable": true, "sortable": true},
    {"name": "spoItemId", "type": "Edm.String", "searchable": false, "filterable": true},
    {"name": "rid", "type": "Edm.String", "searchable": false, "filterable": false},
    {"name": "contentVector", "type": "Collection(Edm.Single)", "searchable": true, "dimensions": 1536, "vectorSearchProfile": "vector-profile"}
  ],
  "vectorSearch": {
    "algorithms": [{"name": "hnsw-algorithm", "kind": "hnsw", "hnswParameters": {"m": 4, "efConstruction": 400, "efSearch": 500, "metric": "cosine"}}],
    "vectorizers": [{"name": "openai-vectorizer", "kind": "azureOpenAI", "azureOpenAIParameters": {"resourceUri": "$OPENAI_ENDPOINT", "deploymentId": "$EMBEDDING_DEPLOY", "modelName": "$EMBEDDING_MODEL"}}],
    "profiles": [{"name": "vector-profile", "algorithm": "hnsw-algorithm", "vectorizer": "openai-vectorizer"}]
  },
  "semantic": {
    "defaultConfiguration": "semantic-config",
    "configurations": [{
      "name": "semantic-config",
      "prioritizedFields": {
        "titleField": {"fieldName": "filename"},
        "prioritizedContentFields": [{"fieldName": "content"}],
        "prioritizedKeywordsFields": [{"fieldName": "department"}, {"fieldName": "fileType"}]
      }
    }]
  }
}
"@
try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/indexes?api-version=2024-07-01" `
        -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($ocrIndexBody)) -ContentType "application/json; charset=utf-8"
    Write-Host "  ocr-data-index 作成成功 (ベクトル + セマンティック)" -ForegroundColor Green
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  ocr-data-index 既存 → スキップ" -ForegroundColor Yellow
    } else { throw }
}

# processed-files インデックス (ベクトル化 + セマンティック構成)
$procIndexBody = @"
{
  "name": "processed-files-index",
  "fields": [
    {"name": "id", "type": "Edm.String", "key": true, "searchable": false, "filterable": true},
    {"name": "fileId", "type": "Edm.String", "searchable": false, "filterable": true},
    {"name": "fileName", "type": "Edm.String", "searchable": true, "filterable": true, "sortable": true},
    {"name": "lastModified", "type": "Edm.String", "searchable": false, "filterable": true, "sortable": true},
    {"name": "processedAt", "type": "Edm.String", "searchable": false, "filterable": true, "sortable": true},
    {"name": "rid", "type": "Edm.String", "searchable": false, "filterable": false},
    {"name": "fileNameVector", "type": "Collection(Edm.Single)", "searchable": true, "dimensions": 1536, "vectorSearchProfile": "vector-profile"}
  ],
  "vectorSearch": {
    "algorithms": [{"name": "hnsw-algorithm", "kind": "hnsw", "hnswParameters": {"m": 4, "efConstruction": 400, "efSearch": 500, "metric": "cosine"}}],
    "vectorizers": [{"name": "openai-vectorizer", "kind": "azureOpenAI", "azureOpenAIParameters": {"resourceUri": "$OPENAI_ENDPOINT", "deploymentId": "$EMBEDDING_DEPLOY", "modelName": "$EMBEDDING_MODEL"}}],
    "profiles": [{"name": "vector-profile", "algorithm": "hnsw-algorithm", "vectorizer": "openai-vectorizer"}]
  },
  "semantic": {
    "defaultConfiguration": "semantic-config",
    "configurations": [{
      "name": "semantic-config",
      "prioritizedFields": {
        "titleField": {"fieldName": "fileName"},
        "prioritizedContentFields": [{"fieldName": "fileName"}],
        "prioritizedKeywordsFields": []
      }
    }]
  }
}
"@
try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/indexes?api-version=2024-07-01" `
        -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($procIndexBody)) -ContentType "application/json; charset=utf-8"
    Write-Host "  processed-files-index 作成成功 (ベクトル + セマンティック)" -ForegroundColor Green
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  processed-files-index 既存 → スキップ" -ForegroundColor Yellow
    } else { throw }
}

# ═══════════════ 7. スキルセット作成 (エンベディング) ═══
Write-Host "`n=== 7. スキルセット作成 ===" -ForegroundColor Cyan

$ocrSkillset = '{"name":"ocr-embedding-skillset","skills":[{"@odata.type":"#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill","name":"content-embedding","context":"/document","resourceUri":"' + $OPENAI_ENDPOINT + '","deploymentId":"' + $EMBEDDING_DEPLOY + '","modelName":"' + $EMBEDDING_MODEL + '","authResourceId":"https://cognitiveservices.azure.com","inputs":[{"name":"text","source":"/document/content"}],"outputs":[{"name":"embedding","targetName":"contentVector"}]}]}'
try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/skillsets?api-version=2024-07-01" `
        -Method Post -Headers $headers -Body $ocrSkillset -ContentType "application/json"
    Write-Host "  ocr-embedding-skillset 作成成功" -ForegroundColor Green
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  ocr-embedding-skillset 既存 → スキップ" -ForegroundColor Yellow
    } else { throw }
}

$procSkillset = '{"name":"processed-embedding-skillset","skills":[{"@odata.type":"#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill","name":"filename-embedding","context":"/document","resourceUri":"' + $OPENAI_ENDPOINT + '","deploymentId":"' + $EMBEDDING_DEPLOY + '","modelName":"' + $EMBEDDING_MODEL + '","authResourceId":"https://cognitiveservices.azure.com","inputs":[{"name":"text","source":"/document/fileName"}],"outputs":[{"name":"embedding","targetName":"fileNameVector"}]}]}'
try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/skillsets?api-version=2024-07-01" `
        -Method Post -Headers $headers -Body $procSkillset -ContentType "application/json"
    Write-Host "  processed-embedding-skillset 作成成功" -ForegroundColor Green
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  processed-embedding-skillset 既存 → スキップ" -ForegroundColor Yellow
    } else { throw }
}

# ═══════════════ 8. AI Search インデクサー作成 ══════════
Write-Host "`n=== 8. AI Search インデクサー作成 ===" -ForegroundColor Cyan

# ocr-data インデクサー (スキルセット付き)
$ocrIndexer = '{"name":"ocr-data-indexer","dataSourceName":"cosmosdb-ocr-data","targetIndexName":"ocr-data-index","skillsetName":"ocr-embedding-skillset","schedule":{"interval":"PT2H"},"fieldMappings":[{"sourceFieldName":"rid","targetFieldName":"rid"}],"outputFieldMappings":[{"sourceFieldName":"/document/contentVector","targetFieldName":"contentVector"}]}'
try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/indexers?api-version=2024-07-01" `
        -Method Post -Headers $headers -Body $ocrIndexer -ContentType "application/json"
    Write-Host "  ocr-data-indexer 作成成功 (with embedding skillset)" -ForegroundColor Green
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  ocr-data-indexer 既存 → スキップ" -ForegroundColor Yellow
    } else { throw }
}

# processed-files インデクサー (スキルセット付き)
$procIndexer = '{"name":"processed-files-indexer","dataSourceName":"cosmosdb-processed-files","targetIndexName":"processed-files-index","skillsetName":"processed-embedding-skillset","schedule":{"interval":"PT2H"},"fieldMappings":[{"sourceFieldName":"rid","targetFieldName":"rid"}],"outputFieldMappings":[{"sourceFieldName":"/document/fileNameVector","targetFieldName":"fileNameVector"}]}'
try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/indexers?api-version=2024-07-01" `
        -Method Post -Headers $headers -Body $procIndexer -ContentType "application/json"
    Write-Host "  processed-files-indexer 作成成功 (with embedding skillset)" -ForegroundColor Green
} catch {
    if ($_.Exception.Response.StatusCode -eq 409) {
        Write-Host "  processed-files-indexer 既存 → スキップ" -ForegroundColor Yellow
    } else { throw }
}

# ═══════════════ 9. インデクサー即時実行 ════════════════
Write-Host "`n=== 9. インデクサー即時実行 ===" -ForegroundColor Cyan
try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/indexers/ocr-data-indexer/run?api-version=2024-07-01" `
        -Method Post -Headers $headers
    Write-Host "  ocr-data-indexer 実行開始" -ForegroundColor Green
} catch {
    Write-Host "  ocr-data-indexer 実行警告: $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    Invoke-RestMethod -Uri "$SEARCH_ENDPOINT/indexers/processed-files-indexer/run?api-version=2024-07-01" `
        -Method Post -Headers $headers
    Write-Host "  processed-files-indexer 実行開始" -ForegroundColor Green
} catch {
    Write-Host "  processed-files-indexer 実行警告: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ═══════════════ 完了サマリー ═══════════════════════════
Write-Host "`n" -NoNewline
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  AI Search + OpenAI デプロイ完了！" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "リソース:" -ForegroundColor Cyan
Write-Host "  AI Search      : $SEARCH_ENDPOINT"
Write-Host "  OpenAI         : $OPENAI_ENDPOINT"
Write-Host "  GPT-4o Deploy  : $OPENAI_DEPLOY"
Write-Host ""
Write-Host "インデックス:" -ForegroundColor Cyan
Write-Host "  ocr-data-index         : OCR テキストデータ (content, filename, department)"
Write-Host "  processed-files-index  : 処理済みファイル追跡"
Write-Host ""
Write-Host "インデクサー:" -ForegroundColor Cyan
Write-Host "  ocr-data-indexer       : 2時間ごとに自動更新"
Write-Host "  processed-files-indexer : 2時間ごとに自動更新"
Write-Host ""
Write-Host "次のステップ:" -ForegroundColor Yellow
Write-Host "  1. インデクサーの完了を待つ (1-2分)"
Write-Host "  2. RAG Agent を実行: python tools\rag_agent.py"
Write-Host "  3. 質問例: python tools\rag_agent.py `"DRCエラーが多い設計を教えて`""
Write-Host ""
