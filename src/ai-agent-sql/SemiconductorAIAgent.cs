using Azure.AI.OpenAI;
using Azure.Identity;
using Microsoft.Azure.Cosmos;
using OpenAI.Chat;
using System.Text;
using System.Text.Json;

namespace SemiconductorAIAgentSQL;

public class SemiconductorAIAgent
{
    private readonly CosmosClient _cosmosClient;
    private readonly Container _designsContainer;
    private readonly Container _manufacturingContainer;
    private readonly ChatClient _chatClient;

    public SemiconductorAIAgent(string cosmosEndpoint, string openAIEndpoint, string deploymentName)
    {
        var credential = new DefaultAzureCredential();

        _cosmosClient = new CosmosClient(cosmosEndpoint, credential);
        var database = _cosmosClient.GetDatabase("semicon");
        _designsContainer = database.GetContainer("designs");
        _manufacturingContainer = database.GetContainer("manufacturing");

        var openAIClient = new AzureOpenAIClient(new Uri(openAIEndpoint), credential);
        _chatClient = openAIClient.GetChatClient(deploymentName);
    }

    public async Task<string> QueryAsync(string userQuery)
    {
        // Step 1: Ask GPT-4o to generate optimal SQL queries for the user's question
        Console.WriteLine("[DEBUG] Generating SQL queries for user question...");
        var sqlQueries = await GenerateSQLQueriesAsync(userQuery);

        // Step 2: Execute the generated queries against Cosmos DB
        Console.WriteLine("[DEBUG] Executing queries against Cosmos DB...");
        var designsData = await ExecuteQueryAsync(_designsContainer, sqlQueries.designsQuery);
        var manufacturingData = await ExecuteQueryAsync(_manufacturingContainer, sqlQueries.manufacturingQuery);

        Console.WriteLine($"[DEBUG] Retrieved {designsData.Count} designs, {manufacturingData.Count} manufacturing records");

        // Step 3: Build context and generate final answer
        var context = BuildContext(designsData, manufacturingData);
        var response = await GenerateResponseAsync(userQuery, context);

        return response;
    }

    private async Task<(string designsQuery, string manufacturingQuery)> GenerateSQLQueriesAsync(string userQuery)
    {
        var systemPrompt = @"You are a Cosmos DB NoSQL SQL query generator for semiconductor data.
Generate TWO SQL queries (one for designs container, one for manufacturing container) that will retrieve the most relevant data to answer the user's question.

DESIGNS container fields: designId, designName, designer, processNode, drcErrors (int), lvsErrors (int), powerConsumption (double), frequency (double), dieArea (double), gateCount (long), clockFrequency (double), designHours (int), completionRate (double), testCoverage (double), designEfficiency (double), revisionNumber (int), status (string), createdDate (datetime)
MANUFACTURING container fields: waferId, waferLot, designId, processStep, equipment, yield (double), defectCount (int), totalDies (int), goodDies (int), cycleTime (double), waferCost (double), defectDensity (double), processTemperature (double), throughput (double), reworkCount (int), oeeScore (double), status (string), productionDate (datetime)

CRITICAL Cosmos DB SQL rules:
- Use 'SELECT TOP 100' to limit results
- Use ORDER BY when ranking is needed
- Use WHERE for filtering
- Always alias container as 'c' (e.g. SELECT c.designId FROM c)
- DO NOT use IS NOT NULL or IS NULL (not supported)
- DO NOT use IN (subquery) (not supported)
- DO NOT use JOINs across containers
- Aggregate functions: AVG, MAX, MIN, COUNT, SUM are supported
- If the question is mainly about designs, set manufacturingQuery to: SELECT TOP 10 c.waferId, c.waferLot, c.yield, c.defectCount FROM c ORDER BY c.yield ASC
- If the question is mainly about manufacturing, set designsQuery to: SELECT TOP 10 c.designId, c.drcErrors, c.powerConsumption FROM c ORDER BY c.drcErrors DESC

Respond in EXACTLY this JSON format (no markdown, no code blocks, no explanation):
{""designsQuery"": ""SELECT ..."", ""manufacturingQuery"": ""SELECT ...""}";

        var messages = new List<ChatMessage>
        {
            new SystemChatMessage(systemPrompt),
            new UserChatMessage(userQuery)
        };

        var completion = await _chatClient.CompleteChatAsync(messages);
        var responseText = completion.Value.Content[0].Text.Trim();

        // Remove markdown code blocks if present
        if (responseText.StartsWith("```"))
        {
            responseText = responseText.Split('\n', 2).Length > 1 ? responseText.Split('\n', 2)[1] : responseText;
            if (responseText.EndsWith("```"))
                responseText = responseText[..^3];
            responseText = responseText.Trim();
        }

        try
        {
            using var doc = JsonDocument.Parse(responseText);
            var designsQuery = doc.RootElement.GetProperty("designsQuery").GetString() ?? "SELECT TOP 50 * FROM c";
            var mfgQuery = doc.RootElement.GetProperty("manufacturingQuery").GetString() ?? "SELECT TOP 50 * FROM c";
            Console.WriteLine($"[DEBUG] Designs query: {designsQuery}");
            Console.WriteLine($"[DEBUG] Manufacturing query: {mfgQuery}");
            return (designsQuery, mfgQuery);
        }
        catch
        {
            Console.WriteLine("[DEBUG] Failed to parse SQL queries, using defaults");
            return ("SELECT TOP 50 * FROM c ORDER BY c.drcErrors DESC", "SELECT TOP 50 * FROM c ORDER BY c.yield ASC");
        }
    }

    private async Task<List<string>> ExecuteQueryAsync(Container container, string sql)
    {
        var results = new List<string>();
        try
        {
            var query = new QueryDefinition(sql);
            using var iterator = container.GetItemQueryStreamIterator(query);
            while (iterator.HasMoreResults)
            {
                using var response = await iterator.ReadNextAsync();
                using var sr = new StreamReader(response.Content);
                var json = await sr.ReadToEndAsync();
                using var doc = JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("Documents", out var docs))
                {
                    foreach (var item in docs.EnumerateArray())
                    {
                        results.Add(item.GetRawText());
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[DEBUG] Query error: {ex.Message}");
        }
        return results;
    }

    private string BuildContext(List<string> designsData, List<string> manufacturingData)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Cosmos DB Query Results");
        sb.AppendLine();

        if (designsData.Count > 0)
        {
            sb.AppendLine("## Design Data:");
            foreach (var doc in designsData)
            {
                sb.AppendLine(doc);
            }
            sb.AppendLine();
        }

        if (manufacturingData.Count > 0)
        {
            sb.AppendLine("## Manufacturing Data:");
            foreach (var doc in manufacturingData)
            {
                sb.AppendLine(doc);
            }
        }

        return sb.ToString();
    }

    private async Task<string> GenerateResponseAsync(string userQuery, string context)
    {
        var systemPrompt = @"You are a semiconductor manufacturing AI assistant with expertise in IC design and fabrication.
You have direct access to the Cosmos DB database containing design and manufacturing KPI data.
Analyze the provided query results to answer questions accurately.
Always cite specific data points (design IDs, wafer IDs, metrics) from the data.
Provide statistical analysis (averages, min, max, trends) when relevant.
Answer in the same language as the user's question.";

        var messages = new List<ChatMessage>
        {
            new SystemChatMessage(systemPrompt),
            new UserChatMessage($@"Cosmos DB query results:
{context}

User Question: {userQuery}

Please provide a detailed answer based on the data above.")
        };

        var completion = await _chatClient.CompleteChatAsync(messages);
        return completion.Value.Content[0].Text;
    }
}
