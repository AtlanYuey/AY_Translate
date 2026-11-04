import Foundation

nonisolated struct TranslationProbe: Identifiable, Sendable {
    let id: String
    let languageName: String
    let text: String

    static func samples(excluding target: String) -> [TranslationProbe] {
        let all: [TranslationProbe] = [
            .init(id: "en", languageName: "English", text: "Please keep the original layout and translate the whole sentence."),
            .init(id: "ja", languageName: "日本語", text: "このケーキはとてもおいしいです。もう一口食べてもいいですか？"),
            .init(id: "ko", languageName: "한국어", text: "다음 기차는 언제 출발하나요? 표 두 장을 사고 싶어요."),
            .init(id: "es", languageName: "Español", text: "¿Dónde está la estación? Quisiera comprar dos billetes."),
            .init(id: "fr", languageName: "Français", text: "Ce restaurant propose un menu végétarien et des desserts faits maison."),
            .init(id: "de", languageName: "Deutsch", text: "Bitte übersetzen Sie den vollständigen Satz und behalten Sie die Namen bei."),
            .init(id: "zh", languageName: "中文", text: "请保留原来的排版，完整翻译这句话，并让标题和正文容易阅读。")
        ]
        return all.filter { !target.lowercased().hasPrefix($0.id) }
    }
}
