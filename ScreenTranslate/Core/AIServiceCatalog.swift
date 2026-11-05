import Foundation

@MainActor
protocol APIKeyStoring {
    func read(_ profile: APIKeySlot) throws -> String
    func save(_ key: String, for profile: APIKeySlot) throws
}

/// All presets use the vendor's documented OpenAI-compatible endpoint.
/// Model IDs remain editable: availability changes independently of the app.
nonisolated enum AIProviderPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepSeek, gemini, openAI, qwen, siliconFlow, moonshot, zhipu, openRouter, other
    var id: Self { self }

    var name: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        case .qwen: "通义千问"
        case .siliconFlow: "硅基流动"
        case .moonshot: "月之暗面 · Kimi"
        case .zhipu: "智谱 · GLM"
        case .openRouter: "OpenRouter"
        case .other: "OpenAI（其他）"
        }
    }

    var baseURL: String {
        switch self {
        case .deepSeek: "https://api.deepseek.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openAI, .other: "https://api.openai.com/v1"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .siliconFlow: "https://api.siliconflow.cn/v1"
        case .moonshot: "https://api.moonshot.cn/v1"
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
        case .openRouter: "https://openrouter.ai/api/v1"
        }
    }

    var supportsVision: Bool { self != .deepSeek }
}

nonisolated struct SavedAIService: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var preset: AIProviderPreset
    var configuration: AIServiceConfiguration
    var supportsVision: Bool

    init(id: UUID = UUID(), name: String? = nil, preset: AIProviderPreset = .other, configuration: AIServiceConfiguration? = nil, supportsVision: Bool? = nil) {
        self.id = id
        self.name = name ?? preset.name
        self.preset = preset
        self.configuration = configuration ?? AIServiceConfiguration(baseURL: preset.baseURL)
        self.supportsVision = supportsVision ?? preset.supportsVision
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceCatalogError.missingName }
        try configuration.validate()
    }

    var consentID: String { id.uuidString + "\n" + configuration.consentID }
}

nonisolated struct AIServiceCatalog: Codable, Equatable, Sendable {
    private(set) var services: [SavedAIService] = []
    private(set) var ocrServiceID: UUID?
    private(set) var translationServiceID: UUID?

    func selected(for profile: AIProfile) -> SavedAIService? {
        let id = profile == .ocr ? ocrServiceID : translationServiceID
        return services.first { $0.id == id }
    }

    mutating func upsert(_ service: SavedAIService) throws {
        try service.validate()
        if let index = services.firstIndex(where: { $0.id == service.id }) { services[index] = service }
        else { services.append(service) }
        if ocrServiceID == service.id && !service.supportsVision { ocrServiceID = nil }
    }

    mutating func select(_ id: UUID?, for profile: AIProfile) throws {
        if let id {
            guard let service = services.first(where: { $0.id == id }) else { throw ServiceCatalogError.serviceMissing }
            guard profile != .ocr || service.supportsVision else { throw ServiceCatalogError.visionUnsupported }
        }
        if profile == .ocr { ocrServiceID = id } else { translationServiceID = id }
    }

    mutating func remove(_ id: UUID) {
        services.removeAll { $0.id == id }
        if ocrServiceID == id { ocrServiceID = nil }
        if translationServiceID == id { translationServiceID = nil }
    }
}

nonisolated enum ServiceCatalogError: LocalizedError {
    case missingName, serviceMissing, visionUnsupported
    var errorDescription: String? {
        switch self {
        case .missingName: "Enter a name for this service."
        case .serviceMissing: "Add and select an AI service first."
        case .visionUnsupported: "This service is configured for text only. Select a vision-capable model for OCR."
        }
    }
}

nonisolated enum APIKeySlot: Hashable, Sendable {
    // Legacy slots are kept only to migrate credentials from the previous version.
    case ocr, translation, service(UUID), sharedPreferences, processingDiagnostics(String)
    var account: String {
        switch self {
        case .ocr: "ocr"
        case .translation: "translation"
        case .service(let id): "service." + id.uuidString
        case .sharedPreferences: "shared-preferences.v1"
        case .processingDiagnostics(let context): "processing-diagnostics.v1." + context
        }
    }
}
