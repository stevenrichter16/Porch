import Foundation

enum ChatEditResendPolicy {
    static func requiresDiscardConfirmation(
        for messageID: UUID,
        in messages: [ChatMessage]
    ) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return false
        }

        return index < messages.index(before: messages.endIndex)
    }
}
