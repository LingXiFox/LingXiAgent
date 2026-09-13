import Foundation
import LingXiProtocol

/// 标准化的模型提供商与上游网关错误分类。
public enum ProviderErrorCategory: String, Sendable, Codable, Equatable, CaseIterable {
    // MARK: - 瞬态错误（可自动指数退避重试）
    /// HTTP 429 或 TPM/RPM 配额耗尽
    case rateLimited
    /// HTTP 503 / 529 提供商服务暂时过载
    case serverOverloaded
    /// HTTP 408 / 504 / 522 / 524 或首字等待超时
    case gatewayTimeout
    /// HTTP 502 / 520 / 521 / 523 网关或反向代理异常
    case badGateway
    /// HTTP 500 提供商服务内部错误
    case internalServerError
    /// 底层传输中断、连接重置、DNS 失败
    case networkFailure

    // MARK: - 永久性错误（不可重试，立即熔断）
    /// HTTP 401: API Key / Access Token 无效或已过期
    case authFailure
    /// HTTP 402 / insufficient_quota: 余额不足或额度耗尽
    case quotaExhausted
    /// HTTP 403: 访问被拒绝、区域限制或账号风控
    case accessForbidden
    /// HTTP 404 / model_not_found: 模型、接口或资源不存在
    case modelNotFound
    /// HTTP 405: 请求方法不支持
    case methodNotAllowed
    /// HTTP 409: 资源状态冲突
    case conflict
    /// HTTP 413: 请求体或上下文过大超出单次限制
    case payloadTooLarge
    /// HTTP 415: 媒体格式或 Content-Type 不支持
    case unsupportedMediaType
    /// HTTP 400 (context_length_exceeded): 模型上下文长度超限
    case contextExceeded
    /// HTTP 400 / 422: 参数错误或不符合接口 Schema
    case invalidRequest
    /// HTTP 423: 账号或资源被临时锁定
    case locked
    /// content_filter / safety: 触发安全审查与敏感词拦截
    case contentFiltered
    /// HTTP 501: 功能未实现
    case notImplemented
    /// 未知异常
    case unknown

    /// 是否属于瞬态可重试错误。
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverOverloaded, .gatewayTimeout, .badGateway, .internalServerError, .networkFailure:
            return true
        case .authFailure, .quotaExhausted, .accessForbidden, .modelNotFound, .methodNotAllowed,
             .conflict, .payloadTooLarge, .unsupportedMediaType, .contextExceeded, .invalidRequest,
             .locked, .contentFiltered, .notImplemented, .unknown:
            return false
        }
    }

    /// 用户可理解的中文诊断描述。
    public var userDescription: String {
        switch self {
        case .rateLimited:
            return "上游请求速率超限 (429)"
        case .serverOverloaded:
            return "上游服务暂时过载 (529/503)"
        case .gatewayTimeout:
            return "上游网关或响应超时 (504/408)"
        case .badGateway:
            return "上游网关异常 (502)"
        case .internalServerError:
            return "上游服务内部错误 (500)"
        case .networkFailure:
            return "网络连接中断或握手失败"
        case .authFailure:
            return "API Key / Access Token 无效或已过期 (401)"
        case .quotaExhausted:
            return "账户余额不足或额度耗尽 (402)"
        case .accessForbidden:
            return "访问被拒绝 (403)，可能是账号风控或区域限制"
        case .modelNotFound:
            return "模型或接口资源不存在 (404)"
        case .methodNotAllowed:
            return "HTTP 请求方法不支持 (405)"
        case .conflict:
            return "资源状态冲突 (409)"
        case .payloadTooLarge:
            return "请求体或上下文过大超出单次限制 (413)"
        case .unsupportedMediaType:
            return "媒体格式不支持 (415)"
        case .contextExceeded:
            return "模型上下文长度超限 (400)"
        case .invalidRequest:
            return "请求参数错误或不符合接口规范 (400/422)"
        case .locked:
            return "账号或资源被临时锁定 (423)"
        case .contentFiltered:
            return "触发提供商内容安全审查风控拦截"
        case .notImplemented:
            return "上游接口未实现此功能 (501)"
        case .unknown:
            return "上游模型服务异常"
        }
    }

    /// 针对永久熔断错误给用户的行动建议。
    public var suggestedAction: String? {
        switch self {
        case .authFailure:
            return "请检查提供商配置中的 API Key 是否有效或过期"
        case .quotaExhausted:
            return "请检查账户余额并前往服务商后台充值，或切换至其他可用模型"
        case .accessForbidden:
            return "请检查当前网络地区或账号权限设置"
        case .modelNotFound:
            return "请检查模型名称配置是否正确，或当前 API Key 是否有该模型权限"
        case .contextExceeded:
            return "上下文已达模型上限，请执行 /compact 压缩会话或新建会话"
        case .payloadTooLarge:
            return "单次输入内容过大，请精简输入或附件后重试"
        case .contentFiltered:
            return "请调整输入内容避免触碰提供商合规策略"
        case .invalidRequest:
            return "请求参数或工具调用定义不符合上游规范，请检查配置"
        case .locked:
            return "账号或资源被锁定，请登录服务商平台解锁"
        default:
            return nil
        }
    }
}

/// 标准化分类后的模型提供商错误。
public struct ClassifiedProviderError: Error, Sendable {
    public let category: ProviderErrorCategory
    public let statusCode: Int?
    public let errorType: String?
    public let serverMessage: String?
    public let retryAfter: Duration?
    public let underlying: Error?
    public let diagnostics: String?

    public init(
        category: ProviderErrorCategory,
        statusCode: Int? = nil,
        errorType: String? = nil,
        serverMessage: String? = nil,
        retryAfter: Duration? = nil,
        underlying: Error? = nil,
        diagnostics: String? = nil
    ) {
        self.category = category
        self.statusCode = statusCode
        self.errorType = errorType
        self.serverMessage = serverMessage
        self.retryAfter = retryAfter
        self.underlying = underlying
        self.diagnostics = diagnostics
    }

    /// 面向用户的清晰诊断概要。
    public var userFacingSummary: String {
        var parts: [String] = []
        if let code = statusCode {
            parts.append("[\(code)]")
        }
        parts.append(category.userDescription)
        if let msg = serverMessage, !msg.isEmpty {
            parts.append("· \(msg)")
        }
        if let action = category.suggestedAction {
            parts.append("(\(action))")
        }
        return parts.joined(separator: " ")
    }
}

/// 模型错误分类器。
public enum ProviderErrorClassifier {
    /// 对 HTTP 状态码、响应体及底层错误进行全面分类。
    public static func classify(
        statusCode: Int?,
        headers: [String: String] = [:],
        body: String? = nil,
        underlying: Error? = nil,
        diagnostics: String? = nil
    ) -> ClassifiedProviderError {
        let (extractedType, extractedMsg) = parseJSONError(body)
        let normalizedBody = (body ?? "").lowercased()
        let normalizedMsg = (extractedMsg ?? "").lowercased()
        let normalizedType = (extractedType ?? "").lowercased()
        let retry = parseRetryAfter(headers: headers, body: body)

        // 1. 优先根据明确的业务错误特征识别（即使 HTTP 状态码不标准也能精准识别）
        if isRateLimited(statusCode: statusCode, type: normalizedType, message: normalizedMsg, body: normalizedBody) {
            return ClassifiedProviderError(
                category: .rateLimited,
                statusCode: statusCode ?? 429,
                errorType: extractedType ?? "rate_limit_exceeded",
                serverMessage: extractedMsg,
                retryAfter: retry,
                underlying: underlying,
                diagnostics: diagnostics
            )
        }

        if isContextLengthExceeded(type: normalizedType, message: normalizedMsg, body: normalizedBody) {
            return ClassifiedProviderError(
                category: .contextExceeded,
                statusCode: statusCode ?? 400,
                errorType: extractedType ?? "context_length_exceeded",
                serverMessage: extractedMsg,
                retryAfter: nil,
                underlying: underlying,
                diagnostics: diagnostics
            )
        }

        if isQuotaExceeded(type: normalizedType, message: normalizedMsg, body: normalizedBody) {
            return ClassifiedProviderError(
                category: .quotaExhausted,
                statusCode: statusCode ?? 402,
                errorType: extractedType ?? "insufficient_quota",
                serverMessage: extractedMsg,
                retryAfter: nil,
                underlying: underlying,
                diagnostics: diagnostics
            )
        }

        if isContentFiltered(type: normalizedType, message: normalizedMsg, body: normalizedBody) {
            return ClassifiedProviderError(
                category: .contentFiltered,
                statusCode: statusCode ?? 400,
                errorType: extractedType ?? "content_filter",
                serverMessage: extractedMsg,
                retryAfter: nil,
                underlying: underlying,
                diagnostics: diagnostics
            )
        }

        if isModelNotFound(type: normalizedType, message: normalizedMsg, body: normalizedBody) {
            return ClassifiedProviderError(
                category: .modelNotFound,
                statusCode: statusCode ?? 404,
                errorType: extractedType ?? "model_not_found",
                serverMessage: extractedMsg,
                retryAfter: nil,
                underlying: underlying,
                diagnostics: diagnostics
            )
        }


        // 2. 根据标准 HTTP 状态码分类
        if let code = statusCode {
            switch code {
            case 400:
                return ClassifiedProviderError(
                    category: .invalidRequest,
                    statusCode: code,
                    errorType: extractedType,
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 401:
                return ClassifiedProviderError(
                    category: .authFailure,
                    statusCode: code,
                    errorType: extractedType ?? "unauthorized",
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 402:
                return ClassifiedProviderError(
                    category: .quotaExhausted,
                    statusCode: code,
                    errorType: extractedType ?? "payment_required",
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 403:
                return ClassifiedProviderError(
                    category: .accessForbidden,
                    statusCode: code,
                    errorType: extractedType ?? "forbidden",
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 404:
                return ClassifiedProviderError(
                    category: .modelNotFound,
                    statusCode: code,
                    errorType: extractedType ?? "not_found",
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 405:
                return ClassifiedProviderError(
                    category: .methodNotAllowed,
                    statusCode: code,
                    errorType: extractedType,
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 408:
                return ClassifiedProviderError(
                    category: .gatewayTimeout,
                    statusCode: code,
                    errorType: extractedType ?? "request_timeout",
                    serverMessage: extractedMsg,
                    retryAfter: retry,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 409:
                return ClassifiedProviderError(
                    category: .conflict,
                    statusCode: code,
                    errorType: extractedType,
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 413:
                return ClassifiedProviderError(
                    category: .payloadTooLarge,
                    statusCode: code,
                    errorType: extractedType ?? "payload_too_large",
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 415:
                return ClassifiedProviderError(
                    category: .unsupportedMediaType,
                    statusCode: code,
                    errorType: extractedType,
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 422:
                return ClassifiedProviderError(
                    category: .invalidRequest,
                    statusCode: code,
                    errorType: extractedType ?? "unprocessable_entity",
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 423:
                return ClassifiedProviderError(
                    category: .locked,
                    statusCode: code,
                    errorType: extractedType ?? "locked",
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 429:
                return ClassifiedProviderError(
                    category: .rateLimited,
                    statusCode: code,
                    errorType: extractedType ?? "rate_limit_exceeded",
                    serverMessage: extractedMsg,
                    retryAfter: retry,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 500:
                return ClassifiedProviderError(
                    category: .internalServerError,
                    statusCode: code,
                    errorType: extractedType ?? "internal_server_error",
                    serverMessage: extractedMsg,
                    retryAfter: retry,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 501:
                return ClassifiedProviderError(
                    category: .notImplemented,
                    statusCode: code,
                    errorType: extractedType,
                    serverMessage: extractedMsg,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 502, 520, 521, 523:
                return ClassifiedProviderError(
                    category: .badGateway,
                    statusCode: code,
                    errorType: extractedType ?? "bad_gateway",
                    serverMessage: extractedMsg,
                    retryAfter: retry,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 503, 529:
                return ClassifiedProviderError(
                    category: .serverOverloaded,
                    statusCode: code,
                    errorType: extractedType ?? "service_unavailable",
                    serverMessage: extractedMsg,
                    retryAfter: retry,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            case 504, 522, 524:
                return ClassifiedProviderError(
                    category: .gatewayTimeout,
                    statusCode: code,
                    errorType: extractedType ?? "gateway_timeout",
                    serverMessage: extractedMsg,
                    retryAfter: retry,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            default:
                if code >= 500 {
                    return ClassifiedProviderError(
                        category: .badGateway,
                        statusCode: code,
                        errorType: extractedType,
                        serverMessage: extractedMsg,
                        retryAfter: retry,
                        underlying: underlying,
                        diagnostics: diagnostics
                    )
                }
            }
        }

        // 3. 检查底层网络/传输错误
        if let underlying {
            let desc = underlying.localizedDescription.lowercased()
            if let coreErr = underlying as? CoreError {
                if coreErr.code == .commandTimedOut {
                    return ClassifiedProviderError(
                        category: .gatewayTimeout,
                        statusCode: 408,
                        errorType: "command_timed_out",
                        serverMessage: coreErr.message,
                        retryAfter: retry,
                        underlying: underlying,
                        diagnostics: diagnostics
                    )
                }
                if coreErr.code == .transportLost {
                    return ClassifiedProviderError(
                        category: .networkFailure,
                        statusCode: nil,
                        errorType: "transport_lost",
                        serverMessage: coreErr.message,
                        retryAfter: retry,
                        underlying: underlying,
                        diagnostics: diagnostics
                    )
                }
            }
            if desc.contains("timed out") || desc.contains("timeout") {
                return ClassifiedProviderError(
                    category: .gatewayTimeout,
                    statusCode: 408,
                    errorType: "timeout",
                    serverMessage: underlying.localizedDescription,
                    retryAfter: retry,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            }
            if desc.contains("connection reset") || desc.contains("network connection lost") || desc.contains("cannot connect") {
                return ClassifiedProviderError(
                    category: .networkFailure,
                    statusCode: nil,
                    errorType: "network_error",
                    serverMessage: underlying.localizedDescription,
                    retryAfter: retry,
                    underlying: underlying,
                    diagnostics: diagnostics
                )
            }
        }

        // 4. 兜底
        return ClassifiedProviderError(
            category: .unknown,
            statusCode: statusCode,
            errorType: extractedType,
            serverMessage: extractedMsg,
            retryAfter: retry,
            underlying: underlying,
            diagnostics: diagnostics
        )
    }

    // MARK: - 辅助特征识别

    private static func isContextLengthExceeded(type: String, message: String, body: String) -> Bool {
        type.contains("context_length_exceeded")
            || type.contains("context_window_exceeded")
            || message.contains("context length")
            || message.contains("maximum context length")
            || message.contains("context_length_exceeded")
            || message.contains("prompt is too long")
            || message.contains("tokens exceed")
            || body.contains("context_length_exceeded")
            || (body.contains("maximum context length") && body.contains("tokens"))
    }

    private static func isQuotaExceeded(type: String, message: String, body: String) -> Bool {
        guard !message.contains("rpm") && !message.contains("tpm") && !body.contains("rpm exhausted") && !body.contains("tpm exhausted") else {
            return false
        }
        return type.contains("insufficient_quota")
            || type.contains("quota_exceeded")
            || type.contains("credit_expired")
            || type.contains("billing_not_active")
            || message.contains("insufficient quota")
            || message.contains("exceeded your current quota")
            || message.contains("quota exceeded")
            || message.contains("balance insufficient")
            || message.contains("额度不足")
            || message.contains("余额不足")
            || message.contains("欠费")
            || body.contains("insufficient_quota")
    }

    private static func isContentFiltered(type: String, message: String, body: String) -> Bool {
        type.contains("content_filter")
            || type.contains("sensitive_content")
            || message.contains("content filter")
            || message.contains("safety system")
            || message.contains("moderation")
            || message.contains("合规")
            || message.contains("违规")
            || body.contains("content_filter")
    }

    private static func isModelNotFound(type: String, message: String, body: String) -> Bool {
        type.contains("model_not_found")
            || type.contains("model_not_exists")
            || message.contains("model does not exist")
            || message.contains("model not found")
            || message.contains("no such model")
            || (type.contains("invalid_request_error") && message.contains("model"))
    }

    private static func isRateLimited(statusCode: Int?, type: String, message: String, body: String) -> Bool {
        statusCode == 429
            || type.contains("rate_limit")
            || type.contains("rate_limit_exceeded")
            || type.contains("tpm_exhausted")
            || type.contains("rpm_exhausted")
            || message.contains("rate limit")
            || message.contains("too many requests")
            || message.contains("tpm exhausted")
            || message.contains("rpm exhausted")
            || message.contains("rpm limit")
            || message.contains("tpm limit")
            || body.contains("429001")
            || (body.contains("inference") && body.contains("tpm") && body.contains("exhaust"))
            || (body.contains("inference") && body.contains("rpm") && body.contains("exhaust"))
    }

    private static func parseJSONError(_ body: String?) -> (type: String?, message: String?) {
        guard let body, !body.isEmpty, let data = body.data(using: .utf8) else { return (nil, nil) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }

        if let errorObj = json["error"] as? [String: Any] {
            let type = errorObj["type"] as? String ?? errorObj["code"] as? String
            let message = errorObj["message"] as? String
            return (type, message)
        } else if let errorMsg = json["error"] as? String {
            return (nil, errorMsg)
        } else if let message = json["message"] as? String {
            let code = json["code"] as? String ?? (json["code"] as? Int).map(String.init)
            return (code, message)
        }
        return (nil, nil)
    }

    private static func parseRetryAfter(headers: [String: String], body: String?) -> Duration? {
        if let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After-Ms") == .orderedSame })?.value.trimmingCharacters(in: .whitespacesAndNewlines), let milliseconds = Double(value), milliseconds >= 0 {
            return .milliseconds(Int(milliseconds))
        }
        if let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let seconds = Double(value), seconds >= 0 { return .milliseconds(Int(seconds * 1_000)) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            if let date = formatter.date(from: value) {
                return .milliseconds(max(0, Int(date.timeIntervalSinceNow * 1_000)))
            }
        }
        return nil
    }
}
