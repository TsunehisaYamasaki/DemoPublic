# Fabric 閉域環境 Pipeline デモ

Microsoft Fabric の閉域ネットワーク環境で、**Azure SQL Database → Lakehouse** のデータパイプラインを構築するデモプロジェクトです。

## 構成概要

- **Fabric Workspace** を Communication Policy (Inbound/Outbound = Deny) で完全閉域化
- **On-premises Data Gateway (OPDG)** が VNet 内 VM 上で動作し、Private Endpoint 経由で SQL / Key Vault にアクセス
- SQL パスワードは **Azure Key Vault Reference** で動的解決（ハードコードなし）
- Key Vault は `Public network access = Disabled` / `Default action = Deny` / `Bypass = None` の完全閉域設定

```text
Fabric (閉域 WS) ── OPDG (VM) ──┬── Key Vault PE ── シークレット取得
                                 └── SQL PE ──────── データ取得
                                                         ↓
                                                     Lakehouse
```

## 前提条件

- Azure サブスクリプション (Contributor 以上)
- Microsoft Fabric テナント (管理者権限)
- Fabric Capacity (F2 以上)
- Azure CLI (`az`)

## クイックスタート

```powershell
# 1. Azure インフラ構築
cd scripts
.\deploy_fabric_private_env.ps1 -Location "westus3" -ResourceGroup "rg-fabric-pl-demo"

# 2. Azure SQL + Private Endpoint 構築
.\setup_azure_sql_pe.ps1 -ResourceGroup "rg-fabric-pl-demo" -Location "westus3" `
    -VNetName "vnet-fabric-pl" -SubnetPe "snet-pe" -VmName "vm-jump-01" -KvName "<KV名>"

# 3. OPDG インストール (VM 上)
# → scripts/install_opdg_on_vm.ps1 を az vm run-command で実行

# 4. Fabric ポータルで接続作成・Workspace 閉域化 (手動)

# 5. Pipeline 作成・実行
.\create_sql_pipeline.ps1 -SqlConnId "<接続ID>"
```

詳細な手順は [docs/implementation-guide.md](docs/implementation-guide.md) を参照してください。

## プロジェクト構成

```
├── docs/
│   └── implementation-guide.md          # メインの実装手順ガイド
├── scripts/
│   ├── deploy_fabric_private_env.ps1    # Azure インフラ自動構築
│   ├── setup_azure_sql_pe.ps1           # SQL + PE + DNS + KV secrets
│   ├── install_opdg_on_vm.ps1           # OPDG サイレントインストール
│   └── create_sql_pipeline.ps1          # Pipeline デプロイ・実行
├── templates/
│   ├── pipeline_sql_kv_def.json         # Pipeline 定義テンプレート
│   └── pls.template.json               # Fabric Private Link Service ARM テンプレート
└── README.md
```


## ライセンス

MIT
