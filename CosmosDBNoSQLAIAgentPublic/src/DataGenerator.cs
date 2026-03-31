using Microsoft.Azure.Cosmos;
using Azure.Identity;
using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace CosmosDBNoSQLAIAgent;

public class DesignData
{
    public string id { get; set; } = string.Empty;
    public string designId { get; set; } = string.Empty;
    public string designName { get; set; } = string.Empty;
    public string designer { get; set; } = string.Empty;
    public string processNode { get; set; } = string.Empty;
    public int drcErrors { get; set; }
    public int lvsErrors { get; set; }
    public double powerConsumption { get; set; }
    public double frequency { get; set; }
    public double dieArea { get; set; }
    public long gateCount { get; set; }
    public double clockFrequency { get; set; }
    public int designHours { get; set; }
    public double completionRate { get; set; }
    public double testCoverage { get; set; }
    public double designEfficiency { get; set; }
    public int revisionNumber { get; set; }
    public string status { get; set; } = string.Empty;
    public DateTime createdDate { get; set; }
    public DateTime lastModified { get; set; }
}

public class ManufacturingData
{
    public string id { get; set; } = string.Empty;
    public string waferId { get; set; } = string.Empty;
    public string waferLot { get; set; } = string.Empty;
    public string lotNumber { get; set; } = string.Empty;
    public string designId { get; set; } = string.Empty;
    public string processStep { get; set; } = string.Empty;
    public string equipment { get; set; } = string.Empty;
    public double yield { get; set; }
    public int defectCount { get; set; }
    public int totalDies { get; set; }
    public int goodDies { get; set; }
    public double cycleTime { get; set; }
    public double waferCost { get; set; }
    public double defectDensity { get; set; }
    public double processTemperature { get; set; }
    public double throughput { get; set; }
    public int reworkCount { get; set; }
    public double oeeScore { get; set; }
    public string status { get; set; } = string.Empty;
    public DateTime productionDate { get; set; }
    public DateTime inspectionDate { get; set; }
}

public class DataGenerator
{
    private readonly CosmosClient _client;
    private readonly Database _database;
    private readonly Random _random = new Random();

    private readonly string[] _designers = { "Tanaka", "Suzuki", "Yamada", "Watanabe", "Ito", "Nakamura", "Kobayashi", "Kato", "Yoshida", "Yamamoto" };
    private readonly string[] _processNodes = { "3nm", "5nm", "7nm", "10nm", "14nm" };
    private readonly string[] _statuses = { "Complete", "InProgress", "Testing", "Review", "Approved" };
    private readonly string[] _processSteps = { "Lithography", "Etching", "Deposition", "Ion Implantation", "CMP", "Inspection", "Testing" };
    private readonly string[] _equipments = { "ASML-EUV-001", "TEL-Etcher-002", "AMAT-CVD-003", "LAM-RIE-004", "KLA-Inspector-005" };

    public DataGenerator(string cosmosEndpoint)
    {
        var credential = new DefaultAzureCredential();
        _client = new CosmosClient(cosmosEndpoint, credential);
        _database = _client.GetDatabase("semicon");
    }

    public async Task DeleteAllDataAsync()
    {
        Console.WriteLine("Deleting all existing data...");
        
        // Delete DesignData
        var designContainer = _database.GetContainer("designs");
        await DeleteContainerDataAsync(designContainer, "DesignData");
        
        // Delete ManufacturingData
        var mfgContainer = _database.GetContainer("manufacturing");
        await DeleteContainerDataAsync(mfgContainer, "ManufacturingData");
        
        Console.WriteLine("All data deleted successfully!");
    }

    private async Task DeleteContainerDataAsync(Container container, string containerName)
    {
        var query = "SELECT c.id, c.designId FROM c";
        if (containerName == "ManufacturingData")
        {
            query = "SELECT c.id, c.waferLot FROM c";
        }

        var iterator = container.GetItemQueryIterator<dynamic>(query);
        int deleteCount = 0;

        while (iterator.HasMoreResults)
        {
            var response = await iterator.ReadNextAsync();
            foreach (var item in response)
            {
                string id = item.id;
                string partitionKey = containerName == "ManufacturingData" ? item.waferLot : item.designId;
                
                try
                {
                    await container.DeleteItemAsync<dynamic>(id, new PartitionKey(partitionKey));
                    deleteCount++;
                    
                    if (deleteCount % 100 == 0)
                    {
                        Console.WriteLine($"  Deleted {deleteCount} items from {containerName}...");
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"  Warning: Failed to delete item {id}: {ex.Message}");
                }
            }
        }

        Console.WriteLine($"  Total deleted from {containerName}: {deleteCount} items");
    }

    public async Task GenerateDesignDataAsync(int count = 1000)
    {
        Console.WriteLine($"\nGenerating {count} design records...");
        var container = _database.GetContainer("designs");
        
        for (int i = 1; i <= count; i++)
        {
            var designId = $"IC-2024-{i:D5}";
            var design = new DesignData
            {
                id = Guid.NewGuid().ToString(),
                designId = designId,
                designName = $"SemiconductorChip_{i}",
                designer = _designers[_random.Next(_designers.Length)],
                processNode = _processNodes[_random.Next(_processNodes.Length)],
                drcErrors = _random.Next(0, 100),
                lvsErrors = _random.Next(0, 80),
                powerConsumption = Math.Round(_random.NextDouble() * 5 + 1, 2), // 1-6W
                frequency = Math.Round(_random.NextDouble() * 4 + 1, 2), // 1-5 GHz
                dieArea = Math.Round(_random.NextDouble() * 95 + 5, 2), // 5-100 mm²
                gateCount = _random.Next(100000, 10000000),
                clockFrequency = _random.Next(500, 5000), // MHz
                designHours = _random.Next(500, 2500),
                completionRate = Math.Round(_random.NextDouble() * 50 + 50, 2), // 50-100%
                testCoverage = Math.Round(_random.NextDouble() * 30 + 70, 2), // 70-100%
                designEfficiency = Math.Round(_random.NextDouble() * 0.3 + 0.7, 2), // 0.7-1.0
                revisionNumber = _random.Next(1, 10),
                status = _statuses[_random.Next(_statuses.Length)],
                createdDate = DateTime.UtcNow.AddDays(-_random.Next(1, 365)),
                lastModified = DateTime.UtcNow.AddDays(-_random.Next(0, 30))
            };

            await container.CreateItemAsync(design, new PartitionKey(design.designId));

            if (i % 100 == 0)
            {
                Console.WriteLine($"  Created {i}/{count} design records...");
            }
        }

        Console.WriteLine($"Successfully created {count} design records!");
    }

    public async Task GenerateManufacturingDataAsync(int count = 1000)
    {
        Console.WriteLine($"\nGenerating {count} manufacturing records...");
        var container = _database.GetContainer("manufacturing");
        
        for (int i = 1; i <= count; i++)
        {
            var waferId = $"W-2024-{i:D6}";
            var waferLot = $"LOT-2024-{_random.Next(1, 100):D3}";
            var yieldRate = Math.Round(_random.NextDouble() * 15 + 85, 2); // 85-100%
            var totalDies = _random.Next(700, 1100);
            var goodDies = (int)(totalDies * yieldRate / 100);
            
            var mfgData = new ManufacturingData
            {
                id = Guid.NewGuid().ToString(),
                waferId = waferId,
                waferLot = waferLot,
                lotNumber = waferLot,
                designId = $"IC-2024-{_random.Next(1, 1000):D5}",
                processStep = _processSteps[_random.Next(_processSteps.Length)],
                equipment = _equipments[_random.Next(_equipments.Length)],
                yield = yieldRate,
                defectCount = totalDies - goodDies,
                totalDies = totalDies,
                goodDies = goodDies,
                cycleTime = Math.Round(_random.NextDouble() * 60 + 20, 2), // 20-80 hours
                waferCost = Math.Round(_random.NextDouble() * 4000 + 1000, 2), // 1000-5000 USD
                defectDensity = Math.Round(_random.NextDouble() * 49 + 1, 2), // 1-50 defects/cm²
                processTemperature = Math.Round(_random.NextDouble() * 400 + 800, 2), // 800-1200°C
                throughput = Math.Round(_random.NextDouble() * 40 + 10, 2), // 10-50 wafers/hour
                reworkCount = _random.Next(0, 6),
                oeeScore = Math.Round(_random.NextDouble() * 25 + 75, 2), // 75-100%
                status = _statuses[_random.Next(_statuses.Length)],
                productionDate = DateTime.UtcNow.AddDays(-_random.Next(1, 180)),
                inspectionDate = DateTime.UtcNow.AddDays(-_random.Next(0, 30))
            };

            await container.CreateItemAsync(mfgData, new PartitionKey(mfgData.waferLot));

            if (i % 100 == 0)
            {
                Console.WriteLine($"  Created {i}/{count} manufacturing records...");
            }
        }

        Console.WriteLine($"Successfully created {count} manufacturing records!");
    }
}
