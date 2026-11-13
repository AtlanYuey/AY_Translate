import XCTest
import Foundation
@testable import ScreenTranslationCore

final class ServiceOrderAndUsageTests: XCTestCase {
    func testServiceOrderReadsTheOlderSingleSelectionAndDropsWhatCannotBeUsed() throws {
        func service(_ name: String, _ preset: AIProviderPreset) -> SavedAIService {
            SavedAIService(name: name, preset: preset, configuration: AIServiceConfiguration(baseURL: preset.baseURL, model: "model"))
        }
        let first = service("First", .gemini), second = service("Second", .openRouter), textOnly = service("Text", .deepSeek)
        var catalog = AIServiceCatalog()
        for service in [first, second, textOnly] { try catalog.upsert(service) }
        try catalog.setChain([second.id, first.id, second.id], for: .translation)
        XCTAssertEqual(catalog.chain(for: .translation).map(\.name), ["Second", "First"], "A repeated entry counts once")
        XCTAssertThrowsError(try catalog.setChain([textOnly.id], for: .ocr), "A text-only service cannot read images")
        try catalog.setChain([first.id, second.id], for: .ocr)
        catalog.remove(first.id)
        XCTAssertEqual(catalog.selected(for: .ocr)?.id, second.id)

        // A catalog saved before the ordered list existed.
        let legacy = try JSONSerialization.data(withJSONObject: [
            "services": try JSONSerialization.jsonObject(with: JSONEncoder().encode([second, textOnly])),
            "ocrServiceID": second.id.uuidString, "translationServiceID": textOnly.id.uuidString])
        let restored = try JSONDecoder().decode(AIServiceCatalog.self, from: legacy)
        XCTAssertEqual(restored.chain(for: .ocr).map(\.id), [second.id])
        XCTAssertEqual(restored.chain(for: .translation).map(\.id), [textOnly.id])
        XCTAssertNil(restored.services[0].price, "Old services simply have no price or limit")
        // …and what is written stays readable by that older version.
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertEqual(written["ocrServiceID"] as? String, second.id.uuidString)
    }

    func testUsageIsCostedAtThePriceOfTheDayAndTheMonthlyFigureStartsOver() throws {
        let service = UUID()
        var ledger = AIUsageLedger()
        let november = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z"))
        let december = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-15T12:00:00Z"))
        ledger.record(AIUsage(input: 1_000_000, output: 500_000), service: service, price: AIPrice(input: 0.5, output: 3), now: november)
        // The price was halved afterwards: earlier spending is not rewritten.
        ledger.record(AIUsage(input: 1_000_000, output: 0), service: service, price: AIPrice(input: 0.25, output: 1.5), now: november)
        XCTAssertEqual(ledger.entry(for: service, now: november).monthCost, 0.5 + 1.5 + 0.25, accuracy: 0.0001)
        XCTAssertEqual(ledger.entry(for: service, now: december).monthCost, 0, "A new month starts at zero")
        XCTAssertEqual(ledger.entry(for: service, now: december).totalUsage.total, 2_500_000)
        ledger.record(AIUsage(input: 10, output: 5), service: service, price: nil, now: december)
        XCTAssertEqual(ledger.entry(for: service, now: december).monthUsage, AIUsage(input: 10, output: 5), "Tokens are counted even without a price")
    }

    func testPublishedPricesAreReadPerMillionTokens() {
        let list = Data(#"{"data":[{"id":"other/model","pricing":{"prompt":"0.000001","completion":"0.000002"}},{"id":"google/gemini","pricing":{"prompt":"0.0000015","completion":0.0000075}},{"id":"no/price"}]}"#.utf8)
        let price = OpenAIClient.price(inModelList: list, model: "google/gemini")
        XCTAssertEqual(price?.input ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(price?.output ?? 0, 7.5, accuracy: 0.0001)
        XCTAssertNil(OpenAIClient.price(inModelList: list, model: "no/price"), "Most providers publish no price")
        XCTAssertNil(OpenAIClient.price(inModelList: Data("{}".utf8), model: "google/gemini"))
    }
}
