import Foundation

public enum CPAAPIError: Error, Equatable, LocalizedError {
    case invalidBaseURL
    case unsupportedScheme(String)
    case insecureHTTPHost(String)
    case invalidResponse
    case httpStatus(code: Int, message: String)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "服务器地址无效"
        case let .unsupportedScheme(scheme):
            return "不支持的地址协议: \(scheme)"
        case let .insecureHTTPHost(host):
            return "公网 HTTP 不安全，请使用 HTTPS 或局域网地址: \(host)"
        case .invalidResponse:
            return "服务器响应无效"
        case let .httpStatus(code, message):
            if message.isEmpty {
                return "请求失败: HTTP \(code)"
            }
            return "请求失败: HTTP \(code), \(message)"
        case let .decoding(message):
            return "数据解析失败: \(message)"
        case let .transport(message):
            return "网络请求失败: \(message)"
        }
    }
}

public struct CPAErrorEnvelope: Decodable, Equatable {
    public let error: String?
    public let message: String?
}
