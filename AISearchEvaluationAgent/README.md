# AI Search Evaluation Agent 実装

## 概要

このディレクトリには、Azure AI SearchとAzure OpenAIを使用したRAG（Retrieval-Augmented Generation）パターンの半導体AI Agentが含まれています。

## プロジェクト構成

### 主要ファイル

#### 実行プログラム
- **Program.cs** - メインエントリーポイント。コマンドライン引数またはインタラクティブモードでクエリを受け付けます。
- **SemiconductorRAGAgent.cs** - RAGエージェントの本体。Azure AI Searchからデータを検索し、OpenAIで回答を生成します。
- **EvaluationAIAgent.csproj** - プロジェクト設定ファイル（NuGetパッケージ依存関係を定義）

#### 設定ファイル
- **appsettings.json** - Azure AI SearchとAzure OpenAIのエンドポイント、APIキー、インデックス名などの設定

#### インフラストラクチャ
- **create-indexers.ps1** - Azure AI Searchのインデクサーを作成するPowerShellスクリプト

#### ドキュメント
- **README.md** - このファイル。プロジェクトの説明とセットアップガイド

### 関連プロジェクト

#### Cosmos DB データ生成（../src/）
- **DataGenerator.cs** - 半導体設計・製造データを生成するクラス
- **DataLoaderProgram.cs** - Cosmos DBにサンプルデータを投入するメインプログラム
- 実行方法: `cd src; $env:COSMOS_ENDPOINT = "..."; dotnet run`

## アーキテクチャ

```
Cosmos DB SQL API (semiconductor database)
    ↓
AI Search Indexers (インデックス化)
    ↓
AI Search Indexes (designs-index, manufacturing-index)
    ↓
RAG Agent (検索 + コンテキスト構築)
    ↓
Azure OpenAI GPT-4o (回答生成)
```

## コンポーネント

### 1. Azure AI Search
- **サービス名**: `search-semiconductor-2923`
- **エンドポイント**: `https://search-semiconductor-2923.search.windows.net`
- **インデックス**:　https://learn.microsoft.com/ja-jp/azure/search/search-how-to-create-search-index?tabs=portal
  - `designs-index`: 設計データ（1000レコード）
    - フィールド: designId, designName, designer, team, drcErrors, powerConsumption
  - `manufacturing-index`: 製造データ（1000レコード）
    - フィールド: waferId, waferLot, designId, facility, yield, defectRate, cycleTime
- **データソース**: Cosmos DB SQL API（Managed Identity認証）
- **インデクサー**: 2時間ごとに自動更新

### 2. Azure OpenAI
- **サービス名**: `openai-tsuney-9509`（または環境に応じて変更）
- **デプロイ名**: `gpt-4o`
- **容量**: 350K TPM（大量コンテキスト処理用）
- **用途**: RAGパターンでの回答生成

### 3. .NET 8.0 AI Agent
- **プロジェクト**: `EvaluationAIAgent.csproj`
- **主要クラス**: `SemiconductorRAGAgent`
- **認証**: DefaultAzureCredential (Azure AD)
- **最大取得件数**: 各インデックスから1000件（合計2000件のコンテキスト）

## セットアップ手順

### 前提条件
- .NET 8.0 SDK がインストールされている
- Azure CLI がインストールされている
- Azureにログイン済み (`az login`)
- 適切なRBACロールが割り当てられている
  - Azure OpenAI: `Cognitive Services OpenAI User`
  - Azure AI Search: `Search Index Data Reader`（API Keyを使用しない場合）

### 1. Cosmos DB データ生成（初回のみ）

プロジェクトルートの `src/` フォルダにデータ生成プログラムがあります。

```powershell
cd ../src
$env:COSMOS_ENDPOINT = "https://your-cosmos-account.documents.azure.com:443/"
dotnet run --project DataLoader.csproj
```

これにより、`semiconductor` データベースに以下のコンテナが作成され、各1000件のサンプルデータが投入されます：
- `designs` - 半導体設計データ（DRCエラー、消費電力など）
- `manufacturing` - 製造データ（歩留まり、欠陥率など）

### 2. AI Search インデクサー作成

Cosmos DBからAI Searchへデータをインポートするインデクサーを作成します。

```powershell
cd AISearchEvaluationAgent
.\create-indexers.ps1
```

このスクリプトは以下を実行します：
- `designs-indexer` の作成（2時間ごとに自動更新）
- `manufacturing-indexer` の作成（2時間ごとに自動更新）

**注意**: Cosmos DBがManaged Identity認証を使用している場合、AI SearchのManaged Identityに適切なロール（`Cosmos DB Built-in Data Reader`）が必要です。

### 3. AI Agentの実行

**初回セットアップ**: `appsettings.json` を作成

```powershell
cd AISearchEvaluationAgent

# サンプルファイルをコピーして設定ファイルを作成
Copy-Item appsettings.sample.json appsettings.json

# エディタで appsettings.json を開き、以下の値を設定：
# - AzureAISearch:Endpoint
# - AzureAISearch:ApiKey (またはManaged Identity使用時は空白)
# - AzureOpenAI:Endpoint
# - AzureOpenAI:DeploymentName
```

**ビルドと実行**:

```powershell
dotnet build
dotnet run
```

または、コマンドライン引数で直接質問を指定：

```powershell
dotnet run -- "DRCエラーが最も少ない設計を教えてください"
```

**注意**: `appsettings.json` は `.gitignore` に含まれており、GitHubにプッシュされません。

## プログラム詳細

### Program.cs（エントリーポイント）

メインプログラムの役割：

1. **設定読み込み** - `appsettings.json` から Azure AI Search と Azure OpenAI の接続情報を取得
2. **エージェント初期化** - `SemiconductorRAGAgent` のインスタンスを作成（最大取得件数: 各インデックス1000件）
3. **クエリ処理**:
   - コマンドライン引数がある場合: 引数の質問を処理して終了
   - 引数がない場合: インタラクティブモードで繰り返し質問を受け付ける
4. **結果表示** - Spectre.Console を使用した見やすい表示

**実行例**:
```powershell
# インタラクティブモード
dotnet run

# ワンショットモード
dotnet run -- "DRCエラーが最も少ない設計を教えてください"
```

### SemiconductorRAGAgent.cs（RAGエージェント本体）

RAGパターンの実装クラス。主要メソッド：

#### 1. QueryAsync(string userQuery)
ユーザーの質問を処理するメインメソッド。以下の3ステップを実行：

**Step 1: データ検索 (Retrieval)**
- `SearchDesignsAsync("*")` - designs-index から最大1000件取得
- `SearchManufacturingAsync("*")` - manufacturing-index から最大1000件取得
- ページネーション処理により、Azure AI Searchの1リクエスト1000件制限に対応

**Step 2: コンテキスト構築**
- `BuildRAGContext()` - 取得したデータをMarkdown形式に整形
- 設計データ: DesignID, Designer, Team, DRCエラー数, 消費電力
- 製造データ: WaferID, Lot, Facility, 歩留まり率, 欠陥率

**Step 3: 回答生成 (Generation)**
- `GenerateResponseAsync()` - GPT-4oにコンテキストと質問を送信
- システムプロンプト: 半導体製造の専門家AIアシスタントとして動作
- レスポンス: コンテキストに基づいた詳細な分析結果

#### 2. 内部メソッド

**SearchDesignsAsync / SearchManufacturingAsync**
- Azure AI Search の `SearchClient` を使用
- ページネーション対応（Skip/Sizeパラメータ）
- 最大取得件数制御（デフォルト: 各1000件）
- ソート順: DRCエラー降順、歩留まり昇順

**BuildRAGContext**
- `StringBuilder` でMarkdown形式のコンテキストを構築
- 構造化データとして整形し、LLMが解析しやすい形式に

**GenerateResponseAsync**
- Azure OpenAI の `ChatClient` を使用
- システムプロンプト + コンテキスト + ユーザー質問を組み合わせ
- DefaultAzureCredential による認証（APIキー不要）

### 認証フロー

両プログラムとも `DefaultAzureCredential` を使用：
1. 環境変数（サービスプリンシパル）
2. Managed Identity（Azure上で実行時）
3. Visual Studio / Azure CLI 認証情報
4. Interactive Browser 認証

### データフロー

```
ユーザー質問
    ↓
Program.cs (Entry)
    ↓
SemiconductorRAGAgent.QueryAsync()
    ↓
Azure AI Search (2000件取得)
    ↓
BuildRAGContext (Markdown整形)
    ↓
Azure OpenAI GPT-4o (350K TPM)
    ↓
回答生成・表示
```

## 実装の特徴

### RAGパターン詳細
本エージェントのRAGプロセスは以下の3ステップで実行されます（対応するコード: `SemiconductorRAGAgent.cs`）：

1. **データ検索 (Retrieval)**:
   - **コード**: `QueryAsync` メソッド内の `SearchDesignsAsync` および `SearchManufacturingAsync`
   - Azure AI Searchの2つのインデックス（`designs-index`, `manufacturing-index`）に対してクエリを実行します。
   - `SearchClient` を使用してデータを取得します。
   - **特徴**: 単なるキーワード検索だけでなく、分析のために大量のドキュメント（最大各1000件、合計2000件）を取得し、広範なコンテキストとして利用します。

2. **コンテキスト構築**:
   - **コード**: `BuildRAGContext` メソッド
   - 取得した半導体設計データ（DRCエラー、消費電力など）と製造データ（歩留まり、欠陥密度など）を統合します。
   - LLMが理解しやすい構造化データ形式テキスト（Markdown形式のリスト）に変換し、システムプロンプトに組み込みます。

3. **回答生成 (Generation)**:
   - **コード**: `GenerateResponseAsync` メソッド
   - 構築されたコンテキストとユーザーの質問を `gpt-4o` モデルに送信します。
   - GPT-4oの強力な推論能力と長いコンテキストウィンドウ（350K TPM）を活かし、数千件規模のデータを一度に分析して、インサイトを含んだ回答を生成します。

### パフォーマンス最適化

- **大容量処理**: Azure OpenAI デプロイメントを350K TPMに設定することで、2000件のドキュメントコンテキストを一度に処理可能
- **ページネーション**: AI Searchの1リクエスト1000件制限を回避するため、Skip/Sizeを使った複数回リクエストを実装
- **ソート最適化**: 分析に有用なデータ（DRCエラー多/歩留まり低）を優先的に取得

### サンプルクエリ
- DRCエラーが最も多い設計を教えてください
- 歩留まりが低いウェーハのデザインは何ですか？
- 消費電力が最も低い設計は？
- コストが高いウェーハの特徴を分析してください
- 品質改善のための推奨事項を教えてください

## 既存実装との比較

| 項目 | Cosmos DB 直接クエリ | RAG Pattern (AISearchEvaluationAgent) |
|------|----------------------|---------------------------------------|
| データアクセス | Cosmos DB SQL直接クエリ | AI Search経由 |
| 検索方式 | SQLクエリ | フルテキスト検索（セマンティック検索対応可能） |
| スケーラビリティ | 中 | 高 |
| レイテンシ | 低 | 中 |
| 実装複雑度 | 低 | 中 |
| コスト | 低 | 中〜高 |
| 大量データ分析 | 制限あり | 最大2000件のコンテキスト処理可能 |
| 自然言語検索 | なし | あり |

## トラブルシューティング

### インデクサーエラー: "missing authorizations"

**原因**: AI SearchのManaged IdentityがCosmos DBへのアクセス権限を持っていない

**解決方法**:
```powershell
# Cosmos DB Built-in Data Reader ロールを割り当て
az cosmosdb sql role assignment create \
  --account-name <cosmos-account-name> \
  --resource-group <resource-group> \
  --role-definition-id 00000000-0000-0000-0000-000000000001 \
  --principal-id <search-service-principal-id> \
  --scope "/"
```

### OpenAI エラー: "Rate limit exceeded (429)"

**原因**: デプロイメントの容量（TPM）が不足

**解決方法**:
- Azure Portalで該当するデプロイメントの容量を増やす（推奨: 350K TPM以上）
- または、`SemiconductorRAGAgent.cs` の `maxResultsPerIndex` パラメータを減らす（例: 500）

### 認証エラー: "Unauthorized (401)"

**原因**: ユーザーに適切なRBACロールが割り当てられていない

**解決方法**:
```powershell
# Azure OpenAIへのアクセス権を付与
az role assignment create \
  --role "Cognitive Services OpenAI User" \
  --assignee <user-email-or-object-id> \
  --scope /subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<openai-account>
```
