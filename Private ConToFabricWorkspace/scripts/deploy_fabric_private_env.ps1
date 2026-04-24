# =============================================================================
# Microsoft Fabric ワークスペースレベル閉域環境 + Managed PE 自動構築スクリプト
# =============================================================================
# 想定環境:
#   - Subscription : <YOUR_SUBSCRIPTION_NAME> (<YOUR_SUBSCRIPTION_ID>)
#   - Account      : <YOUR_ACCOUNT>@<YOUR_TENANT>.onmicrosoft.com
#   - Capacity     : <YOUR_CAPACITY_NAME> (<YOUR_CAPACITY_ID>)
#
# 制限事項（手動操作が必要）:
#   1. Fabric テナント設定「Configure workspace-level inbound network rules」の有効化
#   2. ワークスペース受信ネットワーク設定で「private link only」へ切替（Phase 8）
#   3. Notebook の作成と実行（Fabric ポータル）
#
# 各フェーズは冪等に作られており、再実行しても既存リソースはスキップされます。
# =============================================================================

[CmdletBinding()]
param(
    [string]$Location          = "westus3",
    [string]$ResourceGroup     = "rg-fabric-pl-demo",
    [string]$VNetName          = "vnet-fabric-pl",
    [string]$VMName            = "vm-jump-01",
    [string]$VMAdminUser       = "azureadmin",
    [string]$BastionName       = "bastion-fabric-pl",
    [string]$BastionPipName    = "pip-bastion-fabric-pl",
    [string]$PLSName           = "pls-fabric-ws-private-demo",
    [string]$PEName            = "pe-fabric-ws-private-demo",
    [string]$DnsZoneFabric     = "privatelink.fabric.microsoft.com",
    [string]$DnsZoneCosmos     = "privatelink.documents.azure.com",
    [string]$DnsZoneKv         = "privatelink.vaultcore.azure.net",
    [string]$WorkspaceName     = "ws-private-demo",
    [string]$CapacityId        = "<YOUR_CAPACITY_ID>",           # Fabric Capacity の ID を指定
    [string]$CosmosAccountName = "cosmos-fabric-demo-$(Get-Random -Max 9999)",
    [string]$CosmosDbName      = "salesdb",
    [string]$CosmosContainerName = "sales",
    [string]$KeyVaultName      = "kvfabdemo$(Get-Random -Max 9999)",
    [string]$MpeCosmosName     = "mpe-cosmos-fabric-demo",
    [string]$MpeKvName         = "mpe-kv-fabric-demo",
    [string]$StateFile         = "$PSScriptRoot\deployment_state.json",
    [switch]$SkipBastion,
    [switch]$SkipVM,
    [switch]$SkipCosmos,
    [switch]$SkipMpe
)

$ErrorActionPreference = "Stop"
$InformationPreference = "Continue"

function Write-Phase($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Step($msg)  { Write-Host "  -> $msg" -ForegroundColor Yellow }
function Write-Ok($msg)    { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Skip($msg)  { Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray }

function Save-State($state) {
    $state | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $StateFile
}
function Load-State() {
    if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json }
    else { [PSCustomObject]@{} }
}

function New-StrongPassword {
    param([int]$Length = 20)
    $upper = [char[]](65..90); $lower = [char[]](97..122); $digit = [char[]](48..57)
    $sym   = [char[]]('!@#%^&*?-_'.ToCharArray())
    $all   = $upper + $lower + $digit + $sym
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    $pw = -join (0..($Length-1) | ForEach-Object { $all[ $bytes[$_] % $all.Length ] })
    # 必須文字種を保証
    $pw = $pw.Substring(0,$Length-4) + ($upper | Get-Random) + ($lower | Get-Random) + ($digit | Get-Random) + ($sym | Get-Random)
    return $pw
}

function Get-FabricToken { az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv }

# -----------------------------------------------------------------------------
$state = Load-State
if (-not $state.PSObject.Properties.Name -contains 'subscriptionId') {
    $state | Add-Member -NotePropertyName subscriptionId -NotePropertyValue (az account show --query id -o tsv) -Force
}

Write-Host "`n#############################################################"
Write-Host "# Fabric Private Workspace 自動構築 開始"
Write-Host "# Subscription : $($state.subscriptionId)"
Write-Host "# RG / Region  : $ResourceGroup / $Location"
Write-Host "# Workspace    : $WorkspaceName"
Write-Host "# State file   : $StateFile"
Write-Host "#############################################################"

# =============================================================================
Write-Phase "Phase 0: リソースプロバイダー登録"
# =============================================================================
foreach ($rp in @("Microsoft.Fabric","Microsoft.Network","Microsoft.Sql","Microsoft.KeyVault","Microsoft.Compute")) {
    $cur = az provider show -n $rp --query registrationState -o tsv
    if ($cur -ne "Registered") {
        Write-Step "$rp を登録中..."
        az provider register -n $rp | Out-Null
        Write-Ok "$rp 登録要求送信"
    } else { Write-Skip "$rp は登録済み" }
}

# =============================================================================
Write-Phase "Phase 1: リソースグループ作成"
# =============================================================================
$rgExists = az group exists -n $ResourceGroup
if ($rgExists -eq "true") { Write-Skip "$ResourceGroup は既に存在" }
else {
    az group create -n $ResourceGroup -l $Location | Out-Null
    Write-Ok "RG $ResourceGroup を作成"
}

# =============================================================================
Write-Phase "Phase 2: 仮想ネットワーク + サブネット作成"
# =============================================================================
$vnet = az network vnet show -g $ResourceGroup -n $VNetName --query id -o tsv 2>$null
if ($vnet) { Write-Skip "VNet $VNetName は存在" }
else {
    az network vnet create -g $ResourceGroup -n $VNetName --address-prefix 10.10.0.0/16 `
        --subnet-name snet-pe --subnet-prefix 10.10.1.0/24 | Out-Null
    Write-Ok "VNet $VNetName 作成"
}

foreach ($s in @(
    @{ Name = "snet-pe";            Prefix = "10.10.1.0/24" },
    @{ Name = "snet-vm";            Prefix = "10.10.2.0/24" },
    @{ Name = "AzureBastionSubnet"; Prefix = "10.10.250.0/26" }
)) {
    $exists = az network vnet subnet show -g $ResourceGroup --vnet-name $VNetName -n $s.Name --query id -o tsv 2>$null
    if ($exists) { Write-Skip "Subnet $($s.Name) は存在" }
    else {
        az network vnet subnet create -g $ResourceGroup --vnet-name $VNetName `
            -n $s.Name --address-prefix $s.Prefix | Out-Null
        Write-Ok "Subnet $($s.Name) 作成"
    }
}

# PE サブネットで private endpoint network policies を無効化（必要な場合）
az network vnet subnet update -g $ResourceGroup --vnet-name $VNetName -n snet-pe `
    --private-endpoint-network-policies Disabled | Out-Null

# =============================================================================
Write-Phase "Phase 3: Fabric ワークスペース作成 & キャパシティ割当"
# =============================================================================
$tok = Get-FabricToken
$h = @{ Authorization = "Bearer $tok"; "Content-Type" = "application/json" }

$wsList = (Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $h).value
$ws = $wsList | Where-Object { $_.displayName -eq $WorkspaceName }
if ($ws) {
    Write-Skip "Workspace $WorkspaceName は存在 (id=$($ws.id))"
} else {
    $body = @{ displayName = $WorkspaceName; description = "Private link demo workspace"; capacityId = $CapacityId } | ConvertTo-Json
    $ws = Invoke-RestMethod -Method Post -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $h -Body $body
    Write-Ok "Workspace $WorkspaceName 作成 (id=$($ws.id))"
}
$WorkspaceId   = $ws.id
$WorkspaceIdNoDash = $WorkspaceId.Replace("-","")
$WorkspacePrefix = $WorkspaceIdNoDash.Substring(0,2)

# キャパシティ割当を保証
try {
    $assignBody = @{ capacityId = $CapacityId } | ConvertTo-Json
    Invoke-RestMethod -Method Post -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/assignToCapacity" -Headers $h -Body $assignBody | Out-Null
    Write-Ok "Capacity 割当 OK"
} catch {
    Write-Skip "Capacity 割当スキップ (既に同じ容量に割当済みの可能性): $($_.Exception.Message)"
}

$state | Add-Member -NotePropertyName workspaceId -NotePropertyValue $WorkspaceId -Force
$state | Add-Member -NotePropertyName workspaceIdNoDash -NotePropertyValue $WorkspaceIdNoDash -Force
$state | Add-Member -NotePropertyName workspacePrefix -NotePropertyValue $WorkspacePrefix -Force
Save-State $state

# =============================================================================
Write-Phase "Phase 4: Fabric Private Link Service (PLS) リソース作成"
# =============================================================================
$tenantId = az account show --query tenantId -o tsv
$plsId = az resource show -g $ResourceGroup -n $PLSName `
    --resource-type "Microsoft.Fabric/privateLinkServicesForFabric" --query id -o tsv 2>$null
if ($plsId) {
    Write-Skip "PLS $PLSName 既存"
} else {
    # ARM テンプレートをファイルに書き出してデプロイ（PowerShell→az の JSON 引用エスケープ回避）
    $armTemplate = [PSCustomObject]@{
        '$schema'      = 'http://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{}
        resources      = @(
            [PSCustomObject]@{
                type       = 'Microsoft.Fabric/privateLinkServicesForFabric'
                apiVersion = '2024-06-01'
                name       = $PLSName
                location   = 'global'
                properties = @{ tenantId = $tenantId; workspaceId = $WorkspaceId }
            }
        )
    }
    $tmplPath = Join-Path $PSScriptRoot "pls.template.json"
    $armTemplate | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $tmplPath
    Write-Step "PLS をARMテンプレートでデプロイ中..."
    az deployment group create -g $ResourceGroup --template-file $tmplPath --name "deploy-pls-$(Get-Date -Format yyyyMMddHHmmss)" | Out-Null
    Start-Sleep -Seconds 5
    $plsId = az resource show -g $ResourceGroup -n $PLSName `
        --resource-type "Microsoft.Fabric/privateLinkServicesForFabric" --query id -o tsv
    if (-not $plsId) { throw "PLS の作成に失敗" }
    Write-Ok "PLS $PLSName 作成"
}
$state | Add-Member -NotePropertyName plsResourceId -NotePropertyValue $plsId -Force
Save-State $state

# =============================================================================
Write-Phase "Phase 5: プライベート DNS ゾーン (Fabric) 作成 & VNet リンク"
# =============================================================================
$zoneExists = az network private-dns zone show -g $ResourceGroup -n $DnsZoneFabric --query id -o tsv 2>$null
if ($zoneExists) { Write-Skip "DNS zone $DnsZoneFabric 既存" }
else {
    az network private-dns zone create -g $ResourceGroup -n $DnsZoneFabric | Out-Null
    Write-Ok "DNS zone $DnsZoneFabric 作成"
}
$linkExists = az network private-dns link vnet show -g $ResourceGroup -z $DnsZoneFabric -n "$VNetName-link" --query id -o tsv 2>$null
if ($linkExists) { Write-Skip "VNet link 既存" }
else {
    az network private-dns link vnet create -g $ResourceGroup -z $DnsZoneFabric -n "$VNetName-link" `
        --virtual-network $VNetName --registration-enabled false | Out-Null
    Write-Ok "VNet link 作成"
}

# =============================================================================
Write-Phase "Phase 6: ワークスペースレベル PE 作成 + DNS 統合"
# =============================================================================
$peExists = az network private-endpoint show -g $ResourceGroup -n $PEName --query id -o tsv 2>$null
if ($peExists) { Write-Skip "PE $PEName 既存" }
else {
    az network private-endpoint create -g $ResourceGroup -n $PEName `
        --vnet-name $VNetName --subnet snet-pe `
        --private-connection-resource-id $plsId `
        --group-id workspace `
        --connection-name "$PEName-conn" `
        --location $Location | Out-Null
    Write-Ok "PE $PEName 作成"
}
$pdnszgExists = az network private-endpoint dns-zone-group list -g $ResourceGroup --endpoint-name $PEName --query "[0].id" -o tsv 2>$null
if (-not $pdnszgExists) {
    az network private-endpoint dns-zone-group create -g $ResourceGroup --endpoint-name $PEName `
        --name fabric-zone-group --private-dns-zone $DnsZoneFabric --zone-name fabric | Out-Null
    Write-Ok "PE DNS zone group 作成"
} else { Write-Skip "PE DNS zone group 既存" }

# =============================================================================
Write-Phase "Phase 7: Azure Bastion 作成"
# =============================================================================
if ($SkipBastion) { Write-Skip "Bastion をスキップ (-SkipBastion)" }
else {
    $bExists = az network bastion show -g $ResourceGroup -n $BastionName --query id -o tsv 2>$null
    if ($bExists) { Write-Skip "Bastion 既存" }
    else {
        $pipExists = az network public-ip show -g $ResourceGroup -n $BastionPipName --query id -o tsv 2>$null
        if (-not $pipExists) {
            az network public-ip create -g $ResourceGroup -n $BastionPipName --sku Standard --allocation-method Static | Out-Null
            Write-Ok "Bastion PIP 作成"
        }
        Write-Step "Bastion デプロイ中... (5〜10 分)"
        az network bastion create -g $ResourceGroup -n $BastionName `
            --public-ip-address $BastionPipName --vnet-name $VNetName --location $Location --sku Basic | Out-Null
        Write-Ok "Bastion 作成"
    }
}

# =============================================================================
Write-Phase "Phase 8: Windows VM 作成 (パブリック IP なし)"
# =============================================================================
if ($SkipVM) { Write-Skip "VM をスキップ (-SkipVM)" }
else {
    $vmExists = az vm show -g $ResourceGroup -n $VMName --query id -o tsv 2>$null
    if ($vmExists) { Write-Skip "VM $VMName 既存" }
    else {
        $vmPw = New-StrongPassword -Length 20
        $state | Add-Member -NotePropertyName vmAdminUser -NotePropertyValue $VMAdminUser -Force
        $state | Add-Member -NotePropertyName vmAdminPassword -NotePropertyValue $vmPw -Force
        Save-State $state
        Write-Step "VM 作成中..."
        az vm create -g $ResourceGroup -n $VMName `
            --image "MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest" `
            --size Standard_D2s_v5 `
            --vnet-name $VNetName --subnet snet-vm `
            --public-ip-address '""' `
            --nsg-rule NONE `
            --admin-username $VMAdminUser --admin-password $vmPw | Out-Null
        Write-Ok "VM $VMName 作成 (パスワードは $StateFile に保存)"
    }
}

# =============================================================================
Write-Phase "Phase 9: Azure Cosmos DB (Core/SQL API) アカウント / DB / コンテナー作成"
# =============================================================================
if ($SkipCosmos) { Write-Skip "Cosmos DB をスキップ (-SkipCosmos)" }
else {
    # Microsoft.DocumentDB プロバイダー登録
    $cdbState = az provider show -n Microsoft.DocumentDB --query registrationState -o tsv 2>$null
    if ($cdbState -ne "Registered") {
        az provider register --namespace Microsoft.DocumentDB --wait | Out-Null
        Write-Ok "Microsoft.DocumentDB 登録"
    }

    $cosmosExists = az cosmosdb show -g $ResourceGroup -n $CosmosAccountName --query id -o tsv 2>$null
    if ($cosmosExists) {
        Write-Skip "Cosmos $CosmosAccountName 既存"
    } else {
        # 闉域デモ用に public を一時的に有効化してサンプルを投入 → 後で無効化
        az cosmosdb create -g $ResourceGroup -n $CosmosAccountName `
            --kind GlobalDocumentDB `
            --locations regionName=$Location failoverPriority=0 isZoneRedundant=False `
            --default-consistency-level Session `
            --public-network-access ENABLED | Out-Null
        Write-Ok "Cosmos $CosmosAccountName 作成 (一時的に public 有効)"
    }
    $cosmosId = az cosmosdb show -g $ResourceGroup -n $CosmosAccountName --query id -o tsv
    $cosmosEndpoint = az cosmosdb show -g $ResourceGroup -n $CosmosAccountName --query documentEndpoint -o tsv
    $state | Add-Member -NotePropertyName cosmosAccountName -NotePropertyValue $CosmosAccountName -Force
    $state | Add-Member -NotePropertyName cosmosAccountId -NotePropertyValue $cosmosId -Force
    $state | Add-Member -NotePropertyName cosmosEndpoint -NotePropertyValue $cosmosEndpoint -Force
    Save-State $state

    $dbExists = az cosmosdb sql database show -g $ResourceGroup -a $CosmosAccountName -n $CosmosDbName --query id -o tsv 2>$null
    if ($dbExists) { Write-Skip "Cosmos DB $CosmosDbName 既存" }
    else {
        az cosmosdb sql database create -g $ResourceGroup -a $CosmosAccountName -n $CosmosDbName | Out-Null
        Write-Ok "Cosmos DB $CosmosDbName 作成"
    }
    $contExists = az cosmosdb sql container show -g $ResourceGroup -a $CosmosAccountName -d $CosmosDbName -n $CosmosContainerName --query id -o tsv 2>$null
    if ($contExists) { Write-Skip "Container $CosmosContainerName 既存" }
    else {
        az cosmosdb sql container create -g $ResourceGroup -a $CosmosAccountName `
            -d $CosmosDbName -n $CosmosContainerName `
            --partition-key-path "/region" --throughput 400 | Out-Null
        Write-Ok "Container $CosmosContainerName 作成 (パーティションキー=/region)"
    }

    # サンプルドキュメント投入 (マスターキー認証で REST API)
    Write-Step "サンプルドキュメント 5 件を投入..."
    try {
        $key = az cosmosdb keys list -g $ResourceGroup -n $CosmosAccountName --query primaryMasterKey -o tsv
        $samples = @(
            @{ id="1"; productName="SSD 1TB";  region="Japan"; quantity=10; unitPrice=12000 },
            @{ id="2"; productName="SSD 2TB";  region="Japan"; quantity=5;  unitPrice=22000 },
            @{ id="3"; productName="HDD 4TB";  region="US";    quantity=20; unitPrice=9800  },
            @{ id="4"; productName="NVMe 1TB"; region="EU";    quantity=8;  unitPrice=18000 },
            @{ id="5"; productName="NVMe 2TB"; region="Japan"; quantity=3;  unitPrice=32000 }
        )
        function New-CosmosAuthHeader {
            param([string]$Verb,[string]$ResType,[string]$ResLink,[string]$DateUtc,[string]$Key)
            $payload = ("$($Verb.ToLower())`n$($ResType.ToLower())`n$ResLink`n$($DateUtc.ToLower())`n`n")
            $hmac = New-Object System.Security.Cryptography.HMACSHA256
            $hmac.Key = [Convert]::FromBase64String($Key)
            $sig = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))
            return [System.Web.HttpUtility]::UrlEncode("type=master&ver=1.0&sig=$sig")
        }
        Add-Type -AssemblyName System.Web
        $resLink = "dbs/$CosmosDbName/colls/$CosmosContainerName"
        foreach ($doc in $samples) {
            $now = [DateTime]::UtcNow.ToString("r")
            $auth = New-CosmosAuthHeader -Verb POST -ResType docs -ResLink $resLink -DateUtc $now -Key $key
            $headers = @{
                Authorization = $auth
                "x-ms-version" = "2018-12-31"
                "x-ms-date"    = $now
                "x-ms-documentdb-partitionkey" = "[`"$($doc.region)`"]"
            }
            $body = $doc | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Method Post -Uri "$cosmosEndpoint$resLink/docs" `
                    -Headers $headers -Body $body -ContentType "application/json" | Out-Null
            } catch {
                if ($_.Exception.Response.StatusCode.value__ -ne 409) { throw }
            }
        }
        Write-Ok "サンプル 5 件投入完了"
    } catch {
        Write-Host "  [WARN] サンプルドキュメント投入失敗: $($_.Exception.Message)" -ForegroundColor Magenta
        Write-Host "         手動で Data Explorer / SDK から投入してください。" -ForegroundColor Magenta
    }

    # public access 無効化
    az cosmosdb update -g $ResourceGroup -n $CosmosAccountName --public-network-access DISABLED | Out-Null
    Write-Ok "Cosmos public access を無効化"
}

# =============================================================================
Write-Phase "Phase 10: Key Vault 作成 + シークレット登録"
# =============================================================================
if ($SkipMpe) { Write-Skip "Key Vault/MPE をスキップ (-SkipMpe)" }
else {
    $kvExists = az keyvault show -n $KeyVaultName -g $ResourceGroup --query id -o tsv 2>$null
    if ($kvExists) { Write-Skip "Key Vault $KeyVaultName 既存" }
    else {
        az keyvault create -g $ResourceGroup -n $KeyVaultName -l $Location `
            --enable-rbac-authorization true `
            --public-network-access Enabled | Out-Null  # 後で MPE 用に Enabled のままでも可
        Write-Ok "Key Vault $KeyVaultName 作成"
    }
    $state | Add-Member -NotePropertyName keyVaultName -NotePropertyValue $KeyVaultName -Force

    # 自分に Key Vault Administrator 権限を付与（シークレット書込用）
    $myObjectId = az ad signed-in-user show --query id -o tsv
    $kvId = az keyvault show -n $KeyVaultName --query id -o tsv
    az role assignment create --assignee-object-id $myObjectId --assignee-principal-type User `
        --role "Key Vault Administrator" --scope $kvId 2>$null | Out-Null
    Start-Sleep -Seconds 15  # RBAC 反映待ち

    if ($state.cosmosAccountName) {
        try {
            $key = az cosmosdb keys list -g $ResourceGroup -n $state.cosmosAccountName --query primaryMasterKey -o tsv
            az keyvault secret set --vault-name $KeyVaultName --name "cosmos-primary-key" --value $key | Out-Null
            Write-Ok "シークレット cosmos-primary-key 登録"
            if ($state.cosmosEndpoint) {
                az keyvault secret set --vault-name $KeyVaultName --name "cosmos-endpoint" --value $state.cosmosEndpoint | Out-Null
                Write-Ok "シークレット cosmos-endpoint 登録"
            }
        } catch {
            Write-Host "  [WARN] シークレット登録失敗（RBAC 反映待ちかも）: $($_.Exception.Message)" -ForegroundColor Magenta
        }
    }
    Save-State $state
}

# =============================================================================
Write-Phase "Phase 11: Fabric Managed Private Endpoint 作成 (Cosmos DB & Key Vault)"
# =============================================================================
if ($SkipMpe) { Write-Skip "MPE スキップ" }
else {
    function Create-Mpe {
        param([string]$Name,[string]$ResourceId,[string]$SubResourceType,[string]$RequestMessage)
        $tok2 = Get-FabricToken
        $h2 = @{ Authorization = "Bearer $tok2"; "Content-Type" = "application/json" }
        $listUri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/managedPrivateEndpoints"
        try {
            $existing = (Invoke-RestMethod -Uri $listUri -Headers $h2).value | Where-Object { $_.name -eq $Name }
        } catch { $existing = $null }
        if ($existing) { Write-Skip "MPE $Name は存在"; return $existing.id }
        $body = @{
            name                          = $Name
            targetPrivateLinkResourceId   = $ResourceId
            targetSubresourceType         = $SubResourceType
            requestMessage                = $RequestMessage
        } | ConvertTo-Json
        $created = Invoke-RestMethod -Method Post -Uri $listUri -Headers $h2 -Body $body
        Write-Ok "MPE $Name 作成 (group=$SubResourceType)"
        return $created.id
    }
    if ($state.cosmosAccountId) { Create-Mpe -Name $MpeCosmosName -ResourceId $state.cosmosAccountId -SubResourceType "Sql" -RequestMessage "Fabric ws-private-demo PoC (Cosmos)" | Out-Null }
    $kvIdForMpe = az keyvault show -n $state.keyVaultName --query id -o tsv 2>$null
    if ($kvIdForMpe) { Create-Mpe -Name $MpeKvName -ResourceId $kvIdForMpe -SubResourceType "vault" -RequestMessage "Fabric ws-private-demo PoC (KV)" | Out-Null }

    Write-Step "MPE プロビジョニング待機 (最大 5 分)..."
    Start-Sleep -Seconds 60

    # Cosmos 側で承認
    if ($state.cosmosAccountId) {
        $pendingCosmos = az network private-endpoint-connection list --id $state.cosmosAccountId 2>$null | ConvertFrom-Json
        foreach ($pe in ($pendingCosmos | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq "Pending" })) {
            az network private-endpoint-connection approve --id $pe.id --description "auto-approved by deploy script" | Out-Null
            Write-Ok "Cosmos PE 承認: $($pe.name)"
        }
    }
    # Key Vault 側で承認
    if ($kvIdForMpe) {
        $pendingKv = az network private-endpoint-connection list --id $kvIdForMpe 2>$null | ConvertFrom-Json
        foreach ($pe in ($pendingKv | Where-Object { $_.properties.privateLinkServiceConnectionState.status -eq "Pending" })) {
            az network private-endpoint-connection approve --id $pe.id --description "auto-approved by deploy script" | Out-Null
            Write-Ok "Key Vault PE 承認: $($pe.name)"
        }
    }
}

Save-State $state

Write-Host "`n#############################################################"
Write-Host "# 自動構築 完了" -ForegroundColor Green
Write-Host "#############################################################"
Write-Host "Workspace ID         : $WorkspaceId"
Write-Host "Workspace ID (no -)  : $WorkspaceIdNoDash"
Write-Host "Workspace Prefix(xy) : $WorkspacePrefix"
Write-Host "FQDN(api)            : $WorkspaceIdNoDash.z$WorkspacePrefix.w.api.fabric.microsoft.com"
Write-Host ""
Write-Host "次に手動で実施してください："
Write-Host "  1. Fabric 管理ポータル → テナント設定で 'Configure workspace-level inbound network rules' を有効化"
Write-Host "  2. Fabric ワークスペース → ワークスペース設定 → Inbound networking で"
Write-Host "     'Allow connections from selected networks and workspace level private links' を選択"
Write-Host "  3. VM (Bastion 経由) で nslookup を実行してプライベート IP が返ることを確認"
Write-Host "  4. Notebook を作成し、Phase D のサンプルコードを実行"
Write-Host ""
Write-Host "認証情報・リソース ID は $StateFile に保存されています。"
