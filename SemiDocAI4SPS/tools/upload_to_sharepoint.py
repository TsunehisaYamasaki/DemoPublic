#!/usr/bin/env python3
"""
サンプルファイルを SharePoint Online の folder1 にアップロードするスクリプト
===================================================================
Microsoft Graph API を使用してファイルをアップロードする。

Usage:
    pip install msal requests
    python tools/upload_to_sharepoint.py
"""
import os
import sys
import msal
import requests
from pathlib import Path

# ─── 設定 ───
TENANT_ID = "<your-tenant-id>"
CLIENT_ID = "<your-client-id>"
CLIENT_SECRET = "<your-client-secret>"
SHAREPOINT_HOST = "<your-tenant>.sharepoint.com"
SITE_PATH = "/sites/<your-site>"
FOLDER_NAME = "folder1"

# アップロード対象ディレクトリ
SAMPLE_DIR = Path(__file__).resolve().parent.parent / "sample_inputs"

# サポート対象拡張子 (SemiDocAI4SPS の Function が処理できる形式)
SUPPORTED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".tiff", ".bmp",
                        ".docx", ".xlsx", ".pptx"}


def get_access_token():
    """MSAL でアクセストークンを取得"""
    authority = f"https://login.microsoftonline.com/{TENANT_ID}"
    app = msal.ConfidentialClientApplication(
        CLIENT_ID, authority=authority, client_credential=CLIENT_SECRET
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in result:
        print(f"[ERROR] Failed to acquire token: {result.get('error_description', result)}")
        sys.exit(1)
    return result["access_token"]


def get_site_and_drive(token):
    """SharePoint のサイト ID とドライブ ID を取得"""
    headers = {"Authorization": f"Bearer {token}"}

    # サイト取得
    site_url = f"https://graph.microsoft.com/v1.0/sites/{SHAREPOINT_HOST}:{SITE_PATH}"
    resp = requests.get(site_url, headers=headers)
    resp.raise_for_status()
    site_id = resp.json()["id"]
    print(f"[OK] Site ID: {site_id}")

    # デフォルトドライブ取得
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
        print("[ERROR] No drive found")
        sys.exit(1)
    print(f"[OK] Drive ID: {drive_id}")

    return site_id, drive_id


def upload_file(token, drive_id, folder_path, file_path):
    """ファイルを SharePoint にアップロード (4MB 以下は簡易アップロード)"""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/octet-stream",
    }
    file_name = file_path.name
    upload_url = (
        f"https://graph.microsoft.com/v1.0/drives/{drive_id}"
        f"/root:/{folder_path}/{file_name}:/content"
    )

    file_size = file_path.stat().st_size
    with open(file_path, "rb") as f:
        data = f.read()

    resp = requests.put(upload_url, headers=headers, data=data)
    if resp.status_code in (200, 201):
        item = resp.json()
        print(f"  [OK] {file_name} ({file_size:,} bytes) -> id={item.get('id', 'N/A')}")
        return True
    else:
        print(f"  [FAIL] {file_name}: {resp.status_code} {resp.text[:200]}")
        return False


def main():
    print("=" * 60)
    print("SharePoint Online folder1 へサンプルファイルをアップロード")
    print("=" * 60)

    # サンプルファイル確認
    if not SAMPLE_DIR.exists():
        print(f"[ERROR] Sample directory not found: {SAMPLE_DIR}")
        print("Run 'python tools/generate_samples.py' first.")
        sys.exit(1)

    files = [f for f in sorted(SAMPLE_DIR.iterdir())
             if f.is_file() and f.suffix.lower() in SUPPORTED_EXTENSIONS]
    if not files:
        print(f"[ERROR] No supported files found in {SAMPLE_DIR}")
        sys.exit(1)

    print(f"\nFound {len(files)} files to upload:")
    for f in files:
        print(f"  {f.name} ({f.stat().st_size:,} bytes)")

    # 認証
    print("\n[1/3] Acquiring access token...")
    token = get_access_token()
    print("[OK] Token acquired")

    # サイト・ドライブ取得
    print("\n[2/3] Getting SharePoint site and drive...")
    site_id, drive_id = get_site_and_drive(token)

    # アップロード
    print(f"\n[3/3] Uploading files to {FOLDER_NAME}...")
    success = 0
    failed = 0
    for f in files:
        if upload_file(token, drive_id, FOLDER_NAME, f):
            success += 1
        else:
            failed += 1

    print(f"\n{'=' * 60}")
    print(f"Upload complete: {success} succeeded, {failed} failed")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
