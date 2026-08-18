import Foundation

// MARK: - Azure Provider

/// Microsoft Azure cloud provider implementation
struct AzureProvider: CloudProvider {
    nonisolated static let providerID = "azure"
    nonisolated static let displayName = "Microsoft Azure"
    nonisolated static let iconName = "cloud.fill"
    nonisolated static let logoImageName: String? = "AzureLogo"

    nonisolated static let supportedAuthMethods: [CloudAuthMethod] = [.azureDeviceCode]

    nonisolated static let capabilities: Set<CloudProviderCapability> = [
        .virtualMachines,
        .kubernetes
    ]

    static func createAPIClient(credentials: CloudCredentials) -> any CloudProviderAPIClient {
        AzureAPIClient(credentials: credentials)
    }

    // MARK: - Azure Regions

    /// Azure region definition
    struct Region: Identifiable, Hashable {
        let id: String
        let name: String
        let description: String

        var displayName: String {
            "\(name) (\(description))"
        }
    }

    /// Common Azure regions (not exhaustive)
    static let regions: [Region] = [
        // US Regions
        Region(id: "eastus", name: "East US", description: "Virginia"),
        Region(id: "eastus2", name: "East US 2", description: "Virginia"),
        Region(id: "westus", name: "West US", description: "California"),
        Region(id: "westus2", name: "West US 2", description: "Washington"),
        Region(id: "westus3", name: "West US 3", description: "Arizona"),
        Region(id: "centralus", name: "Central US", description: "Iowa"),
        Region(id: "northcentralus", name: "North Central US", description: "Illinois"),
        Region(id: "southcentralus", name: "South Central US", description: "Texas"),
        Region(id: "westcentralus", name: "West Central US", description: "Wyoming"),

        // Canada
        Region(id: "canadacentral", name: "Canada Central", description: "Toronto"),
        Region(id: "canadaeast", name: "Canada East", description: "Quebec City"),

        // Europe
        Region(id: "northeurope", name: "North Europe", description: "Ireland"),
        Region(id: "westeurope", name: "West Europe", description: "Netherlands"),
        Region(id: "uksouth", name: "UK South", description: "London"),
        Region(id: "ukwest", name: "UK West", description: "Cardiff"),
        Region(id: "germanywestcentral", name: "Germany West Central", description: "Frankfurt"),
        Region(id: "francecentral", name: "France Central", description: "Paris"),
        Region(id: "switzerlandnorth", name: "Switzerland North", description: "Zurich"),
        Region(id: "norwayeast", name: "Norway East", description: "Oslo"),
        Region(id: "swedencentral", name: "Sweden Central", description: "Gävle"),

        // Asia Pacific
        Region(id: "eastasia", name: "East Asia", description: "Hong Kong"),
        Region(id: "southeastasia", name: "Southeast Asia", description: "Singapore"),
        Region(id: "japaneast", name: "Japan East", description: "Tokyo"),
        Region(id: "japanwest", name: "Japan West", description: "Osaka"),
        Region(id: "koreacentral", name: "Korea Central", description: "Seoul"),
        Region(id: "koreasouth", name: "Korea South", description: "Busan"),
        Region(id: "centralindia", name: "Central India", description: "Pune"),
        Region(id: "southindia", name: "South India", description: "Chennai"),

        // Australia
        Region(id: "australiaeast", name: "Australia East", description: "Sydney"),
        Region(id: "australiasoutheast", name: "Australia Southeast", description: "Melbourne"),
        Region(id: "australiacentral", name: "Australia Central", description: "Canberra"),

        // South America
        Region(id: "brazilsouth", name: "Brazil South", description: "São Paulo"),

        // Middle East & Africa
        Region(id: "uaenorth", name: "UAE North", description: "Dubai"),
        Region(id: "southafricanorth", name: "South Africa North", description: "Johannesburg")
    ]

    /// Get display name for a region ID
    static func regionDisplayName(for regionID: String) -> String {
        if let region = regions.first(where: { $0.id == regionID }) {
            return region.displayName
        }
        return regionID
    }

    // MARK: - Help Text

    static let deviceCodeHelpText = """
    Sign in with your Microsoft work or school account. You'll be given a code \
    to enter at microsoft.com/devicelogin.
    """

    static let deviceCodeVerificationURL = URL(string: "https://microsoft.com/devicelogin")!
}
