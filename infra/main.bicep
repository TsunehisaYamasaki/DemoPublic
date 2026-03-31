// Azure Cosmos DB for NoSQL - Semiconductor Manufacturing Demo
// This demo showcases NoSQL document storage for design and manufacturing KPI data

targetScope = 'resourceGroup'

@description('Location for all resources')
param location string = 'eastus2'

@description('Cosmos DB account name')
param cosmosAccountName string = 'cosmos-semiconductor-${uniqueString(resourceGroup().id)}'

@description('Administrator user principal ID for RBAC')
param adminPrincipalId string

// Cosmos DB Account for NoSQL API
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: false
    enableMultipleWriteLocations: false
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    disableKeyBasedMetadataWriteAccess: false
    disableLocalAuth: false
  }
}

// NoSQL Database
resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmosAccount
  name: 'semicon'
  properties: {
    resource: {
      id: 'semicon'
    }
  }
}

// Container for Design Department - IC Design Information
resource designsContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: 'designs'
  properties: {
    resource: {
      id: 'designs'
      partitionKey: {
        paths: ['/designId']
        kind: 'Hash'
      }
    }
    options: {
      throughput: 400
    }
  }
}

// Container for Manufacturing Department - Production Information
resource manufacturingContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: 'manufacturing'
  properties: {
    resource: {
      id: 'manufacturing'
      partitionKey: {
        paths: ['/waferLot']
        kind: 'Hash'
      }
    }
    options: {
      throughput: 400
    }
  }
}

// RBAC Role Assignment - Cosmos DB Built-in Data Contributor
resource roleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, adminPrincipalId, 'contributor')
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: adminPrincipalId
    scope: cosmosAccount.id
  }
}

// Outputs
output cosmosAccountName string = cosmosAccount.name
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint
output databaseName string = database.name
output designsContainerName string = designsContainer.name
output manufacturingContainerName string = manufacturingContainer.name
