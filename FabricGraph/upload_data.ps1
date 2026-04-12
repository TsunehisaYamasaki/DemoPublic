# ============================================================
# OneLake へ Parquet ファイルをアップロードするスクリプト
# 使用前に以下の変数を自分の環境に合わせて設定してください
# ============================================================

$wsId = "<your-workspace-id>"
$lhId = "<your-lakehouse-id>"
$token = (az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv)

$folders = @("adventureworks_customers", "adventureworks_orders")

foreach ($folder in $folders) {
    $basePath = Join-Path $PSScriptRoot "sample_data\adventureworks\$folder"
    $parquetFile = (Get-ChildItem -Path $basePath -Filter "*.parquet")[0]
    $fileName = $parquetFile.Name
    $fileBytes = [System.IO.File]::ReadAllBytes($parquetFile.FullName)
    $fileSize = $fileBytes.Length

    $baseUrl = "https://onelake.dfs.fabric.microsoft.com/$wsId/$lhId/Files/$folder/$fileName"
    
    Write-Host "Uploading $folder ($fileSize bytes)..."
    
    try {
        # Create file
        $null = Invoke-RestMethod -Uri "${baseUrl}?resource=file" -Method Put -Headers @{
            "Authorization" = "Bearer $token"
            "Content-Length" = "0"
        }
        Write-Host "  File resource created"
        
        # Append data
        $null = Invoke-RestMethod -Uri "${baseUrl}?action=append&position=0" -Method Patch -Headers @{
            "Authorization" = "Bearer $token"
            "Content-Length" = "$fileSize"
        } -Body $fileBytes
        Write-Host "  Data appended"
        
        # Flush
        $null = Invoke-RestMethod -Uri "${baseUrl}?action=flush&position=$fileSize" -Method Patch -Headers @{
            "Authorization" = "Bearer $token"
            "Content-Length" = "0"
        }
        Write-Host "  Flushed - Upload complete for $folder"
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)"
        if ($_.Exception.Response) {
            try {
                $sr = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                Write-Host "  Response: $($sr.ReadToEnd())"
            } catch {}
        }
    }
}

Write-Host "`nAll uploads finished!"
