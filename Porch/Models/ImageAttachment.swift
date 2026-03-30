import Foundation
#if canImport(UIKit)
import UIKit
#endif

struct ImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let imageData: Data
    let mimeType: String
    #if canImport(UIKit)
    let thumbnail: UIImage?
    #endif

    var base64Encoded: String {
        imageData.base64EncodedString()
    }

    var dataURL: String {
        "data:\(mimeType);base64,\(base64Encoded)"
    }

    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }
}
