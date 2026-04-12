# Fabric Graph Quickstart　<img width="37" height="40" alt="image" src="https://github.com/user-attachments/assets/892e2464-8fa1-4bd5-a8a8-172c9ef3540e" />

Microsoft Fabric の Graph model (preview) を使用して、AdventureWorks サンプルデータからグラフを作成し、GQL クエリを実行するプロジェクトです。 UI を使わずプロジェクトをデプロイしています。

> 参考: [Quickstart: Create your first graph in Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/graph/quickstart)

## 前提条件

- Azure CLI (`az`) がインストール済みであること
- Microsoft Fabric 容量（F2 以上）へのアクセス
- Python 3.12 以上（`requests`, `pandas`, `pyarrow` が必要）
- Fabric テナント管理ポータルで Graph が有効化されていること

## ファイル構成

```
FabricGraph/
├── sample_data/
│   └── adventureworks/          # AdventureWorks サンプル Parquet データ
│       ├── adventureworks_customers/
│       ├── adventureworks_orders/
│       └── ...（その他テーブル）
├── upload_data.ps1              # OneLake へ Parquet をアップロード
├── load_lakehouse_tables.ipynb  # Load Table API でテーブル作成（ノートブック）
├── run_gql.py                   # GQL クエリ実行スクリプト
└── README.md
```

## 環境変数の設定

スクリプト実行前に以下の環境変数を設定してください。

```powershell
# Fabric API トークン
$env:FABRIC_TOKEN = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)

# リソース ID（自分の環境に合わせて設定）
$env:FABRIC_WORKSPACE_ID = "<your-workspace-id>"
$env:FABRIC_LAKEHOUSE_ID = "<your-lakehouse-id>"
$env:FABRIC_GRAPHMODEL_ID = "<your-graphmodel-id>"
```

## 手順

### 1. Azure にサインイン

```powershell
az login --use-device-code
```

### 2. Fabric ワークスペースと Lakehouse を作成

Fabric ポータル、または REST API でワークスペースと Lakehouse を作成します。

```powershell
$token = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

# ワークスペース作成
$wsBody = @{ displayName = "GraphQuickstartWS"; capacityId = "<your-capacity-id>" } | ConvertTo-Json
$ws = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces" -Headers $headers -Method Post -Body $wsBody
$wsId = $ws.id

# Lakehouse 作成
$lhBody = @{ displayName = "AdventureWorksLakehouse"; type = "Lakehouse" } | ConvertTo-Json
$lh = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/items" -Headers $headers -Method Post -Body $lhBody
$lhId = $lh.id
```

### 3. サンプルデータを OneLake にアップロード

`upload_data.ps1` 内の `$wsId` と `$lhId` を自分の環境の値に書き換えてから実行します。

```powershell
powershell -ExecutionPolicy Bypass -File upload_data.ps1
```

`adventureworks_customers` と `adventureworks_orders` の Parquet ファイルが Lakehouse の Files にアップロードされます。

### 4. テーブルとしてロード

Fabric REST API の Load Table API で Parquet を Delta テーブルに変換します。

```powershell
$token = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
$wsId = $env:FABRIC_WORKSPACE_ID
$lhId = $env:FABRIC_LAKEHOUSE_ID
$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }

foreach ($table in @("adventureworks_customers", "adventureworks_orders")) {
    $body = @{ relativePath = "Files/$table"; pathType = "Folder"; mode = "Overwrite"; formatOptions = @{ format = "Parquet" } } | ConvertTo-Json
    Invoke-WebRequest -Uri "https://api.fabric.microsoft.com/v1/workspaces/$wsId/lakehouses/$lhId/tables/$table/load" -Headers $headers -Method Post -Body $body
}
```

### 5. Graph Model の作成と定義

Fabric REST API で Graph Model を作成し、ノード・エッジを定義します。

- **ノード**:
  - `Customer` — マッピングテーブル: `adventureworks_customers`, ID: `CustomerID_K`
  - `Order` — マッピングテーブル: `adventureworks_orders`, ID: `SalesOrderDetailID_K`
- **エッジ**:
  - `purchases` — マッピングテーブル: `adventureworks_orders`, Source: `Customer` (`CustomerID_FK`) → Target: `Order` (`SalesOrderDetailID_K`)

定義後、Fabric ポータルで Graph Model を開き「保存」をクリックしてデータロードを実行します。

### 6. GQL クエリの実行

```powershell
$env:FABRIC_TOKEN = (az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv)
$env:FABRIC_WORKSPACE_ID = "<your-workspace-id>"
$env:FABRIC_GRAPHMODEL_ID = "<your-graphmodel-id>"
python run_gql.py
```

注文数上位5顧客を取得する GQL クエリが実行されます。

```gql
MATCH (c:Customer)-[:purchases]->(o:`Order`)
RETURN c.FullName AS customer_name, count(o) AS num_orders
GROUP BY customer_name
ORDER BY num_orders DESC
LIMIT 5
```

### クエリ結果例

| customer_name | num_orders |
|---|---|
| Reuben D'sa | 530 |
| Richard Lum | 482 |
| Ryan Calafato | 451 |
| Yale Li | 446 |
| Marcia Sultan | 441 |

## 注意事項

- `Order` は GQL の予約語のため、バッククォート `` `Order` `` でエスケープが必要です
- Graph Model のデータロード（Save）は 2026年4月時点で REST API 非対応のため、Fabric ポータルの UI から実行する必要があります
- Execute Query API は Preview 段階のため `?preview=true` パラメータが必要です

## 参考リンク

- [Quickstart: Create your first graph in Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/graph/quickstart)
- [Graph Model REST API](https://learn.microsoft.com/en-us/rest/api/fabric/graphmodel/items)
- [Lakehouse Load Table API](https://learn.microsoft.com/en-us/rest/api/fabric/lakehouse/tables/load-table)
- [GQL Language Guide](https://learn.microsoft.com/en-us/fabric/graph/gql-language-guide)
