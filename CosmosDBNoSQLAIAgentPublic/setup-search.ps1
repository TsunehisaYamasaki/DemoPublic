$searchEndpoint = "https://<YOUR-SEARCH-SERVICE-NAME>.search.windows.net"
$searchAdminKey = "<YOUR-SEARCH-ADMIN-KEY>"
$headers = @{ "api-key" = $searchAdminKey; "Content-Type" = "application/json" }

Write-Host "=== Creating AI Search Indexers ===" -ForegroundColor Cyan

# Create designs-indexer
Write-Host "Creating designs-indexer..." -ForegroundColor Yellow
$designsIndexerBody = @"
{
    "name": "designs-indexer",
    "dataSourceName": "designs-ds",
    "targetIndexName": "designs-index",
    "schedule": { "interval": "PT2H" },
    "parameters": { "maxFailedItems": 10, "maxFailedItemsPerBatch": 5 }
}
"@

try {
    $r1 = Invoke-RestMethod -Uri "$searchEndpoint/indexers?api-version=2023-11-01" -Method Post -Headers $headers -Body $designsIndexerBody
    Write-Host "  OK: designs-indexer created" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "  Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red }
}

# Create manufacturing-indexer
Write-Host "Creating manufacturing-indexer..." -ForegroundColor Yellow
$mfgIndexerBody = @"
{
    "name": "manufacturing-indexer",
    "dataSourceName": "manufacturing-ds",
    "targetIndexName": "manufacturing-index",
    "schedule": { "interval": "PT2H" },
    "parameters": { "maxFailedItems": 10, "maxFailedItemsPerBatch": 5 }
}
"@

try {
    $r2 = Invoke-RestMethod -Uri "$searchEndpoint/indexers?api-version=2023-11-01" -Method Post -Headers $headers -Body $mfgIndexerBody
    Write-Host "  OK: manufacturing-indexer created" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host "  Detail: $($_.ErrorDetails.Message)" -ForegroundColor Red }
}

# Run indexers immediately
Write-Host "`nRunning indexers..." -ForegroundColor Yellow
try {
    Invoke-RestMethod -Uri "$searchEndpoint/indexers/designs-indexer/run?api-version=2023-11-01" -Method Post -Headers @{ "api-key" = $searchAdminKey }
    Write-Host "  OK: designs-indexer started" -ForegroundColor Green
} catch {
    Write-Host "  Warning: $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    Invoke-RestMethod -Uri "$searchEndpoint/indexers/manufacturing-indexer/run?api-version=2023-11-01" -Method Post -Headers @{ "api-key" = $searchAdminKey }
    Write-Host "  OK: manufacturing-indexer started" -ForegroundColor Green
} catch {
    Write-Host "  Warning: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "`n=== Done ===" -ForegroundColor Cyan

# Wait and check status
Write-Host "Checking indexer status..." -ForegroundColor Yellow
$status1 = Invoke-RestMethod -Uri "$searchEndpoint/indexers/designs-indexer/status?api-version=2023-11-01" -Method Get -Headers @{ "api-key" = $searchAdminKey }
Write-Host "  designs-indexer: $($status1.status) - lastResult: $($status1.lastResult.status)" -ForegroundColor Cyan

$status2 = Invoke-RestMethod -Uri "$searchEndpoint/indexers/manufacturing-indexer/status?api-version=2023-11-01" -Method Get -Headers @{ "api-key" = $searchAdminKey }
Write-Host "  manufacturing-indexer: $($status2.status) - lastResult: $($status2.lastResult.status)" -ForegroundColor Cyan
