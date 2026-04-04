"""
半導体ドキュメント RAG Agent
============================
Azure AI Search (Cosmos DB ocr-data インデックス) + Azure OpenAI GPT-4o による
RAG (Retrieval-Augmented Generation) パターンの質問応答エージェント。

使い方:
  # インタラクティブモード
  python tools/rag_agent.py

  # ワンショットモード
  python tools/rag_agent.py "品質検査報告書の内容を要約して"

環境変数 (省略時はデフォルト値を使用):
  AZURE_SEARCH_ENDPOINT   : AI Search エンドポイント
  AZURE_SEARCH_API_KEY     : AI Search 管理キー (省略時は DefaultAzureCredential)
  AZURE_OPENAI_ENDPOINT    : OpenAI エンドポイント
  AZURE_OPENAI_DEPLOYMENT  : GPT-4o デプロイメント名
"""

import os
import sys
from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.core.credentials import AzureKeyCredential
from openai import AzureOpenAI

# ─── 設定 ──────────────────────────────────────────────
SEARCH_ENDPOINT     = os.environ.get("AZURE_SEARCH_ENDPOINT", "https://search-<your-prefix>.search.windows.net")
SEARCH_API_KEY      = os.environ.get("AZURE_SEARCH_API_KEY", "")
OCR_INDEX_NAME      = "ocr-data-index"
PROC_INDEX_NAME     = "processed-files-index"

OPENAI_ENDPOINT     = os.environ.get("AZURE_OPENAI_ENDPOINT", "https://openai-<your-prefix>.openai.azure.com/")
OPENAI_DEPLOYMENT   = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4o")
MAX_RESULTS         = 50  # インデックスから取得する最大ドキュメント数

SYSTEM_PROMPT = """あなたは半導体設計・製造の専門知識を持つ AI アシスタントです。
Azure AI Search から取得した OCR テキストデータ (設計仕様書、品質報告書、テスト結果、
タイミングダイアグラム等) をもとに、ユーザーの質問に正確に回答してください。

回答ルール:
- 提供されたコンテキストに基づいて回答してください。
- 具体的なファイル名、数値、KPI を引用してください。
- コンテキストに十分な情報がない場合はその旨を伝えてください。
- 日本語で回答してください。
"""


def create_search_client(index_name: str):
    """AI Search クライアントを作成"""
    if SEARCH_API_KEY:
        credential = AzureKeyCredential(SEARCH_API_KEY)
    else:
        credential = DefaultAzureCredential()
    return SearchClient(
        endpoint=SEARCH_ENDPOINT,
        index_name=index_name,
        credential=credential,
    )


def create_openai_client():
    """Azure OpenAI クライアントを作成"""
    credential = DefaultAzureCredential()
    token = credential.get_token("https://cognitiveservices.azure.com/.default")
    return AzureOpenAI(
        azure_endpoint=OPENAI_ENDPOINT,
        api_version="2024-12-01-preview",
        azure_ad_token=token.token,
    )


def search_ocr_data(query: str) -> list[dict]:
    """ocr-data インデックスからドキュメントを検索"""
    client = create_search_client(OCR_INDEX_NAME)
    results = client.search(
        search_text=query,
        top=MAX_RESULTS,
        select=["filename", "fileType", "department", "content", "createdAt"],
    )
    docs = []
    for r in results:
        docs.append({
            "filename":   r.get("filename", ""),
            "fileType":   r.get("fileType", ""),
            "department": r.get("department", ""),
            "content":    r.get("content", "")[:3000],  # トークン節約
            "createdAt":  r.get("createdAt", ""),
        })
    return docs


def search_processed_files() -> list[dict]:
    """processed-files インデックスから処理済みファイル一覧を取得"""
    client = create_search_client(PROC_INDEX_NAME)
    results = client.search(
        search_text="*",
        top=100,
        select=["fileName", "processedAt"],
    )
    return [{"fileName": r.get("fileName", ""), "processedAt": r.get("processedAt", "")} for r in results]


def build_context(ocr_docs: list[dict], proc_docs: list[dict]) -> str:
    """RAG コンテキストを構築"""
    lines = ["# 取得したナレッジベース (半導体ドキュメントデータベース)\n"]

    if ocr_docs:
        lines.append("## OCR テキストデータ:")
        for doc in ocr_docs:
            lines.append(f"\n### ファイル: {doc['filename']} ({doc['fileType']}, 部門: {doc['department']})")
            lines.append(f"作成日: {doc['createdAt']}")
            lines.append(f"内容:\n{doc['content']}")
    else:
        lines.append("## OCR テキストデータ: なし")

    if proc_docs:
        lines.append(f"\n## 処理済みファイル数: {len(proc_docs)}")
        for p in proc_docs[:10]:
            lines.append(f"- {p['fileName']} (処理日: {p['processedAt']})")

    return "\n".join(lines)


def generate_response(openai_client, user_query: str, context: str) -> str:
    """GPT-4o で回答を生成"""
    response = openai_client.chat.completions.create(
        model=OPENAI_DEPLOYMENT,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"## コンテキスト:\n{context}\n\n## 質問:\n{user_query}"},
        ],
        temperature=0.3,
        max_tokens=2000,
    )
    return response.choices[0].message.content


def query(user_query: str) -> str:
    """RAG パイプライン: 検索 → コンテキスト構築 → 回答生成"""
    print(f"[検索中] AI Search からドキュメントを取得...")
    ocr_docs = search_ocr_data(user_query)
    proc_docs = search_processed_files()
    print(f"[取得完了] OCR ドキュメント: {len(ocr_docs)} 件, 処理済みファイル: {len(proc_docs)} 件")

    context = build_context(ocr_docs, proc_docs)

    print(f"[生成中] GPT-4o で回答を生成中...")
    openai_client = create_openai_client()
    answer = generate_response(openai_client, user_query, context)
    return answer


def main():
    print("=" * 60)
    print("  半導体ドキュメント RAG Agent")
    print("  Azure AI Search + Azure OpenAI GPT-4o")
    print("=" * 60)
    print()

    # ワンショットモード
    if len(sys.argv) > 1:
        user_query = " ".join(sys.argv[1:])
        print(f"質問: {user_query}\n")
        answer = query(user_query)
        print(f"\n{'─' * 60}")
        print(f"回答:\n{answer}")
        return

    # インタラクティブモード
    print("質問を入力してください (exit で終了)\n")
    print("サンプル質問:")
    samples = [
        "品質検査報告書の内容を要約して",
        "SoC 設計仕様書のスペックを教えて",
        "ウェーハテストの歩留まりデータを分析して",
        "設計レビューの課題は何ですか？",
        "タイミング図から読み取れる情報を教えて",
    ]
    for i, s in enumerate(samples, 1):
        print(f"  {i}. {s}")
    print()

    while True:
        try:
            user_input = input("質問> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n終了します。")
            break

        if not user_input or user_input.lower() == "exit":
            print("終了します。")
            break

        answer = query(user_input)
        print(f"\n{'─' * 60}")
        print(f"回答:\n{answer}")
        print(f"{'─' * 60}\n")


if __name__ == "__main__":
    main()
