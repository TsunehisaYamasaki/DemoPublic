"""Cosmos DB のデータを確認するスクリプト"""
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient

cred = DefaultAzureCredential()
client = CosmosClient("https://cosmos-<your-prefix>.documents.azure.com:443/", credential=cred)
db = client.get_database_client("semiconductor-db")
container = db.get_container_client("ocr-data")

query = "SELECT c.filename, c.fileType, c.department, c.source, c.status, c.createdAt FROM c ORDER BY c.createdAt DESC"
items = list(container.query_items(query, enable_cross_partition_query=True))

print(f"{'filename':40s} | {'fileType':12s} | {'department':15s} | {'source':20s} | {'status':10s} | {'createdAt'}")
print("-" * 130)
for item in items:
    fn = item.get("filename", "")
    ft = item.get("fileType", "")
    dp = item.get("department", "")
    src = item.get("source", "")
    st = item.get("status", "")
    ca = item.get("createdAt", "")
    print(f"{fn:40s} | {ft:12s} | {dp:15s} | {src:20s} | {st:10s} | {ca}")

print(f"\nTotal: {len(items)} documents")
