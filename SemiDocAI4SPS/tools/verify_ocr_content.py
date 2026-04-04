"""OCR 結果の内容を詳細に確認するスクリプト"""
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient

cred = DefaultAzureCredential()
client = CosmosClient("https://cosmos-<your-prefix>.documents.azure.com:443/", credential=cred)
db = client.get_database_client("semiconductor-db")
container = db.get_container_client("ocr-data")

# 各ファイルから最新1件ずつ取得して内容確認
query = """
SELECT c.filename, c.fileType, c.department, c.source, c.status, c.createdAt,
       c.content, ARRAY_LENGTH(c.pages) AS pageCount,
       ARRAY_LENGTH(c.tables) AS tableCount,
       ARRAY_LENGTH(c.keyValuePairs) AS kvCount
FROM c ORDER BY c.createdAt DESC
"""
items = list(container.query_items(query, enable_cross_partition_query=True))

seen = set()
for item in items:
    fn = item.get("filename", "")
    if fn in seen:
        continue
    seen.add(fn)

    content = item.get("content", "")
    text_len = len(content)
    preview = content[:300].replace("\n", "\\n") if content else "(empty)"

    print("=" * 100)
    print(f"File: {fn}")
    print(f"Type: {item.get('fileType')} | Dept: {item.get('department')} | Status: {item.get('status')}")
    print(f"Pages: {item.get('pageCount', 0)} | Tables: {item.get('tableCount', 0)} | KV Pairs: {item.get('kvCount', 0)}")
    print(f"Text Length: {text_len:,} chars")
    print(f"Content Preview: {preview}")
    print()
