# =============================================================================
# install_opdg_on_vm.ps1
#  vm-jump-01 (Customer VNet 内) で実行する On-premises Data Gateway
#  サイレントインストール + テナント登録スクリプト
# =============================================================================
#  使い方:
#   az vm run-command invoke -g rg-fabric-pl-demo -n vm-jump-01 `
#       --command-id RunPowerShellScript `
#       --scripts "@install_opdg_on_vm.ps1" `
#       --parameters spAppId=<appId> spSecret=<secret> spTenant=<tenantId> recoveryKey=<32+ chars>
# =============================================================================
param(
    [Parameter(Mandatory=$true)] [string]$spAppId,
    [Parameter(Mandatory=$true)] [string]$spSecret,
    [Parameter(Mandatory=$true)] [string]$spTenant,
    [Parameter(Mandatory=$true)] [string]$recoveryKey,
    [string]$gatewayName = "opdg-fabric-private",
    [string]$region      = "Japan East"
)

$ErrorActionPreference = "Stop"
Write-Host "==> Step 1: Install DataGateway PowerShell module"
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name DataGateway -Force -AllowClobber -Scope AllUsers

Write-Host "==> Step 2: Install On-premises Data Gateway (silent)"
Install-DataGateway -AcceptConditions

Write-Host "==> Step 3: Login (Service Principal)"
$sec = ConvertTo-SecureString $spSecret -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($spAppId, $sec)
Login-DataGatewayServiceAccount -ApplicationId $spAppId `
    -ClientSecret $sec -Tenant $spTenant

Write-Host "==> Step 4: Create / Add gateway cluster"
$rk = ConvertTo-SecureString $recoveryKey -AsPlainText -Force
Add-DataGatewayCluster -RecoveryKey $rk -Name $gatewayName -RegionKey $region

Write-Host "==> Step 5: Show registered cluster"
Get-DataGatewayCluster | Format-List
