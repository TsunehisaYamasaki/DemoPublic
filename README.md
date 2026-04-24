# DemoPublic

私が手元で検証した内容を紹介いたします。

## プロジェクト一覧

| プロジェクト | 概要 | 主要技術 |
|-------------|------|---------|
| [CosmosDBNoSQLAIAgentPublic](./CosmosDBNoSQLAIAgentPublic/) | Cosmos DB + AI Search による半導体 KPI データ分析 AI エージェント | .NET 8.0, Bicep, C# |
| [SemiDocAI4SPS](./SemiDocAI4SPS/) | SharePoint Online ドキュメントの自動テキスト化 + RAG 質問応答システム | Python, Azure Functions |
| [FabricGraph](./FabricGraph/) | Microsoft Fabric Graph model で AdventureWorks データのグラフ分析 | Python, PowerShell, GQL |
| [Private ConToFabricWorkspace](./Private%20ConToFabricWorkspace/) | Fabric 閉域ネットワーク環境で OPDG 経由の SQL → Lakehouse パイプライン構築 | PowerShell, ARM, Fabric REST API |

---

## CosmosDBNoSQLAIAgentPublic

Azure Cosmos DB for NoSQL と Azure OpenAI を統合した **半導体設計・製造データ分析システム** です。RAG (Retrieval-Augmented Generation) パターンを 2 つのアプローチで実装しています。

### アーキテクチャ
<img width="489" height="132" alt="image" src="https://github.com/user-attachments/assets/cd8ccf7e-3c25-4692-8cf9-e6eea9c7b83a" />

```mermaid
flowchart TD
    A["Cosmos DB for NoSQL<br/>(設計 1,000 件 + 製造 1,000 件)"] --> B["Azure AI Search Indexers<br/>(自動インデックス化)"]
    B --> C["Azure AI Search Indexes<br/>(designs / manufacturing)"]
    C --> D["RAG Agent<br/>(検索 + コンテキスト構築)"]
    D --> E["Azure OpenAI GPT-4o<br/>(回答生成)"]
```

### 2 つの AI エージェントパターン

| パターン | フォルダ | 特徴 |
|---------|---------|------|
| **直接クエリ型** | `src/ai-agent-sql/` | GPT-4o が自然言語から Cosmos DB SQL クエリを自動生成。低レイテンシー、構造化データに最適 |
| **RAG 型** | `AISearchEvaluationAgent/` | Azure AI Search でセマンティック検索。大規模データ・柔軟な検索に対応 |

### 主要コンポーネント

- **Azure Cosmos DB for NoSQL** — 設計部門・製造部門の KPI データ (各 20 列 × 1,000 件)
- **Azure AI Search** — Cosmos DB データのインデックス化・セマンティック検索
- **Azure OpenAI (GPT-4o)** — 大量コンテキストでの自然言語分析
- **Infrastructure as Code** — Bicep による完全自動デプロイ
- **セキュア認証** — Azure AD + RBAC + Managed Identity

👉 詳細は [CosmosDBNoSQLAIAgentPublic/README.md](./CosmosDBNoSQLAIAgentPublic/README.md) を参照

---

## SemiDocAI4SPS

SharePoint Online にアップロードされた半導体関連ドキュメントを **Azure AI Document Intelligence** で自動テキスト化し、**Azure AI Search + Azure OpenAI GPT-4o** による RAG パターンで自然言語の質問応答を実現するサーバーレスシステムです。

### アーキテクチャ
<img width="1169" height="194" alt="image" src="https://github.com/user-attachments/assets/0f99ef4c-49b7-4408-8652-ee46881b59da" />


```mermaid
flowchart TD
    A["SharePoint Online<br/>(folder1)"] -->|"Microsoft Graph API<br/>(5 分間隔ポーリング)"| B["Azure Functions<br/>(Python, Timer Trigger)"]
    B -->|"Document Intelligence API"| C["Azure AI Document Intelligence<br/>(prebuilt-layout)"]
    C -->|"テキスト・テーブル・<br/>キーバリュー抽出"| D["Azure Cosmos DB<br/>(JSON 保存)"]
    D -->|"自動インデックス化"| E["Azure AI Search<br/>(全文検索 + ベクトル検索)"]
    E -->|"検索 + コンテキスト構築"| F["RAG Agent"]
    F --> G["Azure OpenAI GPT-4o<br/>(回答生成)"]
```

### 対応ファイル形式

PDF / Word (.docx) / Excel (.xlsx) / PowerPoint (.pptx) / 画像 (PNG, JPG, BMP, TIFF)

### 主要コンポーネント

- **Azure Functions (Python)** — SharePoint 監視 + Document Intelligence 連携のサーバーレス処理
- **Azure AI Document Intelligence** — OCR・テーブル・キーバリュー抽出
- **Azure Cosmos DB** — OCR 結果と処理済みファイル追跡の NoSQL ストレージ
- **Azure AI Search** — ベクトル検索 (HNSW + text-embedding-ada-002) + セマンティック構成
- **Azure OpenAI (GPT-4o)** — RAG による質問応答
- **Copilot Studio 連携** — AI Search インデックスをナレッジソースとして直接接続可能

### 認証方式

| 対象 | 認証方式 |
|------|---------|
| SharePoint Online (Graph API) | Azure AD App Registration (Client Credentials) |
| Document Intelligence / Cosmos DB / OpenAI | Managed Identity (DefaultAzureCredential) |
| AI Search → Cosmos DB | Managed Identity (System Assigned) |

👉 詳細は [SemiDocAI4SPS/README.md](./SemiDocAI4SPS/README.md) を参照

---

## Fabric Graph　<img width="37" height="40" alt="image" src="https://github.com/user-attachments/assets/892e2464-8fa1-4bd5-a8a8-172c9ef3540e" />

Microsoft Fabric の **Graph model (preview)** を使用して、AdventureWorks サンプルデータからグラフを作成し、**GQL (Graph Query Language)** クエリを REST API 経由で実行するプロジェクトです。UI を使わずプロジェクトをデプロイしています。

### アーキテクチャ

```mermaid
flowchart TD
    A["AdventureWorks<br/>Parquet データ"] -->|"OneLake ADLS Gen2 API<br/>(アップロード)"| B["Fabric Lakehouse<br/>(Delta テーブル)"]
    B -->|"Load Table API"| C["Graph Model<br/>(Customer / Order ノード<br/>+ purchases エッジ)"]
    C -->|"Execute Query API (GQL)"| D["クエリ結果<br/>(注文数上位顧客)"]
```

### 主要コンポーネント

- **Microsoft Fabric Graph model** — Lakehouse テーブルからグラフ構造を定義
- **OneLake** — ADLS Gen2 互換のデータレイク
- **Fabric REST API** — ワークスペース・Lakehouse・Graph Model のプログラマティック操作
- **GQL** — ISO 標準ベースの Graph Query Language

👉 詳細は [FabricGraph/README.md](./FabricGraph/README.md) を参照

---

## Private ConToFabricWorkspace

Microsoft Fabric の **Workspace-level Private Link** と **Communication Policy (Inbound/Outbound = Deny)** を使用して完全閉域化されたワークスペースで、**On-premises Data Gateway (OPDG)** 経由で Azure SQL Database → Lakehouse へデータをコピーするパイプラインを構築するデモです。

### アーキテクチャ

```mermaid
flowchart TD
    subgraph Fabric[Fabric Service]
        WS["Workspace\n🔒 Communication Policy\nInbound: Deny / Outbound: Deny"]
        P[Data Pipeline]
        L[Lakehouse]
    end
    subgraph Azure[Azure Subscription]
        subgraph VNet[VNet]
            VM["VM + OPDG"]
            PE_WS[Workspace PE]
            PE_KV[Key Vault PE]
            PE_SQL[SQL PE]
        end
        KV["Key Vault\n(PNA=Disabled)"]
        SQL[Azure SQL Server]
    end
    VM -->|Private Link| PE_WS --> WS
    P -->|OPDG 経由| VM
    VM --> PE_KV -->|Private Link| KV
    VM --> PE_SQL -->|Private Link| SQL
    P -->|write| L
```

### 構成のポイント

- **完全閉域化** — Workspace Communication Policy で Public Internet アクセスを完全遮断
- **AKV Reference** — SQL パスワードを Key Vault から動的解決 (OPDG 経由で PE アクセス)
- **Private Endpoint** — SQL / Key Vault / Workspace すべて PE 経由の通信
- **自動構築スクリプト** — VNet / PE / DNS / VM / Bastion / SQL / Key Vault を PowerShell で冪等に自動構築

### 主要コンポーネント

- **Fabric Workspace-level Private Link** — ワークスペース単位の閉域接続
- **On-premises Data Gateway (OPDG)** — VNet 内 VM 上で Private Endpoint 経由アクセスを仲介
- **Azure Key Vault** — SQL 認証情報の安全な格納 (完全閉域設定で運用)
- **Azure SQL Database** — データソース (Private Endpoint 経由のみアクセス可)
- **Azure Bastion** — VM への安全なリモート接続

👉 詳細は [Private ConToFabricWorkspace/README.md](./Private%20ConToFabricWorkspace/README.md) を参照

---

## 共通の技術スタック

- **Azure Cosmos DB for NoSQL** — データストア
- **Azure AI Search** — セマンティック検索 + ベクトル検索
- **Azure OpenAI (GPT-4o)** — 自然言語分析・回答生成
- **Microsoft Fabric** — データレイク + Graph model + 閉域パイプライン
- **Managed Identity** — サービス間のキーレス認証
- **RBAC** — ロールベースアクセス制御
- **Private Endpoint / Private Link** — 閉域ネットワーク接続
