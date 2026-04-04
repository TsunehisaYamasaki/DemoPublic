"""
処理済みファイル追跡コンテナをクリアするスクリプト
（再処理したい場合に使用）
"""
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient

ENDPOINT = "https://cosmos-<your-prefix>.documents.azure.com:443/"
DATABASE = "semiconductor-db"
CONTAINER = "processed-files"
PARTITION_KEY_PATH = "fileId"

cred = DefaultAzureCredential()
client = CosmosClient(ENDPOINT, credential=cred)
db = client.get_database_client(DATABASE)
container = db.get_container_client(CONTAINER)

items = list(container.query_items(
    f"SELECT c.id, c.{PARTITION_KEY_PATH}, c.fileName FROM c",
    enable_cross_partition_query=True,
))

print(f"処理済みレコード: {len(items)} 件")

for item in items:
    doc_id = item["id"]
    pk_value = item[PARTITION_KEY_PATH]
    file_name = item.get("fileName", "")
    container.delete_item(item=doc_id, partition_key=pk_value)
    print(f"  削除: {file_name} (fileId={pk_value})")

print(f"\n完了: {len(items)} 件の処理済みレコードを削除しました")
