import Foundation
import SwiftData

typealias ChatThread = PorchSchemaV6.ChatThread

enum ChatThreadMetadataBackfill {
    @discardableResult
    static func populateMissingLastMessagePreviews(in context: ModelContext) throws -> Int {
        let threads = try context.fetch(FetchDescriptor<ChatThread>())
        var backfilledCount = 0

        for thread in threads where thread.lastMessagePreview.isEmpty {
            let latestMessage = thread.messages.max { lhs, rhs in
                lhs.createdAt < rhs.createdAt
            }
            if thread.backfillLastMessagePreview(from: latestMessage) {
                backfilledCount += 1
            }
        }

        if backfilledCount > 0 {
            try context.save()
        }

        return backfilledCount
    }
}
