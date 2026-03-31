# Azure Cosmos DB + AI Search Evaluation Agent

Azure Cosmos DB、Azure AI Search、Azure OpenAIを統合した、半導体設計・製造データの分析システムです。

## 🎯 プロジェクト概要

本プロジェクトは、Azure Cosmos DB for NoSQL とAzure OpenAIを統合した半導体製造データ分析システムで、**RAG（Retrieval-Augmented Generation）パターン**を実装しています。

### アーキテクチャ

```
Cosmos DB for NoSQL (semiconductor database)
    ↓
Azure AI Search Indexers (自動インデックス化)
    ↓
Azure AI Search Indexes (2つのインデックス)
    ↓
RAG Agent (検索 + コンテキスト構築)
    ↓
Azure OpenAI GPT-4o (回答生成)
```

### 主要コンポーネント

- **Azure Cosmos DB for NoSQL**: 設計部門と製造部門のKPIデータを格納（各20列、1,000件）
- **Azure AI Search**: Cosmos DBデータをインデックス化し、高速検索を実現
- **RAG Agent (.NET 8.0)**: Azure AI Searchから最大2,000件のコンテキストを取得し、GPT-4oで分析
- **Azure OpenAI (GPT-4o)**: 大量コンテキスト（350K TPM）での自然言語分析

### 技術的特徴

- **Infrastructure as Code**: Bicepによる完全自動デプロイ
- **セキュア認証**: Azure AD + RBACによるキーレス認証
- **Managed Identity**: サービス間認証にManaged Identityを使用
- **大規模コンテキスト処理**: 最大2,000ドキュメントを一度に分析可能

## 📊 データモデル

### designs コンテナ（設計部門データ）
- **パーティションキー**: `/designId`
- **ドキュメント数**: 1,000件
- **列数**: 20列

**主要KPI**: designId, designName, revision, designer, team, status, completionRate, designHours, drcErrors, lvsErrors, powerConsumption, chipArea, gateCount, clockFrequency, testCoverage, designEfficiency, criticalPathDelay, setupViolations, holdViolations, createdDate

### manufacturing コンテナ（製造部門データ）
- **パーティションキー**: `/waferLot`
- **ドキュメント数**: 1,000件
- **列数**: 20列

**主要KPI**: lotId, waferId, waferLot, designId, facility, processNode, totalDies, goodDies, yieldRate, defectRate, cycleTime, waferCost, defectDensity, processTemperature, throughput, reworkCount, oeScore, binningCategory, testDuration, manufactureDate

## 🚀 クイックスタート

### 前提条件

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) がインストールされていること
- [.NET 8.0 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) がインストールされていること
- Azure サブスクリプションへのアクセス権
- Azure OpenAI サービスへのアクセス権（申請が必要な場合あり）

### ステップ1: リポジトリのクローン

```powershell
git clone https://github.com/TsunehisaYamasaki/CosmosDBNoSQLAIAgent.git
cd CosmosDBNoSQLAIAgent
```

### ステップ2: インフラストラクチャのデプロイ

```powershell
# 1. Azureにログイン
az login

# 2. リソースグループ作成
$resourceGroup = "<YOUR-RESOURCE-GROUP>"
$location = "eastus2"
az group create --name $resourceGroup --location $location

# 3. Cosmos DB for NoSQLをデプロイ
az deployment group create `
  --name cosmos-deployment `
  --resource-group $resourceGroup `
  --template-file infra/main.bicep `
  --parameters infra/main.bicepparam

# 4. エンドポイントを取得
$cosmosEndpoint = az deployment group show `
  --name cosmos-deployment `
  --resource-group $resourceGroup `
  --query properties.outputs.cosmosEndpoint.value `
  -o tsv

Write-Host "Cosmos DB Endpoint: $cosmosEndpoint"
```

### ステップ3: サンプルデータの投入

```powershell
# 環境変数を設定
$env:COSMOS_ENDPOINT = $cosmosEndpoint

# データローダーを実行
cd src
dotnet run
```

**実行結果**: 設計データ1,000件 + 製造データ1,000件が投入されます（所要時間: 30-60秒）

### ステップ4: Azure AI SearchとOpenAIのセットアップ

詳細は [AISearchEvaluationAgent/README.md](./AISearchEvaluationAgent/README.md) を参照してください。

1. Azure AI Searchサービスを作成
2. Azure OpenAI サービスとgpt-4oデプロイメントを作成
3. `AISearchEvaluationAgent/appsettings.json` を作成（`appsettings.sample.json`をコピー）
4. インデクサーを作成: `.\create-indexers.ps1`

### ステップ5: AI Agentの実行

```powershell
cd AISearchEvaluationAgent
dotnet run
```

インタラクティブモードで質問を入力するか、コマンドライン引数で直接質問：

```powershell
dotnet run -- "DRCエラーが最も多い設計を教えてください"
```

### ステップ3a: 直接クエリ型AIエージェントの実行

```powershell
# 環境変数を設定
$env:COSMOS_ENDPOINT = "https://<YOUR-COSMOS-ACCOUNT-NAME>.documents.azure.com:443/"
$env:OPENAI_ENDPOINT = "https://<YOUR-OPENAI-ACCOUNT-NAME>.openai.azure.com/"

# AIエージェントを起動
cd src\ai-agent-sql
dotnet run
```

### ステップ3b: RAG型AIエージェントのセットアップ

```powershell
# AI Searchリソースを作成（既にデプロイ済みの場合はスキップ）
cd AISearchEvaluationAgent
az search service create `
  --name <YOUR-SEARCH-SERVICE-NAME> `
  --resource-group <YOUR-RESOURCE-GROUP> `
  --location eastus2 `
  --sku basic

# AI Searchのセットアップを実行（Managed Identity設定、インデックス作成）
.\setup-search.ps1

# RAG型AIエージェントを起動
dotnet run
```

## 💡 主要機能と実装パターン比較

### パターン1: 直接クエリ型 (src/ai-agent-sql/)

**特徴**:
- GPT-4oが自然言語からCosmos DB SQLクエリを自動生成
- Cosmos DB SDKで直接SQLクエリを実行
- 低レイテンシー、シンプルな実装
- 構造化データに最適

**自然言語での質問応答**:
```
質問: DRCエラーが最も多い設計のDesignIDと件数を教えてください
回答: 設計データを分析した結果、DRCエラーが最も多い設計は...
      DesignID: IC-2026-0543
      DRCエラー数: 98件
```

**主要機能**:
- 設計データの統計分析
- 製造データの歩留まり分析
- DRCエラー/LVSエラーのトレンド分析
- 消費電力最適化の提案
- クロスドメイン分析（設計×製造）

### パターン2: RAG型 (AISearchEvaluationAgent/)

**特徴**:
- Azure AI Searchでセマンティック検索
- 自然言語クエリで柔軟な検索
- 非構造化・半構造化データにも対応可能
- スケーラブルな検索インフラ

**アーキテクチャ**:
```
1. ユーザークエリ → AI Searchでセマンティック検索
2. 関連データを取得（designs + manufacturing）
3. 取得データを知識ベースとして整形
4. GPT-4oで文脈理解した回答を生成
```

**RAGの利点**:
- 大規模データセットでも高速検索
- セマンティック検索による柔軟なマッチング
- 検索結果のランキングと relevance スコア
- ファセット・フィルタリングによる絞り込み

### 実装比較表

| 項目 | 直接クエリ型 | RAG型 |
|------|-------------|-------|
| データアクセス | Cosmos DB直接 | AI Search経由 |
| レイテンシ | 低（100-200ms） | 中（300-500ms） |
| 実装複雑度 | 低 | 中 |
| コスト | 低 | 中〜高 |
| スケーラビリティ | 中 | 高 |
| セマンティック検索 | なし | あり |
| 適用シーン | 構造化データ、明確なクエリ | 柔軟な検索、大規模データ |
## 🤖 AIエージェントの使用例

### 起動方法

```powershell
cd src/ai-agent-sql
$env:COSMOS_ENDPOINT = "https://<YOUR-COSMOS-ACCOUNT-NAME>.documents.azure.com:443/"
$env:OPENAI_ENDPOINT = "https://<YOUR-OPENAI-ACCOUNT-NAME>.openai.azure.com/"
dotnet run
```

### サンプル質問

```
質問1: DRCエラーが最も多い設計のDesignIDと件数を教えてください
→ AIがCosmos DBから実際のデータを取得して分析

質問2: 歩留まり率が90%以下のウェハを教えてください
→ 製造データをフィルタリングして回答

質問3: 設計データの統計情報を教えてください
→ 平均値、最大値、最小値などを計算

質問4: 消費電力が最も高い設計は？
→ powerConsumptionでソートして回答
```

### AIエージェントの特徴

- **リアルタイムデータ取得**: Cosmos DBから最新データを動的にクエリ
- **コンテキスト理解**: 質問の意図を解析して適切なクエリを実行
- **統計計算**: 平均、最大、最小などの集計を自動実行
- **対話型UI**: Spectre.Consoleによる美しいインターフェース

### 利用例

```
質問: 設計データの平均完了率を教えて
回答: 設計データを分析した結果、平均完了率は74.5%です...

質問: 製造の歩留まり率を改善する方法は？
回答: 製造データから、以下の改善ポイントが見つかりました...
```

## 🎯 ベクトル検索を活用した高度なクエリ例

### セマンティック検索の強み

ベクトル化されたAI Searchでは、キーワードの完全一致ではなく、**意味的な類似性**に基づいて検索が可能です。複数の指標を総合的に評価し、ビジネス的な洞察を提供する質問に威力を発揮します。

### 🌟 推奨クエリ例

#### 1. 品質と効率のバランス分析

**質問**:
```
「品質と効率のバランスが取れた優れた設計の特徴を教えてください」
```

**回答例**:
```
分析結果から、優れた設計には以下の共通特徴が見られます：

【品質指標】
- DRCエラー: 平均15件以下（業界標準の30%削減）
- LVSエラー: 平均8件以下
- テストカバレッジ: 85%以上

【効率指標】
- 設計効率スコア: 0.85以上
- 完成率: 90%以上
- リビジョン回数: 平均3回以下

【代表的な設計】
- IC-2024-00342: DRC 12件、効率0.92、完成率95%
- IC-2024-00789: DRC 8件、効率0.89、完成率94%

これらの設計に共通するのは、初期設計段階での検証の徹底と、
段階的なレビュープロセスの実施です。
```

#### 2. コスト最適化と品質維持

**質問**:
```
「製造コストを削減しながら高品質を維持するための改善策は？」
```

**回答例**:
```
データ分析から、以下の改善アプローチを推奨します：

【現状分析】
- 高コスト要因: 歩留まり率85%以下のロットで平均ウェーハコスト$4,200
- 低コストロット: 歩留まり率95%以上で平均$3,100（26%のコスト差）

【改善提案】
1. プロセス温度の最適化
   - 現状: 800-1200°C の広範囲
   - 推奨: 950-1050°C に集約（歩留まり率2.3%向上）

2. 欠陥密度の低減
   - 目標: 15 defects/cm² 以下
   - 施策: Fab1-Tokyo の best practice を他施設に展開

3. サイクルタイムの短縮
   - 目標: 平均45時間以下
   - 効果: ウェーハコスト8-12%削減

【ROI予測】
実施後6ヶ月で製造コスト平均18%削減、品質指標は横ばい維持の見込み
```

#### 3. 設計と製造の相関分析

**質問**:
```
「設計フェーズで製造トラブルに繋がりやすいパターンはありますか？」
```

**回答例**:
```
設計データと製造データのクロス分析により、以下のリスクパターンを特定：

【高リスクパターン】
1. DRCエラー60件以上 × ゲート数800万以上
   → 製造歩留まり率: 平均82.3%（標準より12%低下）
   → 該当設計: 47件

2. 消費電力4.5W以上 × ダイ面積85mm²以上
   → 欠陥密度: 平均38 defects/cm²（標準より52%高）
   → 該当設計: 23件

3. 設計時間2000時間超 × リビジョン7回以上
   → サイクルタイム: 平均62時間（標準より38%増）
   → 該当設計: 31件

【予防措置】
- 設計段階でのDRCチェックの頻度を2倍に
- サーマル解析の早期実施（設計完成率50%時点）
- 複雑設計のモジュール分割による管理性向上

【期待効果】
これらの対策により製造歩留まり率3-5%の向上が見込まれます。
```

#### 4. エネルギー効率の分析

**質問**:
```
「エネルギー効率が優れているチップの特性を分析してください」
```

**回答例**:
```
エネルギー効率上位20%のチップを分析した結果：

【効率的な設計の特徴】
- 消費電力: 平均1.8W（全体平均3.2Wの56%）
- クロック周波数: 1500-2500 MHz（最適レンジ）
- プロセスノード: 5nm または 7nm が90%
- ゲート数: 200万-400万（適度な規模）

【電力効率指標】
- Performance per Watt: 上位群は下位群の2.4倍
- 動作温度: 平均15°C低い
- 寿命予測: 平均1.8倍長い

【設計手法】
・クロックゲーティングの積極的な活用
・電力ドメインの細分化（平均7ドメイン）
・動的電圧/周波数スケーリング（DVFS）の実装

【推奨アクション】
新規設計では5nmプロセス + DVFS実装により、
消費電力40%削減と性能10%向上を同時達成可能
```

#### 5. 製造信頼性の評価

**質問**:
```
「信頼性の高い製造プロセスの条件とは？」
```

**回答例**:
```
信頼性指標上位25%の製造プロセスを分析：

【高信頼性プロセスの特徴】
1. 歩留まり率: 平均94.2%（標準偏差±1.8%）
2. OEEスコア: 平均92.5%
3. 再作業率: 0.8回以下/ロット
4. 欠陥密度: 12 defects/cm² 以下

【環境パラメータ】
- プロセス温度: 980-1020°C（±20°Cの厳密管理）
- 圧力: 950-970 hPa
- ガス流量: 1200-1400 sccm
- エッチング時間: 120-180秒

【ファシリティ別パフォーマンス】
1. Fab1-Tokyo: 歩留まり率95.1%、OEE 94.2%（ベストプラクティス）
2. Fab3-Kyushu: 歩留まり率93.8%、OEE 91.8%
3. Fab2-Osaka: 歩留まり率92.1%、OEE 89.5%（改善余地あり）

【改善推奨】
Fab2-OsakaへFab1-Tokyoのプロセスレシピ展開により、
全体歩留まり率1.2-1.8%向上が期待できます。
```

#### 6. タイムtoマーケット最適化

**質問**:
```
「タイムtoマーケットを短縮できる可能性がある設計を探してください」
```

**回答例**:
```
設計完了時間が短い上位20%の分析：

【高速設計の特徴】
- 設計時間: 平均920時間（全体平均1450時間の63%）
- 完成率: 平均88.5%（品質も担保）
- リビジョン数: 平均2.3回（少ない手戻り）

【設計パターン】
1. モジュール再利用率が高い
   - IPブロック活用: 平均28個（標準の1.8倍）
   - 既存設計資産の効果的活用

2. 適切な規模設定
   - ゲート数: 150万-350万（最適レンジ）
   - ダイ面積: 25-60 mm²

3. チーム構成
   - TeamA と TeamC が高速設計を多く実現
   - 平均経験年数: 8.5年以上

【高速化可能な候補設計】
- IC-2024-00156: 現在1200h → 推定850h可能
- IC-2024-00487: 現在1450h → 推定950h可能
- IC-2024-00723: 現在1600h → 推定1100h可能

【施策】
IPブロックライブラリの拡充とモジュール設計の標準化により、
平均設計時間25-30%短縮が見込めます。
```

### ❌ 避けるべき単純なクエリ

ベクトル検索では以下のような単純な検索は推奨されません（通常のSQLクエリで十分）：

```
❌ 「DRCエラーが99の設計を教えてください」
   → 完全一致検索（WHERE drcErrors = 99）

❌ 「デザイナーがTanakaのレコードは？」
   → 単純なフィルタリング

❌ 「最も消費電力が高い設計は？」
   → 単純なソート処理（ORDER BY powerConsumption DESC）
```

### 💡 ベクトル検索を活かすポイント

1. **複数の概念を組み合わせる**: 「品質 × 効率」「コスト × 性能」
2. **"なぜ"や"どのように"を問う**: 因果関係や改善提案を求める
3. **ドメイン用語を自然言語で**: 「エネルギー効率」「信頼性」「最適化」
4. **ビジネス価値に結びつける**: ROI、コスト削減、品質向上

これらの質問により、単純なデータベースクエリでは得られない、**AIの推論能力とベクトル検索の意味理解を活かした洞察**が得られます。

##  プロジェクト構成

```
CosmosDBNoSQLAIAgent/
├── src/
│   ├── ai-agent-sql/                    # 直接クエリ型AIエージェント
│   │   ├── Program.cs                   # メインプログラム（対話UI）
│   │   ├── SemiconductorAIAgent.cs      # AIエージェントロジック
│   │   └── SemiconductorAIAgent.csproj  # プロジェクトファイル
│   │
│   ├── DataLoaderProgram.cs             # データローダー メインプログラム
│   ├── DataGenerator.cs                 # サンプルデータ生成
│   └── DataLoader.csproj                # データローダー プロジェクトファイル
│
├── AISearchEvaluationAgent/             # RAG型AIエージェント
│   ├── Program.cs                       # メインプログラム（対話UI）
│   ├── SemiconductorRAGAgent.cs         # RAGエージェントロジック
│   ├── EvaluationAIAgent.csproj         # プロジェクトファイル
│   ├── appsettings.json                 # 設定ファイル
│   └── create-indexers.ps1              # インデクサー作成スクリプト
│
├── infra/                               # Infrastructure as Code
│   ├── main.bicep                       # Cosmos DB for NoSQLのデプロイ
│   └── main.bicepparam                  # パラメータファイル
│
├── IMPLEMENTATION_SUMMARY.md            # 実装の詳細ドキュメント
└── README.md                            # このファイル
```

## 🔧 トラブルシューティング

### 認証エラーが発生する場合

```powershell
# Azure CLIでログインを確認
az account show

# RBACロールの割り当てを確認
az cosmosdb sql role assignment list `
  --account-name <YOUR-COSMOS-ACCOUNT-NAME> `
  --resource-group <YOUR-RESOURCE-GROUP>
```

### デプロイ済みリソース情報

| リソース | 名前 | エンドポイント |
|---------|------|---------------|
| Cosmos DB NoSQL | <YOUR-COSMOS-ACCOUNT-NAME> | https://<YOUR-COSMOS-ACCOUNT-NAME>.documents.azure.com:443/ |
| Azure AI Search | <YOUR-SEARCH-SERVICE-NAME> | https://<YOUR-SEARCH-SERVICE-NAME>.search.windows.net |
| Azure OpenAI | <YOUR-OPENAI-ACCOUNT-NAME> | https://<YOUR-OPENAI-ACCOUNT-NAME>.openai.azure.com/ |
| GPT-4o デプロイメント | gpt-4o | - |

## 📚 関連ドキュメント

- **[IMPLEMENTATION_SUMMARY.md](./IMPLEMENTATION_SUMMARY.md)** - 実装の詳細、アーキテクチャ、学んだこと
- [Azure Cosmos DB for NoSQL](https://learn.microsoft.com/azure/cosmos-db/sql/)
- [Azure OpenAI Service](https://learn.microsoft.com/azure/ai-services/openai/)
- [Microsoft.Azure.Cosmos SDK](https://learn.microsoft.com/dotnet/api/microsoft.azure.cosmos)

## 📝 ライセンス

MIT License

---

**実装完了日**: 2026年1月23日  
**バージョン**: 1.0.0
