import Foundation

nonisolated enum OCREngine: String, CaseIterable, Identifiable, Sendable {
    case appleVision, ai
    var id: Self { self }
    var name: String { self == .appleVision ? "Apple Vision · Free" : "AI OCR · Cloud" }
}

nonisolated enum TranslationEngine: String, CaseIterable, Identifiable, Sendable {
    case apple, ai
    var id: Self { self }
    var name: String { self == .apple ? "Apple Translation · Free" : "AI Translation · Cloud" }
}

nonisolated enum TranslationPreference: String, CaseIterable, Identifiable, Sendable {
    case speed, quality
    var id: Self { self }
    var name: String { self == .speed ? "Speed" : "Quality" }
}

nonisolated enum AIProfile: String, CaseIterable, Identifiable, Sendable {
    case ocr, translation
    var id: Self { self }
    var title: String { self == .ocr ? "AI OCR" : "AI Translation" }
}

/// Credentials deliberately do not belong to this Codable value.
nonisolated struct AIServiceConfiguration: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var requestOptions: AIRequestOptions? = nil

    /// Gemini's model listing can return resource names (models/foo), while
    /// its OpenAI-compatible chat endpoint requires the bare model ID.
    /// Do not strip namespaces used by OpenRouter or self-hosted endpoints.
    var isGoogleCompatibilityEndpoint: Bool {
        guard let url = try? endpoint() else { return false }
        return url.host?.lowercased() == "generativelanguage.googleapis.com"
            && ["/v1beta/openai/chat/completions", "/v1/openai/chat/completions"].contains(url.path)
    }

    func normalizedModelID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isGoogleCompatibilityEndpoint && trimmed.hasPrefix("models/") ? String(trimmed.dropFirst(7)) : trimmed
    }

    var requestModelID: String { normalizedModelID(model) }

    func endpoint() throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AIServiceError.invalidEndpoint
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = path.hasSuffix("chat/completions") ? "/" + path : "/" + [path, "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else { throw AIServiceError.invalidEndpoint }
        return url
    }

    func validate() throws {
        _ = try endpoint()
        _ = try requestOptions?.parameters()
        guard !requestModelID.isEmpty else {
            throw AIServiceError.missingModel
        }
    }

    func modelsEndpoint() throws -> URL {
        let chat = try endpoint()
        return chat.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
    }

    /// Consent is scoped to the exact destination and model, not just a boolean.
    var consentID: String {
        guard let endpoint = try? endpoint() else { return "" }
        return endpoint.absoluteString + "\n" + model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum AIServiceError: LocalizedError, Equatable {
    case invalidEndpoint, missingModel, invalidResponse, invalidRegions, incompleteTranslation
    case requestTooLarge, responseTooLarge, transport, http(Int), wrongTargetLanguage
    case outputTruncated, contentBlocked, emptyResponse

    /// Stable, content-free reason codes for on-device diagnostics.
    var diagnosticCode: String {
        switch self {
        case .http(let status): "http_\(status)"
        case .outputTruncated: "output_truncated"
        case .contentBlocked: "content_blocked"
        case .emptyResponse: "empty_response"
        case .invalidResponse: "invalid_json"
        case .invalidRegions: "invalid_regions"
        case .transport: "transport"
        default: "configuration_or_output"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Use an HTTPS Base URL without credentials, query parameters, or fragments. Include the provider’s API prefix, for example /v1."
        case .missingModel: "Enter a model name in the selected AI engine’s settings."
        case .invalidResponse: "The AI service did not return the requested JSON. Try another model or use Apple’s engine."
        case .outputTruncated: "The AI response reached its output limit. Increase the output token limit or reduce the thinking budget in Request Parameters."
        case .contentBlocked: "The AI provider declined this image or text. Its content restrictions cannot be changed by this app. Local recognition remains available."
        case .emptyResponse: "The AI service returned no text. Check that the selected model supports image input and the compatible API."
        case .invalidRegions: "The AI service returned invalid OCR regions. Local recognition is available as a fallback."
        case .incompleteTranslation: "The translation service omitted or duplicated text regions. Retry or choose a different translation engine."
        case .wrongTargetLanguage: "The model did not follow the selected target language. The original image is preserved. Choose another model or retry."
        case .requestTooLarge: "This screenshot contains too much text for one AI request. Use Apple’s engines or a smaller screenshot."
        case .responseTooLarge: "The AI service response exceeded the size limit. Try a smaller screenshot."
        case .transport: "Could not reach the AI service securely. Check the endpoint and your connection."
        case .http(401), .http(403): "The AI service rejected access. Check the API key and model permissions."
        case .http(429): "The AI service rate or usage limit was reached. Wait, or use Apple’s free engine."
        case .http(400), .http(404), .http(422): "The AI service rejected the model or request format. Check the model ID, image support and Request Parameters."
        case .http(let status): AppLocalization.formatted("The AI service returned HTTP %d. Retry or use Apple’s engine.", status)
        }
    }
}
