using Azure;
using Azure.AI.OpenAI;
using Azure.Identity;
using Azure.Search.Documents;
using Azure.Search.Documents.Models;
using OpenAI.Chat;
using System.Text;
using System.Text.Json;

namespace EvaluationAIAgent;

/// <summary>
/// Semiconductor AI Agent using Azure AI Search + Azure OpenAI (RAG Pattern)
/// </summary>
public class SemiconductorRAGAgent
{
    private readonly SearchClient _designsSearchClient;
    private readonly SearchClient _manufacturingSearchClient;
    private readonly ChatClient _chatClient;
    private readonly int _maxResultsPerIndex;

    public SemiconductorRAGAgent(
        string searchEndpoint,
        string designsIndexName,
        string manufacturingIndexName,
        string openAIEndpoint,
        string deploymentName,
        string? searchApiKey = null,
        int maxResultsPerIndex = 500)  // Default to 500 per index (1000 total) to avoid token limits
    {
        _maxResultsPerIndex = maxResultsPerIndex;
        
        // Initialize AI Search clients
        if (!string.IsNullOrEmpty(searchApiKey))
        {
            var searchCredential = new AzureKeyCredential(searchApiKey);
            _designsSearchClient = new SearchClient(
                new Uri(searchEndpoint),
                designsIndexName,
                searchCredential);

            _manufacturingSearchClient = new SearchClient(
                new Uri(searchEndpoint),
                manufacturingIndexName,
                searchCredential);
        }
        else
        {
            var credential = new DefaultAzureCredential();
            _designsSearchClient = new SearchClient(
                new Uri(searchEndpoint),
                designsIndexName,
                credential);

            _manufacturingSearchClient = new SearchClient(
                new Uri(searchEndpoint),
                manufacturingIndexName,
                credential);
        }

        // Initialize Azure OpenAI client (always use Managed Identity)
        var openAICredential = new DefaultAzureCredential();
        var openAIClient = new AzureOpenAIClient(new Uri(openAIEndpoint), openAICredential);
        _chatClient = openAIClient.GetChatClient(deploymentName);
    }

    public async Task<string> QueryAsync(string userQuery)
    {
        // Step 1: Retrieve relevant knowledge from AI Search indexes
        // Use "*" to get all documents for better context
        var designsKnowledge = await SearchDesignsAsync("*");
        var manufacturingKnowledge = await SearchManufacturingAsync("*");

        Console.WriteLine($"[DEBUG] Retrieved {designsKnowledge.Count} designs, {manufacturingKnowledge.Count} manufacturing records");

        // Step 2: Build RAG context
        var context = BuildRAGContext(designsKnowledge, manufacturingKnowledge);

        // Step 3: Generate response using GPT-4o with retrieved context
        var response = await GenerateResponseAsync(userQuery, context);

        return response;
    }

    private async Task<List<SearchDocument>> SearchDesignsAsync(string query)
    {
        var documents = new List<SearchDocument>();
        int skip = 0;
        const int pageSize = 1000;  // Maximum size per request (Azure AI Search limit)
        bool hasMore = true;

        // Fetch documents using pagination up to maxResultsPerIndex
        while (hasMore && documents.Count < _maxResultsPerIndex)
        {
            var searchOptions = new SearchOptions
            {
                Size = Math.Min(pageSize, _maxResultsPerIndex - documents.Count),
                Skip = skip,
                Select = { "designId", "designName", "designer", "team", "drcErrors", "powerConsumption" },
                OrderBy = { "drcErrors desc" }  // Sort by DRC errors descending
            };

            var results = await _designsSearchClient.SearchAsync<SearchDocument>("*", searchOptions);
            int count = 0;

            await foreach (var result in results.Value.GetResultsAsync())
            {
                documents.Add(result.Document);
                count++;
                if (documents.Count >= _maxResultsPerIndex) break;
            }

            // If we got fewer results than requested, we've reached the end
            hasMore = count == searchOptions.Size;
            skip += pageSize;
        }

        return documents;
    }

    private async Task<List<SearchDocument>> SearchManufacturingAsync(string query)
    {
        var documents = new List<SearchDocument>();
        int skip = 0;
        const int pageSize = 1000;  // Maximum size per request (Azure AI Search limit)
        bool hasMore = true;

        // Fetch documents using pagination up to maxResultsPerIndex
        while (hasMore && documents.Count < _maxResultsPerIndex)
        {
            var searchOptions = new SearchOptions
            {
                Size = Math.Min(pageSize, _maxResultsPerIndex - documents.Count),
                Skip = skip,
                Select = { "waferId", "waferLot", "designId", "facility", "yield", "cycleTime", "defectRate" },
                OrderBy = { "yield asc" }  // Sort by yield ascending (lowest first)
            };

            var results = await _manufacturingSearchClient.SearchAsync<SearchDocument>("*", searchOptions);
            int count = 0;

            await foreach (var result in results.Value.GetResultsAsync())
            {
                documents.Add(result.Document);
                count++;
                if (documents.Count >= _maxResultsPerIndex) break;
            }

            // If we got fewer results than requested, we've reached the end
            hasMore = count == searchOptions.Size;
            skip += pageSize;
        }

        return documents;
    }

    private string BuildRAGContext(List<SearchDocument> designsData, List<SearchDocument> manufacturingData)
    {
        var contextBuilder = new StringBuilder();
        contextBuilder.AppendLine("# Retrieved Knowledge from Semiconductor Database");
        contextBuilder.AppendLine();

        if (designsData.Any())
        {
            contextBuilder.AppendLine("## Design Data:");
            foreach (var doc in designsData)
            {
                contextBuilder.AppendLine($"- Design: {doc.GetString("designName")} (ID: {doc.GetString("designId")})");
                contextBuilder.AppendLine($"  Designer: {doc.GetString("designer")}, Team: {doc.GetString("team")}");
                contextBuilder.AppendLine($"  DRC Errors: {(int)doc.GetDouble("drcErrors")}, Power: {doc.GetDouble("powerConsumption")} mW");
            }
            contextBuilder.AppendLine();
        }

        if (manufacturingData.Any())
        {
            contextBuilder.AppendLine("## Manufacturing Data:");
            foreach (var doc in manufacturingData)
            {
                contextBuilder.AppendLine($"- Wafer: {doc.GetString("waferId")} (Lot: {doc.GetString("waferLot")})");
                contextBuilder.AppendLine($"  Design ID: {doc.GetString("designId")}, Facility: {doc.GetString("facility")}");
                contextBuilder.AppendLine($"  Yield: {doc.GetDouble("yield")}%, DefectRate: {doc.GetDouble("defectRate")}, CycleTime: {doc.GetDouble("cycleTime")}");
            }
        }

        return contextBuilder.ToString();
    }

    private async Task<string> GenerateResponseAsync(string userQuery, string context)
    {
        var systemPrompt = @"You are a semiconductor manufacturing AI assistant with expertise in design and fabrication.
You help engineers and managers analyze design data, manufacturing KPIs, and provide insights.

Use the provided knowledge base context to answer questions accurately.
If the context doesn't contain sufficient information, acknowledge this and provide general guidance.
Always cite specific data points (design IDs, wafer IDs, metrics) from the context when available.";

        var messages = new List<ChatMessage>
        {
            new SystemChatMessage(systemPrompt),
            new UserChatMessage($@"Context from knowledge base:
{context}

User Question: {userQuery}

Please provide a detailed answer based on the context above.")
        };

        var completion = await _chatClient.CompleteChatAsync(messages);
        return completion.Value.Content[0].Text;
    }
}
