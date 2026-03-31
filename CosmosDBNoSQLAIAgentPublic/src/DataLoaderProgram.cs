using System;
using System.Threading.Tasks;

namespace CosmosDBNoSQLAIAgent;

class DataLoaderProgram
{
    static async Task Main(string[] args)
    {
        Console.WriteLine("=== Cosmos DB Data Generator ===");
        Console.WriteLine("設計部門と製造部門のKPIサンプルデータを生成します");
        Console.WriteLine("各テーブル: 20列 × 1000行\n");

        var cosmosEndpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
        
        if (string.IsNullOrEmpty(cosmosEndpoint))
        {
            Console.WriteLine("エラー: COSMOS_ENDPOINT 環境変数が設定されていません");
            Console.WriteLine("使用例:");
            Console.WriteLine("  $env:COSMOS_ENDPOINT = \"https://your-cosmos-account.documents.azure.com:443/\"");
            Console.WriteLine("  dotnet run --project DataLoader.csproj");
            return;
        }

        Console.WriteLine($"Cosmos DB Endpoint: {cosmosEndpoint}");
        Console.WriteLine($"認証方法: DefaultAzureCredential (Azure AD)\n");

        try
        {
            var generator = new DataGenerator(cosmosEndpoint);

            // Step 1: Delete all existing data
            Console.WriteLine("Step 1: 既存データの削除");
            Console.WriteLine("既存のデータをすべて削除しますか? (y/n): ");
            var confirm = Console.ReadLine()?.ToLower();
            
            if (confirm == "y" || confirm == "yes")
            {
                await generator.DeleteAllDataAsync();
            }
            else
            {
                Console.WriteLine("削除をスキップしました。");
            }

            // Step 2: Generate Design Data
            Console.WriteLine("\nStep 2: 設計部門データの生成");
            await generator.GenerateDesignDataAsync(1000);

            // Step 3: Generate Manufacturing Data
            Console.WriteLine("\nStep 3: 製造部門データの生成");
            await generator.GenerateManufacturingDataAsync(1000);

            Console.WriteLine("\n=== データ生成完了 ===");
            Console.WriteLine("設計部門データ: 1000件 (20列)");
            Console.WriteLine("製造部門データ: 1000件 (20列)");
            Console.WriteLine("\nAzure Portalで確認してください:");
            Console.WriteLine("  Data Explorer → designs コンテナ");
            Console.WriteLine("  Data Explorer → manufacturing コンテナ");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"\nエラーが発生しました: {ex.Message}");
            Console.WriteLine($"詳細: {ex.StackTrace}");
        }
    }
}
