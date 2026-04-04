"""
Cosmos DB にサンプル OCR データを直接投入するスクリプト。
Azure Functions の OCR 処理結果相当のデータを生成して保存する。
"""
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient
import uuid
from datetime import datetime

COSMOS_ENDPOINT = "https://cosmos-<your-prefix>.documents.azure.com:443/"
DB_NAME = "semiconductor-db"
OCR_CONTAINER = "ocr-data"
PROC_CONTAINER = "processed-files"

cred = DefaultAzureCredential()
client = CosmosClient(COSMOS_ENDPOINT, credential=cred)
db = client.get_database_client(DB_NAME)
ocr_container = db.get_container_client(OCR_CONTAINER)
proc_container = db.get_container_client(PROC_CONTAINER)

# --- サンプル OCR データ ---
sample_docs = [
    {
        "id": str(uuid.uuid4()),
        "filename": "design_soc_specification.docx",
        "fileType": "Word",
        "source": "SharePoint Online",
        "spoItemId": "SPO-001",
        "department": "design",
        "createdAt": datetime.utcnow().isoformat(),
        "status": "succeeded",
        "content": """SSS-7NM-A1 SoC 設計仕様書 (TSMC 7nm FinFET)

1. 概要
本ドキュメントは SSS-7NM-A1 SoC の設計仕様を定義する。プロセスノード: TSMC 7nm FinFET (N7)。

2. 主要スペック
- プロセスノード: TSMC 7nm FinFET (N7)
- トランジスタ数: 12億個
- ダイサイズ: 78.5 mm²
- 動作周波数: 最大 2.4 GHz
- 消費電力: TDP 15W (typ), 22W (max)
- 電源電圧: 0.75V (コア), 1.8V (I/O)
- パッケージ: FCBGA 1024ピン

3. バスアーキテクチャ
- AHB-Lite バス (32bit アドレス, 64bit データ)
- クロック: 800 MHz (バスクロック)
- レイテンシ: Read 2サイクル, Write 1サイクル

4. DRC/LVS 結果
- DRC エラー: 3件 (全て waiver 対象)
- LVS エラー: 0件
- テストカバレッジ: 98.2%
- 設計効率スコア: 0.94

5. メモリサブシステム
- L1 キャッシュ: 64KB (I) + 64KB (D)
- L2 キャッシュ: 1MB (統合)
- 外部メモリ: LPDDR5 4266MHz 対応

6. I/O インターフェース
- PCIe Gen4 x4
- USB 3.2 Gen2 x2
- UART x4, SPI x2, I2C x4
- GPIO: 48本""",
        "pages": [{"pageNumber": 1, "lines": [{"content": "SSS-7NM-A1 SoC 設計仕様書"}], "wordCount": 250}],
        "tables": [],
        "keyValuePairs": [
            {"key": "プロセスノード", "value": "TSMC 7nm FinFET", "confidence": 0.95},
            {"key": "動作周波数", "value": "最大 2.4 GHz", "confidence": 0.93},
            {"key": "消費電力", "value": "TDP 15W", "confidence": 0.92},
        ],
    },
    {
        "id": str(uuid.uuid4()),
        "filename": "manufacturing_wafer_test_results.xlsx",
        "fileType": "Excel",
        "source": "SharePoint Online",
        "spoItemId": "SPO-002",
        "department": "manufacturing",
        "createdAt": datetime.utcnow().isoformat(),
        "status": "succeeded",
        "content": """ウェーハテスト結果 - SSS-7NM-A1 (Lot: WL-2026-001)

ロット情報:
- ロットID: WL-2026-001
- ウェーハ枚数: 25枚
- プロセスノード: TSMC 7nm
- 製造施設: Fab-Tokyo-1

ウェーハ別テスト結果:
Wafer-01: 総ダイ数=520, 良品=487, 歩留まり=93.7%, 欠陥密度=0.12/cm²
Wafer-02: 総ダイ数=520, 良品=498, 歩留まり=95.8%, 欠陥密度=0.08/cm²
Wafer-03: 総ダイ数=520, 良品=475, 歩留まり=91.3%, 欠陥密度=0.18/cm²
Wafer-04: 総ダイ数=520, 良品=501, 歩留まり=96.3%, 欠陥密度=0.07/cm²
Wafer-05: 総ダイ数=520, 良品=492, 歩留まり=94.6%, 欠陥密度=0.11/cm²

ロット平均:
- 平均歩留まり: 94.3%
- 平均欠陥密度: 0.112/cm²
- サイクルタイム: 42.5時間
- ウェーハコスト: $3,200/枚

PCM パラメトリックデータ:
- Vth (NMOS): 0.32V ± 0.015V (spec: 0.28-0.36V) → PASS
- Vth (PMOS): -0.35V ± 0.018V (spec: -0.40--0.30V) → PASS
- Idsat (NMOS): 850 µA/µm (spec: >750) → PASS
- Idsat (PMOS): 680 µA/µm (spec: >600) → PASS
- リーク電流 Ioff: 12 nA/µm (spec: <20) → PASS
- ゲート酸化膜厚: 1.8nm ± 0.05nm""",
        "pages": [{"pageNumber": 1, "lines": [{"content": "ウェーハテスト結果"}], "wordCount": 180}],
        "tables": [
            {"rowCount": 6, "columnCount": 5, "cells": [
                {"rowIndex": 0, "columnIndex": 0, "content": "Wafer ID", "kind": "columnHeader"},
                {"rowIndex": 0, "columnIndex": 1, "content": "総ダイ数", "kind": "columnHeader"},
                {"rowIndex": 0, "columnIndex": 2, "content": "良品数", "kind": "columnHeader"},
                {"rowIndex": 0, "columnIndex": 3, "content": "歩留まり", "kind": "columnHeader"},
                {"rowIndex": 0, "columnIndex": 4, "content": "欠陥密度", "kind": "columnHeader"},
            ]}
        ],
        "keyValuePairs": [
            {"key": "平均歩留まり", "value": "94.3%", "confidence": 0.97},
            {"key": "サイクルタイム", "value": "42.5時間", "confidence": 0.95},
        ],
    },
    {
        "id": str(uuid.uuid4()),
        "filename": "manufacturing_quality_report.pdf",
        "fileType": "PDF",
        "source": "SharePoint Online",
        "spoItemId": "SPO-003",
        "department": "manufacturing",
        "createdAt": datetime.utcnow().isoformat(),
        "status": "succeeded",
        "content": """品質検査報告書 — SSS-7NM-A1 品質管理部

報告書番号: QR-2026-0042
対象ロット: WL-2026-001
検査日: 2026年3月15日

1. ウェーハレベルテスト結果
- 検査ウェーハ数: 25枚
- 合格ウェーハ数: 25枚 (全数合格)
- ロット判定: PASS
- 平均歩留まり: 94.3%
- 目標歩留まり: 90.0% → 目標達成

2. 外観検査
- 検査サンプル数: 100個
- 外観不良: 2個 (パッケージ傷)
- 外観不良率: 2.0%
- 判定基準: 5.0%以下 → PASS

3. 信頼性試験
- HTOL (High Temperature Operating Life): 1000時間 @ 125°C → PASS (0/77 fail)
- TC (Temperature Cycling): 500サイクル (-40°C〜125°C) → PASS (0/77 fail)
- HAST (Highly Accelerated Stress Test): 96時間 → PASS (0/77 fail)
- ESD (Electrostatic Discharge): HBM 2kV → PASS

4. 電気特性
- 動作周波数: 2.38 GHz (spec: >2.2 GHz) → PASS
- 消費電力: 14.2W (spec: <15W typ) → PASS
- リーク電流: 320mA @ Standby (spec: <500mA) → PASS

5. 総合判定: 合格
出荷可否: 出荷可""",
        "pages": [
            {"pageNumber": 1, "lines": [{"content": "品質検査報告書"}], "wordCount": 200},
            {"pageNumber": 2, "lines": [{"content": "信頼性試験結果"}], "wordCount": 150},
        ],
        "tables": [],
        "keyValuePairs": [
            {"key": "ロット判定", "value": "PASS", "confidence": 0.99},
            {"key": "総合判定", "value": "合格", "confidence": 0.98},
            {"key": "平均歩留まり", "value": "94.3%", "confidence": 0.97},
        ],
    },
    {
        "id": str(uuid.uuid4()),
        "filename": "design_review_presentation.pptx",
        "fileType": "PowerPoint",
        "source": "SharePoint Online",
        "spoItemId": "SPO-004",
        "department": "design",
        "createdAt": datetime.utcnow().isoformat(),
        "status": "succeeded",
        "content": """SoC 設計レビュー資料 — SSS-7NM-A1

スライド1: プロジェクト概要
- プロジェクト名: SSS-7NM-A1 次世代SoC開発
- ターゲット市場: モバイル/IoT エッジコンピューティング
- プロセス: TSMC 7nm FinFET
- 開発チーム: 設計1課 (リーダー: 田中太郎)

スライド2: 設計進捗
- RTL 設計: 100% 完了
- 論理合成: 100% 完了 → Timing Met (WNS: +0.05ns)
- P&R: 95% 完了 (最終最適化中)
- DRC: 3件残 (all waivable)
- LVS: クリーン (0 errors)

スライド3: 合成結果サマリー
- ゲート数: 12.3M gates
- クリティカルパス遅延: 0.42ns
- セットアップ違反: 0件
- ホールド違反: 0件
- 面積使用率: 78.5%

スライド4: 課題と対策
課題1: メモリコントローラの消費電力が目標値を5%超過
→ 対策: クロックゲーティング追加 (次週実施予定)

課題2: PCIe PHY のジッター特性がマージン不足
→ 対策: PLL パラメータチューニング (完了済み)

スライド5: 今後のスケジュール
- テープアウト予定: 2026年4月末
- サンプル入手: 2026年7月
- 量産開始: 2026年10月""",
        "pages": [
            {"pageNumber": 1, "lines": [{"content": "SoC 設計レビュー資料"}], "wordCount": 50},
            {"pageNumber": 2, "lines": [{"content": "設計進捗"}], "wordCount": 80},
        ],
        "tables": [],
        "keyValuePairs": [
            {"key": "P&R 進捗", "value": "95%", "confidence": 0.90},
            {"key": "テープアウト予定", "value": "2026年4月末", "confidence": 0.95},
        ],
    },
    {
        "id": str(uuid.uuid4()),
        "filename": "design_wavedrom_soc_timing.png",
        "fileType": "Image",
        "source": "SharePoint Online",
        "spoItemId": "SPO-005",
        "department": "design",
        "createdAt": datetime.utcnow().isoformat(),
        "status": "succeeded",
        "content": """SoC AHB-Lite バスタイミングダイアグラム (7nm FinFET)

信号名とタイミング:
CLK: クロック信号 (800MHz)
HADDR: アドレスバス → A0, A1, A2 シーケンス
HWDATA: ライトデータ → D0, D1
HRDATA: リードデータ → Q0
HWRITE: ライト制御 → High (Write), Low (Read)
HREADY: レディ信号 → 通常 High, Wait State で Low
HRESP: レスポンス → OKAY

タイミング特性:
- Setup Time: 0.15ns
- Hold Time: 0.08ns
- Clock-to-Q: 0.12ns
- バス帯域幅: 6.4 GB/s (64bit × 800MHz)""",
        "pages": [{"pageNumber": 1, "lines": [{"content": "AHB-Lite Bus Timing"}], "wordCount": 60}],
        "tables": [],
        "keyValuePairs": [],
    },
]

# 投入実行
print("=" * 60)
print("  Cosmos DB サンプル OCR データ投入")
print("=" * 60)

for doc in sample_docs:
    ocr_container.create_item(body=doc)
    print(f"[OK] {doc['filename']} ({doc['fileType']}, {doc['department']})")

    # processed-files にも追加
    proc_doc = {
        "id": str(uuid.uuid4()),
        "fileId": doc["spoItemId"],
        "fileName": doc["filename"],
        "lastModified": doc["createdAt"],
        "processedAt": datetime.utcnow().isoformat(),
    }
    proc_container.create_item(body=proc_doc)

print(f"\n合計 {len(sample_docs)} ドキュメントを投入しました。")
print("ocr-data + processed-files に保存完了")
