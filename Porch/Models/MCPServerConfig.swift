import Foundation

struct MCPServerConfig: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var url: String
    var authorizationHeader: String?
    var isEnabled: Bool

    init(name: String, url: String, authorizationHeader: String? = nil, isEnabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.url = url
        self.authorizationHeader = authorizationHeader
        self.isEnabled = isEnabled
    }
}

extension PorchSchemaV7.AppSettings {
    private static let configDecoder = JSONDecoder()
    private static let configEncoder = JSONEncoder()

    var mcpServerConfigs: [MCPServerConfig] {
        get {
            guard let data = mcpServerConfigsData else { return [] }
            return (try? Self.configDecoder.decode([MCPServerConfig].self, from: data)) ?? []
        }
        set {
            mcpServerConfigsData = try? Self.configEncoder.encode(newValue)
        }
    }
}
