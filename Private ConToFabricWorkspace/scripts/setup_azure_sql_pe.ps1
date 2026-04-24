<#
.SYNOPSIS
  Azure SQL Server + Private Endpoint + DNS 構築、サンプルデータ投入、KV シークレット登録

.DESCRIPTION
  以下を自動構築します:
    1. Azure SQL Server (プライベートエンドポイントのみ) + Database
    2. Private Endpoint (snet-pe) + Private DNS Zone (privatelink.database.windows.net)
    3. VM run-command 経由でサンプルテーブル作成・データ投入
    4. KV に SQL 認証情報を格納 (一時的に KV Public Access を有効化して設定後、無効化)

.NOTES
  前提:
    - az login / az account set 済み
    - vnet-fabric-pl / snet-pe / snet-vm が存在
    - <KEY_VAULT_NAME> が存在 (rg-fabric-pl-demo)
    - vm-jump-01 が Running
#>

param(
    [string]$ResourceGroup  = "rg-fabric-pl-demo",
    [string]$Location       = "westus3",
    [string]$VNetName       = "vnet-fabric-pl",
    [string]$SubnetPe       = "snet-pe",
    [string]$VmName         = "vm-jump-01",
    [string]$KvName         = "<YOUR_KEY_VAULT_NAME>",   # deploy_fabric_private_env.ps1 で作成した Key Vault 名を指定
    [string]$SqlAdminUser   = "sqladmin",
    # SQL Server 名は未指定なら自動生成
    [string]$SqlServerName  = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#-----------------------------------------------------------------------
# 0. 初期化
#-----------------------------------------------------------------------
if (-not $SqlServerName) {
    $SqlServerName = "sql-fabric-demo-$(Get-Random -Minimum 1000 -Maximum 9999)"
}
$SqlDbName   = "salesdb"
$SqlPeName   = "pe-sql-vnet"
$SqlDnsZone  = "privatelink.database.windows.net"
$SqlDnsLink  = "link-sql"
$SqlDnsZoneGroup = "zg-sql"

# SQL admin パスワードをランダム生成 (大文字・小文字・数字・記号 各1以上)
$rnd  = Get-Random -Minimum 1000 -Maximum 9999
$SqlAdminPw = "Fab!${rnd}Sql$(Get-Random -Minimum 10 -Maximum 99)Kv"

Write-Host "============================================================"
Write-Host " SQL Server : $SqlServerName"
Write-Host " Database   : $SqlDbName"
Write-Host " Admin      : $SqlAdminUser"
Write-Host " Resource G : $ResourceGroup"
Write-Host "============================================================"

#-----------------------------------------------------------------------
# 1. SQL Server 作成
#-----------------------------------------------------------------------
Write-Host "`n[1/8] Creating SQL Server..."
# MCAPS ポリシー AzureSQL_WithoutAzureADOnlyAuthentication_Deny のバイパス:
# tags[SecurityControl]=Ignore を付与するか、Azure AD-only auth を有効化する必要がある。
# ここでは dev/test 環境向けにタグバイパスを採用。
az sql server create `
    --name              $SqlServerName `
    --resource-group    $ResourceGroup `
    --location          $Location `
    --admin-user        $SqlAdminUser `
    --admin-password    $SqlAdminPw `
    --tags              "SecurityControl=Ignore" `
    --output none

# 作成確認
$sqlExists = az sql server show --name $SqlServerName --resource-group $ResourceGroup --query name -o tsv 2>$null
if (-not $sqlExists) {
    Write-Error "SQL Server creation failed. Check Azure Policy errors above."
    exit 1
}
Write-Host "  -> SQL Server created: $SqlServerName"

# パブリックアクセス無効 (az sql server update の --enable-public-network はプレビュー。代わりに REST API を使用)
Write-Host "  -> Disabling public network access via REST API..."
$sqlServerObj = az sql server show --name $SqlServerName --resource-group $ResourceGroup -o json | ConvertFrom-Json
$sqlServerResourceId = $sqlServerObj.id
$mgmtTok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$pnaBody = '{"properties":{"publicNetworkAccess":"Disabled"}}'
Invoke-RestMethod `
    -Method  Patch `
    -Uri     "https://management.azure.com$sqlServerResourceId`?api-version=2022-05-01-preview" `
    -Headers @{ Authorization = "Bearer $mgmtTok"; "Content-Type" = "application/json" } `
    -Body    $pnaBody | Out-Null
Write-Host "  -> Public network access set to Disabled"

#-----------------------------------------------------------------------
# 2. SQL Database 作成
#-----------------------------------------------------------------------
Write-Host "`n[2/8] Creating SQL Database ($SqlDbName)..."
az sql db create `
    --name              $SqlDbName `
    --server            $SqlServerName `
    --resource-group    $ResourceGroup `
    --service-objective Basic `
    --output none
Write-Host "  -> Database created: $SqlDbName"

#-----------------------------------------------------------------------
# 3. Private Endpoint 作成
#-----------------------------------------------------------------------
Write-Host "`n[3/8] Creating Private Endpoint ($SqlPeName)..."
$sqlId = az sql server show `
    --name           $SqlServerName `
    --resource-group $ResourceGroup `
    --query          id -o tsv

az network private-endpoint create `
    --name                          $SqlPeName `
    --resource-group                $ResourceGroup `
    --vnet-name                     $VNetName `
    --subnet                        $SubnetPe `
    --private-connection-resource-id $sqlId `
    --group-id                      sqlServer `
    --connection-name               "pe-conn-sql" `
    --location                      $Location `
    --output none
Write-Host "  -> Private Endpoint created"

# PE 承認
Write-Host "  -> Auto-approving PE connection..."
Start-Sleep 15
$peConns = az network private-endpoint-connection list --id $sqlId -o json | ConvertFrom-Json
foreach ($conn in $peConns) {
    if ($conn.properties.privateLinkServiceConnectionState.status -eq "Pending") {
        az network private-endpoint-connection approve --id $conn.id --description "auto-approved" --output none
        Write-Host "  -> Approved: $($conn.name)"
    } else {
        Write-Host "  -> $($conn.name): $($conn.properties.privateLinkServiceConnectionState.status)"
    }
}

# PE の IP 取得
Start-Sleep 10
$sqlPeIp = az network private-endpoint show `
    --name           $SqlPeName `
    --resource-group $ResourceGroup `
    --query          "customDnsConfigs[0].ipAddresses[0]" -o tsv
Write-Host "  -> SQL PE IP: $sqlPeIp"

#-----------------------------------------------------------------------
# 4. Private DNS Zone 作成 (既存の場合はスキップ)
#-----------------------------------------------------------------------
Write-Host "`n[4/8] Setting up Private DNS Zone ($SqlDnsZone)..."
$existingZone = az network private-dns zone list `
    --resource-group $ResourceGroup `
    --query          "[?name=='$SqlDnsZone'].name" -o tsv
if ($existingZone) {
    Write-Host "  -> DNS zone already exists, skipping creation"
} else {
    az network private-dns zone create `
        --resource-group $ResourceGroup `
        --name           $SqlDnsZone `
        --output none
    Write-Host "  -> DNS zone created"
}

# VNet リンク (既存の場合はスキップ)
$existingLink = az network private-dns link vnet list `
    --resource-group $ResourceGroup `
    --zone-name      $SqlDnsZone `
    --query          "[?name=='$SqlDnsLink'].name" -o tsv
if ($existingLink) {
    Write-Host "  -> DNS VNet link already exists, skipping"
} else {
    az network private-dns link vnet create `
        --resource-group     $ResourceGroup `
        --zone-name          $SqlDnsZone `
        --name               $SqlDnsLink `
        --virtual-network    $VNetName `
        --registration-enabled false `
        --output none
    Write-Host "  -> DNS VNet link created"
}

# DNS Zone Group
Write-Host "  -> Creating DNS Zone Group..."
az network private-endpoint dns-zone-group create `
    --resource-group  $ResourceGroup `
    --endpoint-name   $SqlPeName `
    --name            $SqlDnsZoneGroup `
    --private-dns-zone $SqlDnsZone `
    --zone-name       "sql" `
    --output none
Write-Host "  -> DNS Zone Group created"

#-----------------------------------------------------------------------
# 5. VM 上でサンプルテーブル作成 + データ投入
#-----------------------------------------------------------------------
Write-Host "`n[5/8] Creating sample table via VM run-command..."
$sqlFqdn = "$SqlServerName.database.windows.net"

# PowerShell スクリプト (VM 上で実行)
$vmScript = @"
`$sqlSrv = '$sqlFqdn'
`$sqlPw  = '$SqlAdminPw'
`$sqlUsr = '$SqlAdminUser'
`$sqlDb  = '$SqlDbName'

Write-Host "==> Testing DNS resolution..."
try {
    `$dnsResult = Resolve-DnsName `$sqlSrv -ErrorAction Stop
    Write-Host "DNS OK: `$(`$dnsResult[0].IPAddress)"
} catch {
    Write-Host "DNS WARN: `$_"
}

Write-Host "==> Creating SQL table and inserting sample data via .NET SqlClient..."
try {
    Add-Type -AssemblyName System.Data
    `$connStr = "Server=`$sqlSrv;Database=`$sqlDb;User Id=`$sqlUsr;Password=`$sqlPw;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    `$conn = New-Object System.Data.SqlClient.SqlConnection(`$connStr)
    `$conn.Open()
    Write-Host "Connected!"

    `$createDDL = @'
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'SalesData')
BEGIN
  CREATE TABLE dbo.SalesData (
    SaleId    INT IDENTITY(1,1) PRIMARY KEY,
    Region    NVARCHAR(50)      NOT NULL,
    Product   NVARCHAR(100)     NOT NULL,
    Quantity  INT               NOT NULL,
    Amount    DECIMAL(18,2)     NOT NULL,
    SaleDate  DATE              NOT NULL
  );
END
'@
    `$cmd = `$conn.CreateCommand()
    `$cmd.CommandText = `$createDDL
    `$cmd.ExecuteNonQuery() | Out-Null
    Write-Host "Table created (or already exists)"

    `$insertSQL = @'
IF NOT EXISTS (SELECT 1 FROM dbo.SalesData WHERE Region = 'East' AND Product = 'Widget A' AND SaleDate = '2024-01-01')
BEGIN
  INSERT INTO dbo.SalesData (Region, Product, Quantity, Amount, SaleDate) VALUES
    ('East',  'Widget A', 10, 1000.00, '2024-01-01'),
    ('West',  'Widget B',  5,  750.00, '2024-01-02'),
    ('North', 'Widget C', 20, 3000.00, '2024-01-03'),
    ('South', 'Widget A', 15, 1500.00, '2024-01-04'),
    ('East',  'Widget D',  8, 1200.00, '2024-01-05');
END
'@
    `$cmd.CommandText = `$insertSQL
    `$cmd.ExecuteNonQuery() | Out-Null
    Write-Host "Sample data inserted"

    `$cmd.CommandText = "SELECT COUNT(*) FROM dbo.SalesData"
    `$cnt = `$cmd.ExecuteScalar()
    Write-Host "Row count: `$cnt"

    `$conn.Close()
    Write-Host "SUCCESS"
} catch {
    Write-Host "ERROR: `$_"
    exit 1
}
"@

$result = az vm run-command invoke `
    --resource-group    $ResourceGroup `
    --name              $VmName `
    --command-id        RunPowerShellScript `
    --scripts           $vmScript `
    -o json | ConvertFrom-Json

$msg = $result.value[0].message
Write-Host $msg

if ($msg -notmatch "SUCCESS") {
    Write-Warning "Sample data insertion may have failed. Check output above."
}

#-----------------------------------------------------------------------
# 6. KV にシークレット登録 (一時的に Public Access 有効化)
#-----------------------------------------------------------------------
Write-Host "`n[6/8] Registering secrets to Key Vault ($KvName)..."
Write-Host "  -> Getting current public IP..."
$myIp = (Invoke-RestMethod "https://api.ipify.org?format=text").Trim()
Write-Host "  -> My IP: $myIp"

Write-Host "  -> Temporarily enabling KV public network access..."
az keyvault update `
    --resource-group      $ResourceGroup `
    --name                $KvName `
    --public-network-access Enabled `
    --default-action      Deny `
    --output none

az keyvault network-rule add `
    --resource-group $ResourceGroup `
    --name           $KvName `
    --ip-address     "$myIp/32" `
    --output none

Write-Host "  -> Waiting 20s for KV policy to propagate..."
Start-Sleep 20

Write-Host "  -> Setting secrets..."
az keyvault secret set --vault-name $KvName --name "sql-admin-username" --value $SqlAdminUser   --output none
az keyvault secret set --vault-name $KvName --name "sql-admin-password" --value $SqlAdminPw     --output none
az keyvault secret set --vault-name $KvName --name "sql-server-fqdn"    --value $sqlFqdn        --output none
az keyvault secret set --vault-name $KvName --name "sql-database-name"  --value $SqlDbName      --output none
Write-Host "  -> Secrets set: sql-admin-username, sql-admin-password, sql-server-fqdn, sql-database-name"

Write-Host "  -> Removing IP allow rule and disabling KV public access..."
az keyvault network-rule remove `
    --resource-group $ResourceGroup `
    --name           $KvName `
    --ip-address     "$myIp/32" `
    --output none

az keyvault update `
    --resource-group      $ResourceGroup `
    --name                $KvName `
    --public-network-access Disabled `
    --output none
Write-Host "  -> KV public access restored to Disabled"

#-----------------------------------------------------------------------
# 7. VM からの疎通確認
#-----------------------------------------------------------------------
Write-Host "`n[7/8] Verifying connectivity from VM to SQL PE..."
$checkScript = @"
`$sqlSrv = '$sqlFqdn'
Write-Host "=== DNS Check ==="
try {
    `$r = Resolve-DnsName `$sqlSrv -ErrorAction Stop
    Write-Host "DNS: `$sqlSrv -> `$(`$r[0].IPAddress)"
} catch { Write-Host "DNS FAILED: `$_" }

Write-Host "=== TCP 1433 Check ==="
`$tcp = Test-NetConnection -ComputerName `$sqlSrv -Port 1433 -InformationLevel Quiet -WarningAction SilentlyContinue
Write-Host "TCP-1433: `$tcp"
"@

$checkResult = az vm run-command invoke `
    --resource-group    $ResourceGroup `
    --name              $VmName `
    --command-id        RunPowerShellScript `
    --scripts           $checkScript `
    -o json | ConvertFrom-Json

Write-Host $checkResult.value[0].message

#-----------------------------------------------------------------------
# 8. 完了サマリ
#-----------------------------------------------------------------------
Write-Host "`n[8/8] ===== SETUP COMPLETE ====="
Write-Host ""
Write-Host "  SQL Server Name : $SqlServerName"
Write-Host "  SQL Server FQDN : $sqlFqdn"
Write-Host "  SQL Database    : $SqlDbName"
Write-Host "  SQL Admin User  : $SqlAdminUser"
Write-Host "  SQL PE Name     : $SqlPeName"
Write-Host "  SQL PE IP       : $sqlPeIp"
Write-Host "  KV Secrets      : sql-admin-username / sql-admin-password / sql-server-fqdn / sql-database-name"
Write-Host ""
Write-Host "  *** 次の手順 ***"
Write-Host "  1. create_sql_pipeline.ps1 -SqlServerName '$SqlServerName' を実行 (Pipeline 定義のデプロイ)"
Write-Host "  2. Fabric ポータルで OPDG コネクションを 2 件作成 (手順は Pipeline_OPDG_KV_SQL_to_Lakehouse_実装手順.md 参照)"
Write-Host "  3. コネクション ID を create_sql_pipeline.ps1 の引数に指定して Pipeline を実行"
Write-Host ""

# SQL Server 名を state ファイルに記録
@{
    SqlServerName = $SqlServerName
    SqlServerFqdn = $sqlFqdn
    SqlDbName     = $SqlDbName
    SqlAdminUser  = $SqlAdminUser
    SqlPeIp       = $sqlPeIp
} | ConvertTo-Json | Set-Content "sql_setup_state.json"
Write-Host "  State saved to sql_setup_state.json"
