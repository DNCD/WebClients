import Foundation

/// `multipart/form-data` body, matching the web client's `serializeFormData` (used for sending mail).
struct MultipartForm {
    let boundary: String
    private(set) var fields: [(name: String, value: String)] = []

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func append(_ name: String, _ value: String) {
        fields.append((name, value))
    }

    /// Flattens nested dictionaries into bracketed keys, like the web client's
    /// `serializeJsonToFormData`: `["Packages": ["text/plain": ["Type": 1]]]` → `Packages[text/plain][Type]=1`.
    mutating func appendNested(_ name: String, _ value: Any) {
        switch value {
        case let dict as [String: Any]:
            for key in dict.keys.sorted() {
                appendNested("\(name)[\(key)]", dict[key]!)
            }
        case let bool as Bool:
            append(name, bool ? "1" : "0")
        default:
            append(name, "\(value)")
        }
    }

    func encoded() -> Data {
        var data = Data()
        for field in fields {
            data.append("--\(boundary)\r\n")
            data.append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            data.append(field.value)
            data.append("\r\n")
        }
        data.append("--\(boundary)--\r\n")
        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
