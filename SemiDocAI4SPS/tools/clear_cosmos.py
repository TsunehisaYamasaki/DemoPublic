"""Cosmos DB ocr-data コンテナの全データを削除するスクリプト"""
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient

ENDPOINT = "https://cosmos-<your-prefix>.documents.azure.com:443/"
DATABASE = "semiconductor-db"
CONTAINER = "ocr-data"
PARTITION_KEY_PATH = "filename"

cred = DefaultAzureCredential()
client = CosmosClient(ENDPOINT, credential=cred)
db = client.get_database_client(DATABASE)
container = db.get_container_client(CONTAINER)

items = list(container.query_items(
    f"SELECT c.id, c.{PARTITION_KEY_PATH} FROM c",
    enable_cross_partition_query=True,
))

print(f"削除対象: {len(items)} 件")

for item in items:
    doc_id = item["id"]
    pk_value = item[PARTITION_KEY_PATH]
    container.delete_item(item=doc_id, partition_key=pk_value)
    print(f"  削除: {pk_value} (id={doc_id})")

print(f"\n完了: {len(items)} 件のドキュメントを削除しました")
