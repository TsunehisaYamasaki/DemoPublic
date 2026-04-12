import os, requests, json

token = os.environ["FABRIC_TOKEN"]
wsId = os.environ.get("FABRIC_WORKSPACE_ID", "<your-workspace-id>")
gmId = os.environ.get("FABRIC_GRAPHMODEL_ID", "<your-graphmodel-id>")

headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}

gql = 'MATCH (c:Customer)-[:purchases]->(o:`Order`) RETURN c.FullName AS customer_name, count(o) AS num_orders GROUP BY customer_name ORDER BY num_orders DESC LIMIT 5'

url = f"https://api.fabric.microsoft.com/v1/workspaces/{wsId}/graphModels/{gmId}/executeQuery?preview=true"

r = requests.post(url, headers=headers, json={"query": gql})
print(f"Status: {r.status_code}")
data = r.json()
print(json.dumps(data, indent=2, ensure_ascii=False)[:5000])
