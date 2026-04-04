<#
.SYNOPSIS
    AI Search インデックスにベクトル化 (Integrated Vectorization) を追加
    Copilot Studio 対応のため、ベクトルフィールド + セマンティック構成 + スキルセットを設定
#>
$ErrorActionPreference = "Stop"

$RESOURCE_GROUP = "rg-<your-prefix>"
$SEARCH_SERVICE = "search-<your-prefix>"
$SEARCH_ENDPOINT = "https://$SEARCH_SERVICE.search.windows.net"
$OPENAI_ENDPOINT = "https://openai-<your-prefix>.openai.azure.com"
$EMBEDDING_DEPLOY = "text-embedding-ada-002"
$API_VERSION = "2024-07-01"

# 管理キー取得
$key = az search admin-key show --resource-group $RESOURCE_GROUP --service-name $SEARCH_SERVICE --query primaryKey -o tsv
$headers = @{
    "api-key"      = $key
    "Content-Type" = "application/json"
}

function Invoke-SearchApi {
    param([string]$Path, [string]$Method = "Get", [string]$Body)
    $uri = "$SEARCH_ENDPOINT/$Path`?api-version=$API_VERSION"
    $params = @{ Uri = $uri; Method = $Method; Headers = $headers }
    if ($Body) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $params.ContentType = "application/json; charset=utf-8"
    }
    Invoke-RestMethod @params
}

# ── 1. 既存リソース削除 ─────────────────────────
Write-Host "=== 1. 既存リソース削除 ===" -ForegroundColor Cyan
foreach ($name in @("ocr-data-indexer", "processed-files-indexer")) {
    try { Invoke-SearchApi "indexers/$name" Delete; Write-Host "  $name 削除" } catch { Write-Host "  $name なし (skip)" }
}
foreach ($name in @("ocr-embedding-skillset", "processed-embedding-skillset")) {
    try { Invoke-SearchApi "skillsets/$name" Delete; Write-Host "  $name 削除" } catch { Write-Host "  $name なし (skip)" }
}
foreach ($name in @("ocr-data-index", "processed-files-index")) {
    try { Invoke-SearchApi "indexes/$name" Delete; Write-Host "  $name 削除" } catch { Write-Host "  $name なし (skip)" }
}

# ── 2. ベクトル化対応インデックス作成 ────────────
Write-Host "`n=== 2. インデックス作成 (ベクトル + セマンティック) ===" -ForegroundColor Cyan

$ocrIndex = @'
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
    "vectorizers": [{"name": "openai-vectorizer", "kind": "azureOpenAI", "azureOpenAIParameters": {"resourceUri": "OPENAI_EP", "deploymentId": "EMBED_DEPLOY", "modelName": "text-embedding-ada-002"}}],
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
'@
$ocrIndex = $ocrIndex.Replace("OPENAI_EP", $OPENAI_ENDPOINT).Replace("EMBED_DEPLOY", $EMBEDDING_DEPLOY)
Invoke-SearchApi "indexes" Post $ocrIndex | Out-Null
Write-Host "  ocr-data-index 作成完了" -ForegroundColor Green

$procIndex = @'
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
    "vectorizers": [{"name": "openai-vectorizer", "kind": "azureOpenAI", "azureOpenAIParameters": {"resourceUri": "OPENAI_EP", "deploymentId": "EMBED_DEPLOY", "modelName": "text-embedding-ada-002"}}],
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
'@
$procIndex = $procIndex.Replace("OPENAI_EP", $OPENAI_ENDPOINT).Replace("EMBED_DEPLOY", $EMBEDDING_DEPLOY)
Invoke-SearchApi "indexes" Post $procIndex | Out-Null
Write-Host "  processed-files-index 作成完了" -ForegroundColor Green

# ── 3. スキルセット作成 (エンベディング) ─────────
Write-Host "`n=== 3. スキルセット作成 ===" -ForegroundColor Cyan

$ocrSkillset = @'
{
  "name": "ocr-embedding-skillset",
  "skills": [{
    "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
    "name": "content-embedding",
    "context": "/document",
    "resourceUri": "OPENAI_EP",
    "deploymentId": "EMBED_DEPLOY",
    "modelName": "text-embedding-ada-002",
    "authResourceId": "https://cognitiveservices.azure.com",
    "inputs": [{"name": "text", "source": "/document/content"}],
    "outputs": [{"name": "embedding", "targetName": "contentVector"}]
  }]
}
'@
$ocrSkillset = $ocrSkillset.Replace("OPENAI_EP", $OPENAI_ENDPOINT).Replace("EMBED_DEPLOY", $EMBEDDING_DEPLOY)
Invoke-SearchApi "skillsets" Post $ocrSkillset | Out-Null
Write-Host "  ocr-embedding-skillset 作成完了" -ForegroundColor Green

$procSkillset = @'
{
  "name": "processed-embedding-skillset",
  "skills": [{
    "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
    "name": "filename-embedding",
    "context": "/document",
    "resourceUri": "OPENAI_EP",
    "deploymentId": "EMBED_DEPLOY",
    "modelName": "text-embedding-ada-002",
    "authResourceId": "https://cognitiveservices.azure.com",
    "inputs": [{"name": "text", "source": "/document/fileName"}],
    "outputs": [{"name": "embedding", "targetName": "fileNameVector"}]
  }]
}
'@
$procSkillset = $procSkillset.Replace("OPENAI_EP", $OPENAI_ENDPOINT).Replace("EMBED_DEPLOY", $EMBEDDING_DEPLOY)
Invoke-SearchApi "skillsets" Post $procSkillset | Out-Null
Write-Host "  processed-embedding-skillset 作成完了" -ForegroundColor Green

# ── 4. インデクサー作成 ──────────────────────────
Write-Host "`n=== 4. インデクサー作成 ===" -ForegroundColor Cyan

$ocrIndexer = '{"name":"ocr-data-indexer","dataSourceName":"cosmosdb-ocr-data","targetIndexName":"ocr-data-index","skillsetName":"ocr-embedding-skillset","schedule":{"interval":"PT2H"},"fieldMappings":[{"sourceFieldName":"rid","targetFieldName":"rid"}],"outputFieldMappings":[{"sourceFieldName":"/document/contentVector","targetFieldName":"contentVector"}]}'
Invoke-SearchApi "indexers" Post $ocrIndexer | Out-Null
Write-Host "  ocr-data-indexer 作成完了" -ForegroundColor Green

$procIndexer = '{"name":"processed-files-indexer","dataSourceName":"cosmosdb-processed-files","targetIndexName":"processed-files-index","skillsetName":"processed-embedding-skillset","schedule":{"interval":"PT2H"},"fieldMappings":[{"sourceFieldName":"rid","targetFieldName":"rid"}],"outputFieldMappings":[{"sourceFieldName":"/document/fileNameVector","targetFieldName":"fileNameVector"}]}'
Invoke-SearchApi "indexers" Post $procIndexer | Out-Null
Write-Host "  processed-files-indexer 作成完了" -ForegroundColor Green

# ── 5. インデクサー即時実行 ──────────────────────
Write-Host "`n=== 5. インデクサー実行 ===" -ForegroundColor Cyan
try { Invoke-SearchApi "indexers/ocr-data-indexer/run" Post; Write-Host "  ocr-data-indexer 実行開始" -ForegroundColor Green } catch { Write-Host "  ocr-data-indexer: $($_.Exception.Message)" -ForegroundColor Yellow }
try { Invoke-SearchApi "indexers/processed-files-indexer/run" Post; Write-Host "  processed-files-indexer 実行開始" -ForegroundColor Green } catch { Write-Host "  processed-files-indexer: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "`n=== 完了 ===" -ForegroundColor Green
Write-Host "インデックスに Integrated Vectorization (text-embedding-ada-002) + Semantic Configuration を追加しました。"
Write-Host "Copilot Studio でインデックスが利用可能になります。"
