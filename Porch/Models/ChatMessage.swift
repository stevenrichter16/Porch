import Foundation
import SwiftData

typealias ChatMessage = PorchSchemaV6.ChatMessage

enum ChatMessageQueries {
    static func sortedDescriptor(for chatID: UUID) -> FetchDescriptor<ChatMessage> {
        FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { message in
                message.thread?.id == chatID
            },
            sortBy: [SortDescriptor(\ChatMessage.createdAt, order: .forward)]
        )
    }

    static func latestDescriptor(for chatID: UUID) -> FetchDescriptor<ChatMessage> {
        var descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate<ChatMessage> { message in
                message.thread?.id == chatID
            },
            sortBy: [SortDescriptor(\ChatMessage.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return descriptor
    }

    static func fetchSortedMessages(for chat: ChatThread, in context: ModelContext) throws -> [ChatMessage] {
        try context.fetch(sortedDescriptor(for: chat.id))
    }

    static func fetchLatestMessage(for chat: ChatThread, in context: ModelContext) throws -> ChatMessage? {
        try context.fetch(latestDescriptor(for: chat.id)).first
    }
}
