using SemiconductorAIAgentSQL;
using Spectre.Console;

AnsiConsole.MarkupLine("[bold cyan]╔════════════════════════════════════════════════════════╗[/]");
AnsiConsole.MarkupLine("[bold cyan]║  Semiconductor AI Agent (Direct Query)                 ║[/]");
AnsiConsole.MarkupLine("[bold cyan]║  Cosmos DB NoSQL + Azure OpenAI GPT-4o                 ║[/]");
AnsiConsole.MarkupLine("[bold cyan]╚════════════════════════════════════════════════════════╝[/]");
AnsiConsole.WriteLine();

var cosmosEndpoint = Environment.GetEnvironmentVariable("COSMOS_ENDPOINT");
var openAIEndpoint = Environment.GetEnvironmentVariable("OPENAI_ENDPOINT");

if (string.IsNullOrEmpty(cosmosEndpoint))
{
    AnsiConsole.MarkupLine("[red]エラー: COSMOS_ENDPOINT 環境変数が設定されていません[/]");
    AnsiConsole.MarkupLine("[gray]例: $env:COSMOS_ENDPOINT = \"https://your-cosmos-account.documents.azure.com:443/\"[/]");
    return;
}

if (string.IsNullOrEmpty(openAIEndpoint))
{
    AnsiConsole.MarkupLine("[red]エラー: OPENAI_ENDPOINT 環境変数が設定されていません[/]");
    AnsiConsole.MarkupLine("[gray]例: $env:OPENAI_ENDPOINT = \"https://your-openai-account.openai.azure.com/\"[/]");
    return;
}

AnsiConsole.Status()
    .Start("初期化中...", ctx =>
    {
        ctx.Spinner(Spinner.Known.Dots);
        ctx.SpinnerStyle(Style.Parse("cyan"));
        Thread.Sleep(1000);
    });

var agent = new SemiconductorAIAgent(cosmosEndpoint, openAIEndpoint, "gpt-4o");

AnsiConsole.MarkupLine("[green]✓[/] AI Agent初期化完了");
AnsiConsole.MarkupLine($"[dim]Cosmos DB: {cosmosEndpoint}[/]");
AnsiConsole.MarkupLine($"[dim]OpenAI: {openAIEndpoint}[/]");
AnsiConsole.WriteLine();

var sampleQueries = new[]
{
    "DRCエラーが最も多い設計のDesignIDと件数を教えてください",
    "歩留まり率が90%以下のウェハを教えてください",
    "設計データの統計情報を教えてください",
    "消費電力が最も高い設計は？",
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

    var response = await AnsiConsole.Status()
        .StartAsync("Cosmos DBからデータ取得＆AI分析中...", async ctx =>
        {
            ctx.Spinner(Spinner.Known.Dots);
            ctx.SpinnerStyle(Style.Parse("cyan"));
            return await agent.QueryAsync(userInput);
        });

    var panel = new Panel(response)
    {
        Header = new PanelHeader("[bold cyan]AI Agent回答[/]", Justify.Left),
        Border = BoxBorder.Rounded,
        BorderStyle = Style.Parse("cyan")
    };
    AnsiConsole.Write(panel);
    return;
}

while (true)
{
    var userInput = AnsiConsole.Ask<string>("[bold green]質問を入力してください[/] ([gray]'exit' で終了[/]): ");

    if (string.IsNullOrWhiteSpace(userInput) || userInput.ToLower() == "exit")
    {
        AnsiConsole.MarkupLine("[yellow]終了します...[/]");
        break;
    }

    if (int.TryParse(userInput, out int queryIndex) && queryIndex >= 1 && queryIndex <= sampleQueries.Length)
    {
        userInput = sampleQueries[queryIndex - 1];
        AnsiConsole.MarkupLine($"[dim]選択されたクエリ: {userInput}[/]");
    }

    AnsiConsole.WriteLine();

    var response = await AnsiConsole.Status()
        .StartAsync("Cosmos DBからデータ取得＆AI分析中...", async ctx =>
        {
            ctx.Spinner(Spinner.Known.Dots);
            ctx.SpinnerStyle(Style.Parse("cyan"));
            return await agent.QueryAsync(userInput);
        });

    var panel = new Panel(response)
    {
        Header = new PanelHeader("[bold cyan]AI Agent回答[/]", Justify.Left),
        Border = BoxBorder.Rounded,
        BorderStyle = Style.Parse("cyan")
    };
    AnsiConsole.Write(panel);
    AnsiConsole.WriteLine();
}
