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
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Use an HTTPS Base URL without credentials, query parameters, or fragments. Include the provider’s API prefix, for example /v1."
        case .missingModel: "Enter a model name in the selected AI engine’s settings."
        case .invalidResponse: "The AI service did not return the requested JSON. Try another model or use Apple’s engine."
        case .invalidRegions: "The AI service returned invalid OCR regions. Local recognition is available as a fallback."
        case .incompleteTranslation: "The translation service omitted or duplicated text regions. Retry or choose a different translation engine."
        case .wrongTargetLanguage: "The model did not follow the selected target language. The original image is preserved. Choose another model or retry."
        case .requestTooLarge: "This screenshot contains too much text for one AI request. Use Apple’s engines or a smaller screenshot."
        case .responseTooLarge: "The AI service response exceeded the size limit. Try a smaller screenshot."
        case .transport: "Could not reach the AI service securely. Check the endpoint and your connection."
        case .http(401), .http(403): "The AI service rejected access. Check the API key and model permissions."
        case .http(429): "The AI service rate or usage limit was reached. Wait, or use Apple’s free engine."
        case .http(let status): AppLocalization.formatted("The AI service returned HTTP %d. Retry or use Apple’s engine.", status)
        }
    }
}
