import Foundation

struct RemoteModel: Codable, Identifiable, Hashable {
    var id: String
    var ownedBy: String?
}
