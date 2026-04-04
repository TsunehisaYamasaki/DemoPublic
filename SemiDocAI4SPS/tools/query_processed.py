"""processed-files コンテナを確認するスクリプト"""
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient

cred = DefaultAzureCredential()
client = CosmosClient("https://cosmos-<your-prefix>.documents.azure.com:443/", credential=cred)
db = client.get_database_client("semiconductor-db")
pc = db.get_container_client("processed-files")

items = list(pc.query_items(
    "SELECT c.fileName, c.processedAt, c.fileId FROM c ORDER BY c.processedAt DESC",
    enable_cross_partition_query=True
))

print(f"{'fileName':45s} | {'processedAt':30s} | fileId")
print("-" * 120)
for i in items:
    fn = i.get("fileName", "")
    pa = i.get("processedAt", "")
    fid = i.get("fileId", "")
    print(f"{fn:45s} | {pa:30s} | {fid}")
print(f"\nTotal: {len(items)} records in processed-files")
