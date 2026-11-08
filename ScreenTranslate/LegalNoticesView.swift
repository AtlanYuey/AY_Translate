import SwiftUI

/// Legal notices travel with both the app and its Share extension.
enum LegalNotices {
    static func text(_ name: String, bundle: Bundle = .main) -> String? {
        let file = bundle.url(forResource: name, withExtension: "txt", subdirectory: "Resources/Legal")
            ?? bundle.url(forResource: name, withExtension: "txt", subdirectory: "Legal")
            ?? bundle.url(forResource: name, withExtension: "txt")
        return file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

struct LegalNoticesView: View {
    private let notices = [
        ("Project attribution", "NOTICE"),
        ("Apache License 2.0", "Apache-2.0"),
        ("Provider icons · MIT", "ProviderIcons-MIT")
    ]
    var body: some View {
        List(notices, id: \.1) { title, file in
            NavigationLink {
                ScrollView {
                    Text(verbatim: LegalNotices.text(file) ?? "")
                        .font(.footnote).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }.navigationTitle(LocalizedStringKey(title)).navigationBarTitleDisplayMode(.inline)
            } label: { Text(LocalizedStringKey(title)) }
        }.navigationTitle("Open-source licenses").navigationBarTitleDisplayMode(.inline)
    }
}
