import Foundation

/// Optional so upgrading an existing service keeps the provider's own defaults.
nonisolated struct AIRequestOptions: Codable, Equatable, Sendable {
    var preset: AIParameterPreset = .modelDefault
    var bodyJSON = ""

    func parameters() throws -> [String: Any] {
        var result: [String: Any] = preset.parameters
        if !bodyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard bodyJSON.utf8.count <= 16_384,
                  let object = try? JSONSerialization.jsonObject(with: Data(bodyJSON.utf8)) as? [String: Any] else {
                throw AIParameterError.invalidJSON
            }
            // Preserve prompt/region integrity, one response and JSON decoding.
            let reserved: Set<String> = ["messages", "model", "stream", "n", "tools", "tool_choice", "functions", "function_call", "api_key", "authorization", "prompt", "instructions", "input", "target_language", "source_language", "language"]
            guard object.keys.allSatisfy({ !reserved.contains($0.lowercased()) }) else { throw AIParameterError.reservedField }
            result.merge(object) { _, custom in custom }
        }
        guard result["max_tokens"] == nil || result["max_completion_tokens"] == nil else { throw AIParameterError.conflictingTokenLimits }
        return result
    }
}

nonisolated enum AIParameterPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case modelDefault, openAINone, low, medium, high, deepSeekFast, deepSeekThinking, qwenFast, custom
    var id: Self { self }
    var name: String {
        switch self {
        case .modelDefault: "Model defaults"
        case .openAINone: "OpenAI · No reasoning"
        case .low: "Reasoning · Low"
        case .medium: "Reasoning · Medium"
        case .high: "Reasoning · High"
        case .deepSeekFast: "DeepSeek · Thinking off"
        case .deepSeekThinking: "DeepSeek · Thinking on"
        case .qwenFast: "Qwen · Thinking off"
        case .custom: "Custom JSON"
        }
    }
    var parameters: [String: Any] {
        switch self {
        case .modelDefault, .custom: [:]
        case .openAINone: ["reasoning_effort": "none"]
        case .low: ["reasoning_effort": "low"]
        case .medium: ["reasoning_effort": "medium"]
        case .high: ["reasoning_effort": "high"]
        case .deepSeekFast: ["thinking": ["type": "disabled"]]
        case .deepSeekThinking: ["thinking": ["type": "enabled"]]
        case .qwenFast: ["enable_thinking": false]
        }
    }
}

nonisolated enum AIParameterError: LocalizedError {
    case invalidJSON, reservedField, conflictingTokenLimits
    var errorDescription: String? {
        switch self {
        case .invalidJSON: "Enter a JSON object of at most 16 KB."
        case .reservedField: "Model, messages, stream, tools, credentials and response count are managed by the app."
        case .conflictingTokenLimits: "Use only one of max_tokens and max_completion_tokens."
        }
    }
}
