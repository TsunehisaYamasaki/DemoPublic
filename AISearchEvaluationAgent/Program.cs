using EvaluationAIAgent;
using Microsoft.Extensions.Configuration;
using Spectre.Console;

// Load configuration
var configuration = new ConfigurationBuilder()
    .SetBasePath(Directory.GetCurrentDirectory())
    .AddJsonFile("appsettings.json", optional: false)
    .Build();

var searchEndpoint = configuration["AzureAISearch:Endpoint"]!;
var designsIndex = configuration["AzureAISearch:DesignsIndexName"]!;
var manufacturingIndex = configuration["AzureAISearch:ManufacturingIndexName"]!;
var searchApiKey = configuration["AzureAISearch:ApiKey"]; // Optional
var openAIEndpoint = configuration["AzureOpenAI:Endpoint"]!;
var deploymentName = configuration["AzureOpenAI:DeploymentName"]!;

// Initialize RAG Agent
AnsiConsole.MarkupLine("[bold cyan]╔════════════════════════════════════════════════════════╗[/]");
AnsiConsole.MarkupLine("[bold cyan]║  Semiconductor AI Agent (RAG Pattern)                  ║[/]");
AnsiConsole.MarkupLine("[bold cyan]║  Azure AI Search + Azure OpenAI GPT-4o                 ║[/]");
AnsiConsole.MarkupLine("[bold cyan]╚════════════════════════════════════════════════════════╝[/]");
AnsiConsole.WriteLine();

AnsiConsole.Status()
    .Start("初期化中...", ctx =>
    {
        ctx.Spinner(Spinner.Known.Dots);
        ctx.SpinnerStyle(Style.Parse("cyan"));
        Thread.Sleep(1000);
    });

// Initialize AI Agent
// maxResultsPerIndex: Maximum documents to fetch per index (default: 500)
// - Set to 1000+ for comprehensive analysis (requires sufficient OpenAI quota)
// - Azure OpenAI capacity: 100K TPM
var agent = new SemiconductorRAGAgent(
    searchEndpoint,
    designsIndex,
    manufacturingIndex,
    openAIEndpoint,
    deploymentName,
    searchApiKey,
    maxResultsPerIndex: 1000);  // Fetch 1000 docs per index (2000 total)

AnsiConsole.MarkupLine("[green]✓[/] AI Agent初期化完了");
AnsiConsole.WriteLine();

// Sample queries
var sampleQueries = new[]
{
    "DRCエラーが最も多い設計を教えてください",
    "歩留まりが低いウェーハのデザインは何ですか？",
    "消費電力が最も低い設計は？",
    "コストが高いウェーハの特徴を分析してください",
    "品質改善のための推奨事項を教えてください"
};

AnsiConsole.MarkupLine("[bold yellow]サンプルクエリ:[/]");
for (int i = 0; i < sampleQueries.Length; i++)
{
    AnsiConsole.MarkupLine($"[cyan]{i + 1}.[/] {sampleQueries[i]}");
}
AnsiConsole.WriteLine();

if (args.Length > 0)
{
    var userInput = args[0];
    AnsiConsole.MarkupLine($"[dim]コマンドライン引数からの質問: {userInput}[/]");
    
    // Query the agent
    var response = await AnsiConsole.Status()
        .StartAsync("AI Agentが回答を生成中...", async ctx =>
        {
            ctx.Spinner(Spinner.Known.Dots);
            ctx.SpinnerStyle(Style.Parse("cyan"));
            return await agent.QueryAsync(userInput);
        });

    // Display response
    var panel = new Panel(response)
    {
        Header = new PanelHeader("[bold cyan]AI Agent回答[/]", Justify.Left),
        Border = BoxBorder.Rounded,
        BorderStyle = Style.Parse("cyan")
    };

    AnsiConsole.Write(panel);
    return;
}

// Interactive loop
while (true)
{
    var userInput = AnsiConsole.Ask<string>("[bold green]質問を入力してください[/] ([gray]'exit' で終了[/]): ");

    if (string.IsNullOrWhiteSpace(userInput) || userInput.ToLower() == "exit")
    {
        AnsiConsole.MarkupLine("[yellow]終了します...[/]");
        break;
    }

    // If user enters a number, use sample query
    if (int.TryParse(userInput, out int queryIndex) && queryIndex >= 1 && queryIndex <= sampleQueries.Length)
    {
        userInput = sampleQueries[queryIndex - 1];
        AnsiConsole.MarkupLine($"[dim]選択されたクエリ: {userInput}[/]");
    }

    AnsiConsole.WriteLine();

    // Query the agent
    var response = await AnsiConsole.Status()
        .StartAsync("AI Agentが回答を生成中...", async ctx =>
        {
            ctx.Spinner(Spinner.Known.Dots);
            ctx.SpinnerStyle(Style.Parse("cyan"));
            return await agent.QueryAsync(userInput);
        });

    // Display response
    var panel = new Panel(response)
    {
        Header = new PanelHeader("[bold cyan]AI Agent回答[/]", Justify.Left),
        Border = BoxBorder.Rounded,
        BorderStyle = Style.Parse("cyan")
    };

    AnsiConsole.Write(panel);
    AnsiConsole.WriteLine();
}
