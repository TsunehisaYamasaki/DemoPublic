#!/usr/bin/env python3
"""
半導体サンプルデータ生成 & SharePoint Online アップロード 統合スクリプト
====================================================================
半導体設計・製造に関わるサンプルドキュメント（Word, Excel, PowerPoint, PDF, 画像）を
自動生成し、SharePoint Online の folder1 にアップロードする。

生成されるファイル:
  1. PNG  - WaveDrom SoC バスタイミングダイアグラム
  2. DOCX - SoC 設計仕様書
  3. XLSX - ウェーハテスト結果 (歩留まりデータ)
  4. PPTX - 設計レビュー資料
  5. PDF  - 品質検査報告書

Usage:
    pip install -r requirements-dev.txt
    pip install msal requests
    python tools/generate_and_upload_samples.py

環境変数 (省略時はスクリプト内デフォルト値を使用):
    GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CLIENT_SECRET
"""
import os
import sys
import msal
import requests
from pathlib import Path

# ─── 設定 ───
TENANT_ID = os.environ.get("GRAPH_TENANT_ID", "")
CLIENT_ID = os.environ.get("GRAPH_CLIENT_ID", "")
CLIENT_SECRET = os.environ.get("GRAPH_CLIENT_SECRET", "")

SHAREPOINT_HOST = "<your-tenant>.sharepoint.com"
SITE_PATH = "/sites/<your-site>"
FOLDER_NAME = "folder1"

SAMPLE_DIR = Path(__file__).resolve().parent.parent / "sample_inputs"

SUPPORTED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".tiff", ".bmp",
                        ".docx", ".xlsx", ".pptx"}


# ═══════════════════════════════════════════════════════════
# Phase 1: サンプルデータ生成
# ═══════════════════════════════════════════════════════════
def generate_samples():
    """generate_samples.py のメイン処理を呼び出す"""
    print("=" * 60)
    print("Phase 1: サンプルファイル生成")
    print("=" * 60)

    # 同じ tools/ ディレクトリの generate_samples.py を import
    tools_dir = Path(__file__).resolve().parent
    sys.path.insert(0, str(tools_dir))
    import generate_samples

    generate_samples.generate_wavedrom_image()
    generate_samples.generate_word_document()
    generate_samples.generate_excel_document()
    generate_samples.generate_pptx_document()
    generate_samples.generate_pdf_document()

    print()
    print("生成されたファイル一覧:")
    files = sorted(SAMPLE_DIR.iterdir())
    for f in files:
        if f.is_file() and f.suffix.lower() in SUPPORTED_EXTENSIONS:
            print(f"  {f.name:50s} {f.stat().st_size:>10,} bytes")
    print()


# ═══════════════════════════════════════════════════════════
# Phase 2: SharePoint Online アップロード
# ═══════════════════════════════════════════════════════════
def get_access_token():
    """MSAL でアクセストークンを取得"""
    authority = f"https://login.microsoftonline.com/{TENANT_ID}"
    app = msal.ConfidentialClientApplication(
        CLIENT_ID, authority=authority, client_credential=CLIENT_SECRET
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in result:
        print(f"[ERROR] トークン取得失敗: {result.get('error_description', result)}")
        sys.exit(1)
    return result["access_token"]


def get_site_and_drive(token):
    """SharePoint のサイト ID とドライブ ID を取得"""
    headers = {"Authorization": f"Bearer {token}"}

    site_url = f"https://graph.microsoft.com/v1.0/sites/{SHAREPOINT_HOST}:{SITE_PATH}"
    resp = requests.get(site_url, headers=headers)
    resp.raise_for_status()
    site_id = resp.json()["id"]
    print(f"  Site ID: {site_id}")

    drives_url = f"https://graph.microsoft.com/v1.0/sites/{site_id}/drives"
    resp = requests.get(drives_url, headers=headers)
    resp.raise_for_status()
    drives = resp.json().get("value", [])
    drive_id = None
    for d in drives:
        if d.get("name") == "Documents" or d.get("driveType") == "documentLibrary":
            drive_id = d["id"]
            break
    if not drive_id and drives:
        drive_id = drives[0]["id"]
    if not drive_id:
        print("[ERROR] ドライブが見つかりません")
        sys.exit(1)
    print(f"  Drive ID: {drive_id}")
    return site_id, drive_id


def upload_file(token, drive_id, folder_path, file_path):
    """ファイルを SharePoint にアップロード"""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/octet-stream",
    }
    file_name = file_path.name
    upload_url = (
        f"https://graph.microsoft.com/v1.0/drives/{drive_id}"
        f"/root:/{folder_path}/{file_name}:/content"
    )

    with open(file_path, "rb") as f:
        data = f.read()

    resp = requests.put(upload_url, headers=headers, data=data)
    if resp.status_code in (200, 201):
        item = resp.json()
        print(f"  [OK] {file_name} ({len(data):,} bytes) -> id={item.get('id', 'N/A')}")
        return True
    else:
        print(f"  [FAIL] {file_name}: {resp.status_code} {resp.text[:200]}")
        return False


def upload_samples():
    """生成済みサンプルファイルを SharePoint Online にアップロード"""
    print("=" * 60)
    print("Phase 2: SharePoint Online アップロード")
    print("=" * 60)

    files = [f for f in sorted(SAMPLE_DIR.iterdir())
             if f.is_file() and f.suffix.lower() in SUPPORTED_EXTENSIONS]
    if not files:
        print(f"[ERROR] {SAMPLE_DIR} にアップロード対象ファイルがありません")
        sys.exit(1)

    print(f"\nアップロード対象: {len(files)} ファイル")

    print("\n[1/3] アクセストークン取得...")
    token = get_access_token()
    print("  [OK] トークン取得完了")

    print("\n[2/3] SharePoint サイト・ドライブ取得...")
    site_id, drive_id = get_site_and_drive(token)

    print(f"\n[3/3] {FOLDER_NAME} へアップロード中...")
    success = 0
    failed = 0
    for f in files:
        if upload_file(token, drive_id, FOLDER_NAME, f):
            success += 1
        else:
            failed += 1

    print(f"\n{'=' * 60}")
    print(f"アップロード完了: {success} 成功, {failed} 失敗")
    print(f"{'=' * 60}")
    return failed == 0


# ═══════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════
if __name__ == "__main__":
    print()
    print("╔══════════════════════════════════════════════════════════╗")
    print("║  半導体サンプルデータ生成 & SharePoint Online アップロード  ║")
    print("╚══════════════════════════════════════════════════════════╝")
    print()

    generate_samples()
    ok = upload_samples()

    print()
    if ok:
        print("✓ すべてのサンプルファイルが SharePoint Online の folder1 にアップロードされました。")
        print("  5分後に Azure Functions が自動的に OCR 処理を実行します。")
    else:
        print("✗ 一部のファイルアップロードに失敗しました。")
        sys.exit(1)
