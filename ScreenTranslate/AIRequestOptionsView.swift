import SwiftUI

struct AIRequestOptionsView: View {
    @Binding var options: AIRequestOptions
    @EnvironmentObject private var settings: AppSettings
    private var preview: String {
        do {
            let data = try JSONSerialization.data(withJSONObject: options.parameters(), options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        } catch { return settings.text(error.localizedDescription) }
    }
    var body: some View {
        Form {
            Section {
                Picker("Parameter Preset", selection: $options.preset) {
                    ForEach(AIParameterPreset.allCases) { Text(LocalizedStringKey($0.name)).tag($0) }
                }
            } footer: {
                Text("Model defaults sends no reasoning override. Choose only parameters supported by your model; stronger reasoning can increase latency. Gemini's compatible API also accepts reasoning_effort on supported models.")
            }
            Section {
                TextField("JSON object", text: $options.bodyJSON, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(6...16).keyboardType(.default)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("service.parameters-json")
            } header: { Text("Custom Body Parameters") } footer: {
                Text("Custom values override the preset. For example: {\"temperature\":0.2,\"max_completion_tokens\":4096}. Do not put credentials here. Test Translation uses these same parameters.")
            }
            Section("Effective Parameters") {
                Text(verbatim: preview).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            }
        }.navigationTitle("Request Parameters").navigationBarTitleDisplayMode(.inline)
    }
}
