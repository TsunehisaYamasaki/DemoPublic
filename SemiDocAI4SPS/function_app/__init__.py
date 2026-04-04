"""
半導体ドキュメント自動テキスト化 Azure Functions (SharePoint Online 版)
=========================================================================
SharePoint Online の folder1 にアップロードされたファイル
（PDF, Word, Excel, PPT, 画像）を Timer トリガーで定期検出し、
Microsoft Graph API でダウンロード → Document Intelligence でテキスト解析
→ Cosmos DB に保存する。

認証方式:
  - SharePoint / Graph API: Azure AD App Registration (Client Credentials)
  - Document Intelligence / Cosmos DB: Managed Identity (DefaultAzureCredential)

対象ファイル:
  - PDF (.pdf)
  - Word (.docx)
  - Excel (.xlsx)
  - PowerPoint (.pptx)
  - 画像 (.png, .jpg, .jpeg, .bmp, .tiff)
"""

import logging
import os
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.cosmos import CosmosClient, PartitionKey
import msal
import requests
import uuid
import json
from datetime import datetime

# ─── 定数 ───────────────────────────────────────────────
SUPPORTED_EXTENSIONS = {
    ".pdf", ".docx", ".xlsx", ".pptx",
    ".png", ".jpg", ".jpeg", ".bmp", ".tiff",
}

FILE_TYPE_MAP = {
    ".pdf":  "PDF",
    ".docx": "Word",
    ".xlsx": "Excel",
    ".pptx": "PowerPoint",
    ".png":  "Image",
    ".jpg":  "Image",
    ".jpeg": "Image",
    ".bmp":  "Image",
    ".tiff": "Image",
}

CONTENT_TYPE_MAP = {
    ".pdf":  "application/pdf",
    ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    ".png":  "image/png",
    ".jpg":  "image/jpeg",
    ".jpeg": "image/jpeg",
    ".bmp":  "image/bmp",
    ".tiff": "image/tiff",
}

GRAPH_API_BASE = "https://graph.microsoft.com/v1.0"


# ═══════════════════════════════════════════════════════════
# Microsoft Graph API ヘルパー
# ═══════════════════════════════════════════════════════════

def get_graph_access_token(tenant_id: str, client_id: str, client_secret: str) -> str:
    """
    MSAL を使用して Microsoft Graph API のアクセストークンを取得する。
    Client Credentials フロー（アプリのみ認証）。
    """
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    app = msal.ConfidentialClientApplication(
        client_id,
        authority=authority,
        client_credential=client_secret,
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])

    if "access_token" not in result:
        error_desc = result.get("error_description", "Unknown error")
        raise RuntimeError(f"Graph API トークン取得失敗: {error_desc}")

    logging.info("[INFO] Graph API アクセストークン取得成功")
    return result["access_token"]


def get_sharepoint_site_id(token: str, site_url: str) -> str:
    """SharePoint サイトの site ID を取得する"""
    url = f"{GRAPH_API_BASE}/sites/{site_url}"
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.get(url, headers=headers)
    resp.raise_for_status()
    site_id = resp.json()["id"]
    logging.info(f"[INFO] SharePoint Site ID: {site_id}")
    return site_id


def get_drive_id(token: str, site_id: str) -> str:
    """SharePoint サイトのデフォルトドライブ (Shared Documents) の ID を取得"""
    url = f"{GRAPH_API_BASE}/sites/{site_id}/drive"
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.get(url, headers=headers)
    resp.raise_for_status()
    drive_id = resp.json()["id"]
    logging.info(f"[INFO] Drive ID: {drive_id}")
    return drive_id


def list_files_in_folder(token: str, site_id: str, drive_id: str, folder_path: str) -> list:
    """
    SharePoint フォルダ内のファイル一覧を取得する。
    フォルダ直下のファイルのみ（サブフォルダは再帰しない）。
    """
    url = f"{GRAPH_API_BASE}/sites/{site_id}/drives/{drive_id}/root:/{folder_path}:/children"
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.get(url, headers=headers)
    resp.raise_for_status()

    items = resp.json().get("value", [])
    files = []
    for item in items:
        if "file" in item:  # フォルダでなくファイルの場合のみ
            files.append({
                "id": item["id"],
                "name": item["name"],
                "size": item.get("size", 0),
                "lastModified": item.get("lastModifiedDateTime", ""),
                "webUrl": item.get("webUrl", ""),
                "mimeType": item.get("file", {}).get("mimeType", ""),
            })

    logging.info(f"[INFO] フォルダ '{folder_path}' 内のファイル数: {len(files)}")
    return files


def download_file_from_sharepoint(token: str, site_id: str, drive_id: str, item_id: str) -> bytes:
    """SharePoint からファイルの内容をダウンロードする"""
    url = f"{GRAPH_API_BASE}/sites/{site_id}/drives/{drive_id}/items/{item_id}/content"
    headers = {"Authorization": f"Bearer {token}"}
    resp = requests.get(url, headers=headers, allow_redirects=True)
    resp.raise_for_status()
    logging.info(f"[INFO] ファイルダウンロード完了: {len(resp.content)} bytes")
    return resp.content


# ═══════════════════════════════════════════════════════════
# 処理済みファイル追跡 (Cosmos DB)
# ═══════════════════════════════════════════════════════════

def is_file_processed(container, file_id: str, last_modified: str) -> bool:
    """
    ファイルが既に処理済みかどうかを確認する。
    file_id + lastModified の組み合わせで判定（更新された場合は再処理）。
    """
    query = "SELECT c.id FROM c WHERE c.fileId = @fileId AND c.lastModified = @lastModified"
    params = [
        {"name": "@fileId", "value": file_id},
        {"name": "@lastModified", "value": last_modified},
    ]
    items = list(container.query_items(
        query=query,
        parameters=params,
        enable_cross_partition_query=True,
    ))
    return len(items) > 0


def mark_file_as_processed(container, file_id: str, file_name: str, last_modified: str) -> None:
    """処理済みとしてマークする"""
    doc = {
        "id": str(uuid.uuid4()),
        "fileId": file_id,
        "fileName": file_name,
        "lastModified": last_modified,
        "processedAt": datetime.utcnow().isoformat(),
    }
    container.create_item(body=doc)
    logging.info(f"[INFO] 処理済みマーク: {file_name}")


# ═══════════════════════════════════════════════════════════
# Document Intelligence
# ═══════════════════════════════════════════════════════════

def get_file_extension(filename: str) -> tuple:
    """ファイル名から拡張子を小文字で取得"""
    return os.path.splitext(filename)[0], os.path.splitext(filename)[1].lower()


def analyze_document_with_identity(credential, endpoint: str, file_data: bytes, content_type: str):
    """
    Document Intelligence を Managed Identity で呼び出してドキュメントを解析する。
    azure-ai-documentintelligence SDK (API v2024-11-30) を使用。
    """
    client = DocumentIntelligenceClient(
        endpoint=endpoint,
        credential=credential,
    )

    poller = client.begin_analyze_document(
        model_id="prebuilt-layout",
        body=file_data,
        content_type="application/octet-stream",
    )
    result = poller.result()
    logging.info("[SUCCESS] Document Intelligence 解析完了")
    return result


def build_cosmos_document(file_name: str, file_type: str, spo_item_id: str, result) -> dict:
    """
    Document Intelligence の解析結果を Cosmos DB 保存用 JSON に整形する。
    """
    doc = {
        "id": str(uuid.uuid4()),
        "filename": file_name,
        "fileType": file_type,
        "source": "SharePoint Online",
        "spoItemId": spo_item_id,
        "department": detect_department(file_name),
        "createdAt": datetime.utcnow().isoformat(),
        "status": "succeeded",
        "content": result.content or "",
        "pages": [],
        "tables": [],
        "keyValuePairs": [],
    }

    # ページ情報
    for page in (result.pages or []):
        lines = []
        for line in (page.lines or []):
            line_content = line.content if hasattr(line, "content") else str(line)
            lines.append({
                "content": line_content or "",
                "confidence": getattr(line, "confidence", None),
            })
        words = page.words or []
        doc["pages"].append({
            "pageNumber": getattr(page, "page_number", None),
            "width": getattr(page, "width", None),
            "height": getattr(page, "height", None),
            "unit": getattr(page, "unit", None),
            "lines": lines,
            "wordCount": len(words),
        })

    # テーブル情報
    for table in (result.tables or []):
        cells = []
        for cell in (table.cells or []):
            cells.append({
                "rowIndex": getattr(cell, "row_index", None),
                "columnIndex": getattr(cell, "column_index", None),
                "content": cell.content if hasattr(cell, "content") else "",
                "kind": getattr(cell, "kind", "content"),
            })
        doc["tables"].append({
            "rowCount": getattr(table, "row_count", None),
            "columnCount": getattr(table, "column_count", None),
            "cells": cells,
        })

    # キー・バリュー ペア
    for kv in (result.key_value_pairs or []):
        key_content = kv.key.content if (kv.key and hasattr(kv.key, "content")) else ""
        value_content = kv.value.content if (kv.value and hasattr(kv.value, "content")) else ""
        doc["keyValuePairs"].append({
            "key": key_content,
            "value": value_content,
            "confidence": getattr(kv, "confidence", None),
        })

    return doc


def detect_department(filename: str) -> str:
    """ファイル名から部門を推定する"""
    lower = filename.lower()
    if "manufacturing" in lower or "fab" in lower or "製造" in lower:
        return "manufacturing"
    elif "design" in lower or "設計" in lower or "rtl" in lower or "layout" in lower:
        return "design"
    elif "wavedrom" in lower or "waveform" in lower or "timing" in lower or "波形" in lower:
        return "design"
    else:
        return "unknown"


def save_to_cosmos_with_identity(doc: dict, credential, cosmos_endpoint: str,
                                  db_name: str, container_name: str) -> None:
    """Cosmos DB に Managed Identity で認証してドキュメントを保存"""
    cosmos_client = CosmosClient(cosmos_endpoint, credential=credential)
    db = cosmos_client.get_database_client(db_name)
    container = db.get_container_client(container_name)
    container.create_item(body=doc)
    logging.info(f"[INFO] Cosmos DB に保存完了: id={doc['id']}")


# ═══════════════════════════════════════════════════════════
# Azure Functions エントリポイント (Timer Trigger)
# ═══════════════════════════════════════════════════════════

def main(timer: func.TimerRequest) -> None:
    """
    Timer トリガー（5分間隔）で SharePoint Online の folder1 を監視し、
    新規・更新ファイルを自動テキスト化して Cosmos DB に保存する。
    """
    utc_now = datetime.utcnow().isoformat()
    logging.info(f"[START] SharePoint ポーリング開始: {utc_now}")

    if timer.past_due:
        logging.warning("[WARN] タイマーが遅延しています")

    # ─── 環境変数取得 ───
    tenant_id = os.environ["GRAPH_TENANT_ID"]
    client_id = os.environ["GRAPH_CLIENT_ID"]
    client_secret = os.environ["GRAPH_CLIENT_SECRET"]
    site_url = os.environ["SHAREPOINT_SITE_URL"]
    folder_path = os.environ["SHAREPOINT_FOLDER_PATH"]

    di_endpoint = os.environ["DOCUMENT_INTELLIGENCE_ENDPOINT"]
    cosmos_endpoint = os.environ["COSMOS_DB_ENDPOINT"]
    cosmos_db_name = os.environ["COSMOS_DB_DATABASE"]
    cosmos_container_name = os.environ["COSMOS_DB_CONTAINER"]
    cosmos_processed_container = os.environ["COSMOS_DB_PROCESSED_CONTAINER"]

    try:
        # ─── 1. Graph API アクセストークン取得 ───
        graph_token = get_graph_access_token(tenant_id, client_id, client_secret)

        # ─── 2. SharePoint サイト・ドライブ情報取得 ───
        site_id = get_sharepoint_site_id(graph_token, site_url)
        drive_id = get_drive_id(graph_token, site_id)

        # ─── 3. フォルダ内ファイル一覧取得 ───
        files = list_files_in_folder(graph_token, site_id, drive_id, folder_path)
        if not files:
            logging.info("[INFO] フォルダ内にファイルがありません。処理をスキップします。")
            return

        # ─── 4. Cosmos DB クライアント準備 ───
        azure_credential = DefaultAzureCredential()
        cosmos_client = CosmosClient(cosmos_endpoint, credential=azure_credential)
        db = cosmos_client.get_database_client(cosmos_db_name)
        processed_container = db.get_container_client(cosmos_processed_container)
        ocr_container = db.get_container_client(cosmos_container_name)

        processed_count = 0
        skipped_count = 0

        for file_info in files:
            file_name = file_info["name"]
            file_id = file_info["id"]
            last_modified = file_info["lastModified"]
            file_size = file_info["size"]

            # 拡張子チェック
            _, ext = get_file_extension(file_name)
            if ext not in SUPPORTED_EXTENSIONS:
                logging.info(f"[SKIP] 非対応ファイル形式: {file_name} ({ext})")
                skipped_count += 1
                continue

            # 処理済みチェック
            if is_file_processed(processed_container, file_id, last_modified):
                logging.info(f"[SKIP] 処理済み: {file_name}")
                skipped_count += 1
                continue

            file_type = FILE_TYPE_MAP.get(ext, "Unknown")
            logging.info(f"[PROC] 処理開始: {file_name} (type={file_type}, size={file_size})")

            # ─── 5. ファイルダウンロード ───
            file_data = download_file_from_sharepoint(graph_token, site_id, drive_id, file_id)

            # ─── 6. Document Intelligence で解析 ───
            content_type = CONTENT_TYPE_MAP.get(ext, "application/octet-stream")
            result = analyze_document_with_identity(azure_credential, di_endpoint, file_data, content_type)

            # ─── 7. Cosmos DB 保存用に整形 & 保存 ───
            doc = build_cosmos_document(file_name, file_type, file_id, result)
            ocr_container.create_item(body=doc)
            logging.info(f"[INFO] OCR 結果を Cosmos DB に保存: {file_name}")

            # ─── 8. 処理済みマーク ───
            mark_file_as_processed(processed_container, file_id, file_name, last_modified)

            processed_count += 1

        logging.info(f"[DONE] ポーリング完了: 処理={processed_count}, スキップ={skipped_count}")

    except Exception as e:
        logging.error(f"[ERROR] SharePoint ポーリング処理失敗: {e}", exc_info=True)
