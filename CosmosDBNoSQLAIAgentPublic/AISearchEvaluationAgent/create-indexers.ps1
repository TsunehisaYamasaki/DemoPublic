# AI Search インデクサー作成スクリプト
# Managed Identity + AccessToken 認証

$searchEndpoint = "https://search-semiconductor-2923.search.windows.net"
$resourceGroup = "<YOUR-RESOURCE-GROUP>"
$searchServiceName = "search-semiconductor-2923"

Write-Host "=== AI Search インデクサー作成 ===" -ForegroundColor Cyan

# 管理キー取得
$searchAdminKey = az search admin-key show --resource-group $resourceGroup --service-name $searchServiceName --query primaryKey -o tsv

# インデクサー作成
Write-Host "`ndesigns-indexer を作成中..." -ForegroundColor Yellow
$indexer1 = @{
    name = "designs-indexer"
    dataSourceName = "designs-ds"
    targetIndexName = "designs-index"
    schedule = @{ interval = "PT2H" }
} | ConvertTo-Json -Depth 10

try {
    $result1 = Invoke-RestMethod -Uri "$searchEndpoint/indexers?api-version=2023-11-01" `
        -Method Post `
        -Headers @{
            "api-key" = $searchAdminKey
            "Content-Type" = "application/json"
        } `
        -Body $indexer1
    Write-Host "✓ designs-indexer 作成成功!" -ForegroundColor Green
} catch {
    Write-Host "エラー: $_" -ForegroundColor Red
}

# manufacturing インデクサー作成
Write-Host "`nmanufacturing-indexer を作成中..." -ForegroundColor Yellow
$indexer2 = @{
    name = "manufacturing-indexer"
    dataSourceName = "manufacturing-ds"
    targetIndexName = "manufacturing-index"
    schedule = @{ interval = "PT2H" }
} | ConvertTo-Json -Depth 10

try {
    $result2 = Invoke-RestMethod -Uri "$searchEndpoint/indexers?api-version=2023-11-01" `
        -Method Post `
        -Headers @{
            "api-key" = $searchAdminKey
            "Content-Type" = "application/json"
        } `
        -Body $indexer2
    Write-Host "✓ manufacturing-indexer 作成成功!" -ForegroundColor Green
} catch {
    Write-Host "エラー: $_" -ForegroundColor Red
}

# インデクサー即時実行
Write-Host "`nインデクサーを実行中..." -ForegroundColor Yellow
try {
    Invoke-RestMethod -Uri "$searchEndpoint/indexers/designs-indexer/run?api-version=2023-11-01" `
        -Method Post `
        -Headers @{"api-key" = $searchAdminKey}
    Invoke-RestMethod -Uri "$searchEndpoint/indexers/manufacturing-indexer/run?api-version=2023-11-01" `
        -Method Post `
        -Headers @{"api-key" = $searchAdminKey}
    Write-Host "✓ インデクサー実行開始" -ForegroundColor Green
} catch {
    Write-Host "警告: $_" -ForegroundColor Yellow
}

Write-Host "`n=== 完了 ===" -ForegroundColor Green
Write-Host "インデックス作成には数分かかります。" -ForegroundColor Yellow
Write-Host "ステータス確認: az search indexer show-status --name designs-indexer --service-name $searchServiceName --resource-group $resourceGroup" -ForegroundColor Cyan
