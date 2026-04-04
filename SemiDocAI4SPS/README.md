# 半導体ドキュメント自動テキスト化 + RAG 分析システム (SharePoint Online 版)

私が手元で検証した内容を紹介いたします。SharePoint Online の **folder1** にアップロードされた半導体関連ドキュメントを **Azure AI Document Intelligence** で自動テキスト化し、**Cosmos DB** に保存。さらに **Azure AI Search** でインデックス化し、**Azure OpenAI GPT-4o** を使った RAG (Retrieval-Augmented Generation) パターンで自然言語による質問応答を実現するサーバーレスシステムです。

## システム構成

```
[ユーザー]
   │ ファイルアップロード (SharePoint Online)
   ▼
[SharePoint Online]           ← folder1 (Shared Documents)
   │ Microsoft Graph API (5分間隔ポーリング)
   ▼
[Azure Functions (Python)]    ← Timer Trigger (5分間隔)
   │                            ├─ Graph API: App Registration (Client Credentials)
   │                            └─ DI / Cosmos: Managed Identity
   │ Document Intelligence API 呼び出し
   ▼
[Azure AI Document Intelligence]  ← prebuilt-layout モデル
   │ テキスト・テーブル・キーバリュー抽出
   ▼
[Azure Cosmos DB]             ← JSON 形式で保存
   ├─ ocr-data               ← OCR 結果
   └─ processed-files        ← 処理済みファイル追跡
   │
   ▼ (自動インデックス化)
[Azure AI Search Indexers]    ← 2時間間隔で自動更新
   │
   ▼
[Azure AI Search Indexes]     ← 2つのインデックス
   ├─ ocr-data-index         ← OCR テキスト全文検索
   └─ processed-files-index  ← 処理済みファイル検索
   │
   ▼ (検索 + コンテキスト構築)
[RAG Agent (Python)]          ← tools/rag_agent.py
   │
   ▼
[Azure OpenAI GPT-4o]         ← 回答生成
```

### 認証方式
| 対象 | 認証方式 |
|------|---------|
| SharePoint Online (Graph API) | Azure AD App Registration (Client Credentials フロー) |
| Document Intelligence | Managed Identity (DefaultAzureCredential) |
| Cosmos DB | Managed Identity (DefaultAzureCredential) |
| Azure AI Search → Cosmos DB | Managed Identity (System Assigned) |
| Azure OpenAI | Managed Identity (DefaultAzureCredential) |

## 対応ファイル形式

| 形式 | 拡張子 | 用途例 |
|------|--------|--------|
| **PDF** | `.pdf` | 品質検査報告書、データシート |
| **Word** | `.docx` | 設計仕様書、テスト手順書 |
| **Excel** | `.xlsx` | ウェーハテスト結果、パラメトリックデータ |
| **PowerPoint** | `.pptx` | デザインレビュー資料 |
| **画像** | `.png`, `.jpg`, `.jpeg`, `.bmp`, `.tiff` | WaveDrom タイミング波形画像 |

## プロジェクト構成

```
SemiDocAI4SPS/
├── host.json                       # Azure Functions ホスト設定
├── requirements.txt                # Azure Functions 用 Python 依存パッケージ
├── requirements-dev.txt            # 開発・ユーティリティ用 依存パッケージ
├── local.settings.json             # ローカル開発用設定
├── .funcignore                     # デプロイ除外設定
├── .gitignore
├── function_app/
│   ├── __init__.py                 # Azure Functions メインコード (TimerTrigger)
│   └── function.json               # 関数バインディング定義
├── deploy/
│   ├── deploy.ps1                  # Azure リソース一括デプロイスクリプト
│   ├── deploy_ai_search.ps1        # AI Search + OpenAI デプロイスクリプト
│   └── update_indexes_vector.ps1   # 既存インデックスのベクトル化対応スクリプト
├── sample_inputs/                  # 生成されたサンプルデータ
│   ├── design_wavedrom_soc_timing.json  # WaveDrom タイミング図 (JSON ソース)
│   ├── design_wavedrom_soc_timing.png   # WaveDrom タイミング図 (PNG)
│   ├── design_soc_specification.docx    # SoC 設計仕様書 (Word)
│   ├── manufacturing_wafer_test_results.xlsx  # ウェーハテスト結果 (Excel)
│   ├── design_review_presentation.pptx  # 設計レビュー資料 (PowerPoint)
│   └── manufacturing_quality_report.pdf # 品質検査報告書 (PDF)
└── tools/                          # ユーティリティスクリプト
    ├── generate_samples.py         # サンプルデータ生成
    ├── generate_and_upload_samples.py  # サンプル生成 + SharePoint アップロード
    ├── upload_to_sharepoint.py     # SharePoint アップロード (単体)
    ├── rag_agent.py                # RAG Agent (AI Search + GPT-4o)
    ├── populate_cosmos_ocr.py      # Cosmos DB サンプル OCR データ投入
    ├── query_cosmos.py             # Cosmos DB データ確認
    ├── query_processed.py          # 処理済みファイル確認
    ├── verify_ocr_content.py       # OCR 結果検証
    ├── clear_cosmos.py             # Cosmos DB OCR データ全削除
    └── clear_processed.py          # 処理済みファイル追跡データ全削除
```

## Azure リソース構成

| リソース | 名前 | リージョン |
|---------|------|-----------|
| リソースグループ | `rg-<your-prefix>` | (任意) |
| Storage Account (Functions 用) | `sa<your-prefix>` | (任意) |
| Document Intelligence | `docint-<your-prefix>` | (任意) |
| Cosmos DB | `cosmos-<your-prefix>` | (任意) |
| Azure Functions | `func-<your-prefix>` | (任意) |
| App Registration | `app-<your-prefix>` | - |
| Azure AI Search | `search-<your-prefix>` | (任意) |
| Azure OpenAI | `openai-<your-prefix>` | (任意) |

## SharePoint Online 設定

| 項目 | 値 |
|------|-----|
| テナント | `<your-tenant>.onmicrosoft.com` |
| サイト URL | `https://<your-tenant>.sharepoint.com/sites/<your-site>` |
| ドキュメントライブラリ | Shared Documents |
| 監視フォルダ | folder1 |

## デプロイ方法

### 一括デプロイ

```powershell
# Step 1: 基盤リソースデプロイ（Functions, Cosmos DB, Document Intelligence 等）
.\deploy\deploy.ps1

# Step 2: AI Search + OpenAI デプロイ（インデクサー, RAG 用）
.\deploy\deploy_ai_search.ps1
```

### 手動デプロイ (コードのみ)

```powershell
# func CLI でローカルビルド & デプロイ
func azure functionapp publish func-<your-prefix> --python --build local
```

> **Note:** Flex Consumption プランでは `--build local` オプションが必要です。
> デプロイストレージは SystemAssignedIdentity 認証を使用しています。

## サンプルデータ

半導体設計・製造に関わるサンプルドキュメントを自動生成し、SharePoint Online にアップロードできます。

### 生成されるファイル

| ファイル | 形式 | 内容 |
|---------|------|------|
| `design_wavedrom_soc_timing.png` | PNG | SoC AHB-Lite バスタイミングダイアグラム (7nm FinFET) |
| `design_soc_specification.docx` | Word | SSS-7NM-A1 SoC 設計仕様書 (TSMC 7nm) |
| `manufacturing_wafer_test_results.xlsx` | Excel | ウェーハテスト結果・歩留まりデータ・PCM パラメトリックデータ |
| `design_review_presentation.pptx` | PowerPoint | SoC 設計レビュー資料 (進捗・合成結果・課題) |
| `manufacturing_quality_report.pdf` | PDF | 品質検査報告書 (ウェーハテスト・外観検査・信頼性試験) |

### サンプルデータの生成 & アップロード

```powershell
# 依存パッケージインストール
pip install -r requirements-dev.txt
pip install msal requests

# サンプル生成 + SharePoint アップロード (一括実行)
python tools\generate_and_upload_samples.py
```

### サンプル生成のみ（アップロードなし）

```powershell
python tools\generate_samples.py
```

生成されたファイルは `sample_inputs/` ディレクトリに保存されます。

## 動作確認

### 1. SharePoint にファイルをアップロード

SharePoint Online の folder1 にドキュメントをアップロードします。
サンプルデータを使う場合は上記の `generate_and_upload_samples.py` を実行します。

### 2. 5分後に Cosmos DB を確認

```powershell
python tools\query_cosmos.py
```

### 3. 処理済みファイルをリセット（再処理したい場合）

```powershell
python tools\clear_processed.py
```

## RAG Agent (質問応答)

Cosmos DB に保存された OCR テキストデータに対して、自然言語で質問応答できる RAG Agent です。

### アーキテクチャ

```
Cosmos DB for NoSQL (semiconductor-db)
    ↓
Azure AI Search Indexers (自動インデックス化 / 2時間間隔)
    ↓
Azure AI Search Indexes (2つのインデックス)
    ↓
RAG Agent (検索 + コンテキスト構築)
    ↓
Azure OpenAI GPT-4o (回答生成)
```

### AI Search + OpenAI デプロイ

```powershell
# AI Search サービス + OpenAI + インデクサーを一括デプロイ
.\deploy\deploy_ai_search.ps1
```

このスクリプトは以下を自動実行します:
- Azure AI Search (Basic SKU) の作成
- Azure OpenAI + GPT-4o + text-embedding-ada-002 デプロイメントの作成
- Managed Identity による Cosmos DB / OpenAI 接続設定
- ベクトル化対応インデックス (ベクトルフィールド + セマンティック構成 + ベクトライザー) の作成
- エンベディングスキルセット (MI 認証) の作成
- データソース / インデクサーの作成
- RBAC ロール割り当て (Data Reader, Account Reader, OpenAI User)

### RAG Agent の実行

```powershell
# 依存パッケージ
pip install azure-search-documents openai azure-identity

# AI Search API キーを環境変数に設定
$env:AZURE_SEARCH_API_KEY = (az search admin-key show --resource-group rg-<your-prefix> --service-name search-<your-prefix> --query primaryKey -o tsv)

# ワンショットモード
python tools\rag_agent.py "品質検査報告書の内容を要約して"

# インタラクティブモード
python tools\rag_agent.py
```

### サンプル質問

| 質問 | 回答イメージ |
|------|-------------|
| 品質検査報告書の内容を要約して | ロット判定 PASS、歩留まり 94.3% 等の詳細情報 |
| SoC の設計進捗と課題を教えて | RTL 100%、P&R 95%、消費電力超過の課題等 |
| ウェーハテストの歩留まりを分析して | Wafer 別の歩留まり、PCM データ分析 |
| タイミング図から読み取れる情報は？ | AHB-Lite バス仕様、帯域幅 6.4 GB/s 等 |

### AI Search インデックス構成

| インデックス | データソース | 主要フィールド |
|-------------|-------------|---------------|
| `ocr-data-index` | Cosmos DB `ocr-data` | filename, fileType, department, content (全文検索), contentVector (1536次元) |
| `processed-files-index` | Cosmos DB `processed-files` | fileName, processedAt, fileNameVector (1536次元) |

各インデックスには以下が設定済みです:
- **ベクトル検索**: HNSW アルゴリズム + Azure OpenAI Vectorizer (text-embedding-ada-002)
- **セマンティック構成**: タイトル / コンテンツ / キーワードの優先度設定
- **エンベディングスキルセット**: Managed Identity 認証で OpenAI に接続

### Cosmos DB サンプルデータ投入

```powershell
# OCR 処理結果相当のサンプルデータを直接 Cosmos DB に投入
python tools\populate_cosmos_ocr.py
```

## Copilot Studio 連携

AI Search インデックスは **Integrated Vectorization** (ベクトルフィールド + ベクトライザー + セマンティック構成) 対応済みのため、**Microsoft Copilot Studio** のナレッジソースとして直接接続できます。

### 接続手順

1. Copilot Studio で新規エージェントを作成
2. **ナレッジ** → **Azure AI Search** を選択
3. 接続先: `https://search-<your-prefix>.search.windows.net`
4. インデックス: `ocr-data-index` を選択

### エージェント設定例

| 項目 | 値 |
|------|-----|
| **Name** | SemiDoc AI |
| **Description** | 半導体設計・製造ドキュメントの RAG エージェント |
| **Knowledge** | Azure AI Search (`ocr-data-index`) |


