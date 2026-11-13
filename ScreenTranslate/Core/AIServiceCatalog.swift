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

    /// Providers that bill in either currency depending on the account: the
    /// user chooses. Everyone else bills in US dollars.
    var billsInYuanOrDollars: Bool { [.deepSeek, .qwen, .siliconFlow, .moonshot, .zhipu, .other].contains(self) }
    var defaultCurrency: String { [.deepSeek, .qwen, .siliconFlow, .moonshot, .zhipu].contains(self) ? "CNY" : "USD" }
}

nonisolated struct SavedAIService: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var preset: AIProviderPreset
    var configuration: AIServiceConfiguration
    var supportsVision: Bool
    /// Price per million tokens. Filled in from the provider when it
    /// publishes prices, otherwise entered by the user.
    var inputPrice: Double? = nil
    var outputPrice: Double? = nil
    /// "USD" or "CNY"; nil means the provider's usual currency.
    var currency: String? = nil
    /// Monthly spending limit in that currency; nil when the limit is off.
    var spendLimit: Double? = nil

    var price: AIPrice? {
        guard let inputPrice, let outputPrice, inputPrice >= 0, outputPrice >= 0, inputPrice + outputPrice > 0 else { return nil }
        return AIPrice(input: inputPrice, output: outputPrice)
    }
    var billingCurrency: String { preset.billsInYuanOrDollars ? (currency ?? preset.defaultCurrency) : "USD" }
    var currencySymbol: String { billingCurrency == "CNY" ? "¥" : "$" }

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
    /// The order services are tried in for each job. The first one is used;
    /// a later one takes over when an earlier one fails or reaches its
    /// spending limit; the on-device engine is always the last resort.
    private(set) var ocrChain: [UUID] = []
    private(set) var translationChain: [UUID] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case services, ocrServiceID, translationServiceID, ocrChain, translationChain }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        services = try values.decodeIfPresent([SavedAIService].self, forKey: .services) ?? []
        // Versions before the ordered list stored one service per job.
        let ocr = try values.decodeIfPresent([UUID].self, forKey: .ocrChain) ?? (try values.decodeIfPresent(UUID.self, forKey: .ocrServiceID)).map { [$0] } ?? []
        let translation = try values.decodeIfPresent([UUID].self, forKey: .translationChain) ?? (try values.decodeIfPresent(UUID.self, forKey: .translationServiceID)).map { [$0] } ?? []
        ocrChain = Self.cleaned(ocr, services: services, vision: true)
        translationChain = Self.cleaned(translation, services: services, vision: false)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(services, forKey: .services)
        try values.encode(ocrChain, forKey: .ocrChain)
        try values.encode(translationChain, forKey: .translationChain)
        // Still written so an older version on another device keeps working.
        try values.encodeIfPresent(ocrChain.first, forKey: .ocrServiceID)
        try values.encodeIfPresent(translationChain.first, forKey: .translationServiceID)
    }

    private static func cleaned(_ ids: [UUID], services: [SavedAIService], vision: Bool) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { id in
            guard let service = services.first(where: { $0.id == id }), !vision || service.supportsVision else { return false }
            return seen.insert(id).inserted
        }
    }

    func chain(for profile: AIProfile) -> [SavedAIService] {
        (profile == .ocr ? ocrChain : translationChain).compactMap { id in services.first { $0.id == id } }
    }

    /// The first service of the order: the one normally used.
    func selected(for profile: AIProfile) -> SavedAIService? { chain(for: profile).first }

    mutating func upsert(_ service: SavedAIService) throws {
        try service.validate()
        if let index = services.firstIndex(where: { $0.id == service.id }) { services[index] = service }
        else { services.append(service) }
        if !service.supportsVision { ocrChain.removeAll { $0 == service.id } }
    }

    mutating func setChain(_ ids: [UUID], for profile: AIProfile) throws {
        for id in ids {
            guard let service = services.first(where: { $0.id == id }) else { throw ServiceCatalogError.serviceMissing }
            guard profile != .ocr || service.supportsVision else { throw ServiceCatalogError.visionUnsupported }
        }
        let cleaned = Self.cleaned(ids, services: services, vision: profile == .ocr)
        if profile == .ocr { ocrChain = cleaned } else { translationChain = cleaned }
    }

    /// Use exactly this service (or only the on-device engine for nil).
    mutating func select(_ id: UUID?, for profile: AIProfile) throws {
        try setChain(id.map { [$0] } ?? [], for: profile)
    }

    mutating func remove(_ id: UUID) {
        services.removeAll { $0.id == id }
        ocrChain.removeAll { $0 == id }
        translationChain.removeAll { $0 == id }
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
