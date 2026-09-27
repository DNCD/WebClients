import Foundation

/// `multipart/form-data` body, matching the web client's `serializeFormData` (used for sending mail
/// and uploading attachments). Binary values (`Data`) become file parts, like the web's Blobs.
struct MultipartForm {
    enum Value: Equatable {
        case text(String)
        case binary(Data)
    }

    let boundary: String
    private(set) var fields: [(name: String, value: Value)] = []

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func append(_ name: String, _ value: String) {
        fields.append((name, .text(value)))
    }

    mutating func append(_ name: String, data: Data) {
        fields.append((name, .binary(data)))
    }

    /// Flattens nested dictionaries into bracketed keys, like the web client's
    /// `serializeJsonToFormData`: `["Packages": ["text/plain": ["Type": 1]]]` → `Packages[text/plain][Type]=1`.
    mutating func appendNested(_ name: String, _ value: Any) {
        switch value {
        case let data as Data:
            append(name, data: data)
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
            switch field.value {
            case .text(let text):
                data.append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
                data.append(text)
            case .binary(let bytes):
                // The web client appends Blobs with the field name as filename.
                data.append("Content-Disposition: form-data; name=\"\(field.name)\"; filename=\"\(field.name)\"\r\n")
                data.append("Content-Type: application/octet-stream\r\n\r\n")
                data.append(bytes)
            }
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
