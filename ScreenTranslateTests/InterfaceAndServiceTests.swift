import XCTest
import CoreText
import SwiftUI
import UIKit
@testable import ScreenTranslate

@MainActor
final class InterfaceAndServiceTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var keys: ServiceTestKeys!
    private var settings: AppSettings!

    override func setUp() async throws {
        suite = "ScreenTranslate.interface." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        keys = ServiceTestKeys()
        settings = AppSettings(defaults: defaults, keyStore: keys)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func service(_ name: String, url: String = "https://example.test/v1") -> SavedAIService {
        SavedAIService(name: name, configuration: .init(baseURL: url, model: "test-model"))
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 390, height: 780)).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 390, height: 390))
            UIColor(red: 0.05, green: 0.12, blue: 0.22, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 390, width: 390, height: 390))
        }
    }

    private func region() -> RecognizedBlock {
        RecognizedBlock(id: UUID(), original: "Hello World", translation: "你好，世界", boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.7, height: 0.04), confidence: 1)
    }

    private func services(_ regions: [RecognizedBlock]) -> ProcessingServices {
        ProcessingServices(vision: { _, _ in regions }, aiOCR: { _, _, _, _ in XCTFail("Unexpected cloud OCR"); throw AIServiceError.transport }, aiTranslation: { _, _, _, _, _, _ in XCTFail("Unexpected cloud translation"); throw AIServiceError.transport })
    }

    func testActivityBorderSurvivesRoundedDisplayMasksInBothOrientations() throws {
        for size in [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393), CGSize(width: 744, height: 1133)] {
            let renderer = ImageRenderer(content: Color.black.overlay { ProcessingEdgeGlow(frameTime: 0, cornerRadius: 64) }
                .frame(width: size.width, height: size.height))
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            let cg = try XCTUnwrap(image.cgImage)
            let width = cg.width, height = cg.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(origin: .zero, size: size))
            }
            let mask = RoundedRectangle(cornerRadius: 64, style: .continuous).path(in: CGRect(origin: .zero, size: size)).cgPath
            // At 1×, a correctly clipped curve still covers part of a pixel
            // whose center lies outside the path. Permit only that 1 px fringe.
            let antialiasFringe = mask.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
            var corners = [Int](repeating: 0, count: 4), clipped = 0
            for y in 0..<height { for x in 0..<width {
                guard (0..<3).contains(where: { bytes[(y * width + x) * 4 + $0] > 45 }) else { continue }
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if !mask.contains(point) && !antialiasFringe.contains(point) { clipped += 1 }
                if (x < 115 || x >= width - 115) && (y < 115 || y >= height - 115) {
                    corners[(x < 115 ? 0 : 1) + (y < 115 ? 0 : 2)] += 1
                }
            } }
            XCTAssertEqual(clipped, 0, "No glow may extend beyond the 1 px antialias fringe")
            for (x, y) in [(0, height / 2), (width - 1, height / 2), (width / 2, 0), (width / 2, height - 1)] {
                XCTAssertGreaterThan(bytes[(y * width + x) * 4 ..< (y * width + x) * 4 + 3].max() ?? 0, 100, "Light must reach the outermost edge without an inset gap")
            }
            XCTAssertEqual(bytes[(height / 2 * width + width / 2) * 4], 0, "The center remains untouched")
            XCTAssertTrue(corners.allSatisfy { $0 > 100 }, "All four corners must contain a continuous visible arc: \(corners)")
            let attachment = XCTAttachment(image: image)
            attachment.name = "贴外缘的动态光晕-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testEdgeLightAnimatesAndAllocatesOnlyPerimeterTiles() throws {
        let size = CGSize(width: 393, height: 852)
        let tiles = ProcessingEdgeGlow.tiles(size: size, radius: 64)
        XCTAssertLessThan(tiles.reduce(0) { $0 + $1.width * $1.height }, size.width * size.height * 0.25)
        for i in tiles.indices { for j in tiles.indices where j > i {
            XCTAssertTrue(tiles[i].intersection(tiles[j]).isEmpty, "Tiles must not double-paint seams")
        } }
        var samples: [Data] = []
        for time in [0.0, 2.0] {
            for background in [Color.black, Color.white] {
                let renderer = ImageRenderer(content: background.overlay { ProcessingEdgeGlow(frameTime: time, cornerRadius: 64) }.frame(width: size.width, height: size.height))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage)
                samples.append(try XCTUnwrap(image.pngData()))
                let attachment = XCTAttachment(image: image)
                attachment.name = "外缘光晕-时间\(time)-背景\(samples.count)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertNotEqual(samples[0], samples[2], "The light must flow over time")
    }

    func testShareLoadingCanvasKeepsTheInvokingImageVisibleInsteadOfBlack() throws {
        let state = AppState(settings: settings, history: HistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), services: services([]))
        state.beginImport()
        XCTAssertTrue(state.isProcessing)
        let renderer = ImageRenderer(content: ZStack {
            Color.green
            TranslationResultView().environmentObject(state).environmentObject(settings).environmentObject(state.history)
        }.frame(width: 393, height: 852))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        // The center contains ProgressView. Sample unobstructed background,
        // not the UIKit progress view's ImageRenderer placeholder.
        for point in [CGPoint(x: 100, y: 200), CGPoint(x: 290, y: 200), CGPoint(x: 100, y: 600), CGPoint(x: 290, y: 600)] {
            var pixel = [UInt8](repeating: 0, count: 4)
            try pixel.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.translateBy(x: -point.x, y: -point.y)
                context.draw(image, in: CGRect(x: 0, y: 0, width: 393, height: 852))
            }
            XCTAssertGreaterThan(pixel[1], 100, "The host remains visible until the screenshot arrives")
            XCTAssertGreaterThan(pixel[1], pixel[0])
        }
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "导入中-透明背景与进度提示"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testTextDetailsAreOptInAndPersistAcrossSettingsReload() {
        XCTAssertFalse(settings.showsTextDetailsOnTap)
        settings.showsTextDetailsOnTap = true
        XCTAssertTrue(AppSettings(defaults: defaults, keyStore: keys).showsTextDetailsOnTap)
        XCTAssertTrue(SharedPreferenceKeys.contains("showsTextDetailsOnTap"))
        XCTAssertTrue(CloudSettingsRecord.allowedKeys.contains("showsTextDetailsOnTap"))
    }

    func testRefreshingPreferencesIsReadOnlyAndPreservesSelectedChineseTarget() throws {
        let bridged = AppSettings(defaults: defaults, keyStore: keys, syncThroughKeychain: true)
        bridged.target = .chinese
        let writes = keys.sharedWrites
        bridged.refreshSharedPreferences()
        bridged.refreshSharedPreferences()
        XCTAssertEqual(bridged.target, .chinese)
        XCTAssertEqual(keys.sharedWrites, writes, "Refreshing must not republish default properties")
    }

    func testNativeZoomKeepsTheRequestedFocalPointAndSurvivesContentUpdates() {
        let controller = ZoomScrollController(root: Color.white)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        let reset = UUID()
        controller.update(size: CGSize(width: 400, height: 600), resetID: reset)
        controller.view.layoutIfNeeded()
        controller.scroll.zoom(to: CGRect(x: 170, y: 150, width: 160, height: 320), animated: false)
        controller.view.layoutIfNeeded()
        let center = controller.scroll.convert(CGPoint(x: controller.scroll.bounds.midX, y: controller.scroll.bounds.midY), to: controller.host.view)
        XCTAssertEqual(controller.scroll.zoomScale, 2.5, accuracy: 0.02)
        XCTAssertEqual(center.x, 250, accuracy: 1)
        XCTAssertEqual(center.y, 310, accuracy: 1)
        let offset = controller.scroll.contentOffset
        controller.host.rootView = AnyView(Color.black)
        controller.update(size: CGSize(width: 400, height: 600), resetID: reset)
        XCTAssertEqual(controller.scroll.zoomScale, 2.5, accuracy: 0.02)
        XCTAssertEqual(controller.scroll.contentOffset, offset)
        window.isHidden = true
    }

    func testDismantledZoomControllerReleasesItsCapturedImageEvenIfHostRetainsController() async throws {
        weak var captured: UIImage?
        var controller: ZoomScrollController<Image>?
        autoreleasepool {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 2600)).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 2600))
            }
            captured = image
            controller = ZoomScrollController(root: Image(uiImage: image))
            controller?.loadViewIfNeeded()
            controller?.onDismiss = { _ = image.size }
        }
        XCTAssertNotNil(captured)
        controller?.releaseImageResources()
        // Let UIKit drain its autoreleased drawing/view work.
        for _ in 0..<30 where captured != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(controller, "The system may retain a dismissed controller")
        XCTAssertNil(captured, "Its image and callbacks must not survive until the next invocation")
        XCTAssertTrue(controller?.children.isEmpty == true)
        XCTAssertNil(controller?.scroll.delegate)
    }

    func testBottomDismissUsesTouchOriginAndIsDisabledDuringProcessingOrZoom() {
        let controller = ZoomScrollController(root: Color.white)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        controller.view.layoutIfNeeded()
        controller.update(size: CGSize(width: 400, height: 600), resetID: UUID())
        let gesture = SampledBottomPan()
        // The first delivered move has already left the bottom 110pt strip.
        gesture.point = CGPoint(x: 48, y: 590)
        gesture.movement = CGPoint(x: 0, y: -160)
        gesture.speed = CGPoint(x: 0, y: -700)
        XCTAssertTrue(controller.shouldBeginBottomDismiss(gesture))
        controller.allowsDismiss = false
        XCTAssertFalse(controller.shouldBeginBottomDismiss(gesture), "Processing must not be dismissed by an incidental drag")
        controller.allowsDismiss = true
        controller.scroll.setZoomScale(2, animated: false)
        XCTAssertFalse(controller.shouldBeginBottomDismiss(gesture), "Dragging an enlarged image pans it instead")
        controller.scroll.setZoomScale(1, animated: false)
        gesture.movement = CGPoint(x: 0, y: -20)
        XCTAssertFalse(controller.shouldBeginBottomDismiss(gesture), "A drag starting in the image centre must not close it")
        gesture.movement = CGPoint(x: 0, y: -160)
        gesture.speed = CGPoint(x: 700, y: -100)
        XCTAssertFalse(controller.shouldBeginBottomDismiss(gesture), "A horizontal gesture must not close the image")
    }

    func testEveryPackagedProviderMarkHasVisibleArtwork() throws {
        for preset in AIProviderPreset.allCases where preset != .other {
            let image = try XCTUnwrap(UIImage(named: "provider-" + preset.rawValue))
            var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
            try bytes.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            let visible = stride(from: 0, to: bytes.count, by: 4).filter { min(bytes[$0], min(bytes[$0+1], bytes[$0+2])) < 180 }.count
            XCTAssertGreaterThan(visible, 160, "Missing/clipped mark: " + preset.rawValue)
        }
    }

    func testCloudSyncBootstrapsAutomaticallyButNewerRemoteEditsWin() throws {
        defaults.set("en", forKey: "defaultTargetLanguage")
        let cloud = MemoryCloudSettings()
        var imported: [String: Any] = [:]
        let sync = CloudSettingsSync(defaults: defaults, store: cloud, apply: { changes in
            imported.merge(changes) { _, new in new }; return true
        }, status: { _ in })
        sync.start()
        defer { sync.stop() }
        let outgoing = "ay.settings.v2." + (try XCTUnwrap(defaults.string(forKey: "icloud.device"))) + ".defaultTargetLanguage"
        let initial = try JSONDecoder().decode(CloudSettingsRecord.self, from: XCTUnwrap(cloud.data(forKey: outgoing)))
        XCTAssertEqual(initial.timestamp, 1, "Existing saved settings seed automatically at migration priority")
        let remote = try CloudSettingsRecord(value: "ja", timestamp: 100, device: "other")
        cloud.set(try JSONEncoder().encode(remote), forKey: "ay.settings.v1.defaultTargetLanguage")
        sync.merge()
        XCTAssertEqual(imported["defaultTargetLanguage"] as? String, "ja")
        sync.changed("es", key: "defaultTargetLanguage")
        let sent = try JSONDecoder().decode(CloudSettingsRecord.self, from: XCTUnwrap(cloud.data(forKey: outgoing)))
        XCTAssertEqual(sent.decodedValue(for: "defaultTargetLanguage") as? String, "es")
        sync.changed("private", key: "APIKey")
        sync.changed(true, key: "saveTranslationHistory")
        XCTAssertNil(cloud.data(forKey: "ay.settings.v1.APIKey"))
        XCTAssertNil(cloud.data(forKey: "ay.settings.v1.saveTranslationHistory"))
    }

    func testCloudSyncAutomaticallyFlushesEditsAndResumesExtensionChanges() async throws {
        let cloud = MemoryCloudSettings()
        let sync = CloudSettingsSync(defaults: defaults, store: cloud, apply: { _ in true }, status: { _ in })
        sync.start()
        let outgoing = "ay.settings.v2." + (try XCTUnwrap(defaults.string(forKey: "icloud.device"))) + ".defaultTargetLanguage"
        let initialCalls = cloud.syncCalls
        defaults.set("zh-Hans", forKey: "defaultTargetLanguage")
        sync.changed("zh-Hans", key: "defaultTargetLanguage")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(cloud.syncCalls, initialCalls)
        defaults.set("ja", forKey: "defaultTargetLanguage") // Share extension edit while app suspended.
        sync.resume()
        let record = try JSONDecoder().decode(CloudSettingsRecord.self, from: XCTUnwrap(cloud.data(forKey: outgoing)))
        XCTAssertEqual(record.decodedValue(for: "defaultTargetLanguage") as? String, "ja")
        sync.stop()
        sync.changed("es", key: "defaultTargetLanguage")
        let stopped = try JSONDecoder().decode(CloudSettingsRecord.self, from: XCTUnwrap(cloud.data(forKey: outgoing)))
        XCTAssertEqual(stopped, record)
    }

    func testFirstCloudDownloadCannotBeOverwrittenByAnotherDevicesBaseline() throws {
        defaults.set("en", forKey: "defaultTargetLanguage")
        let cloud = MemoryCloudSettings()
        var imported: String?
        let sync = CloudSettingsSync(defaults: defaults, store: cloud, apply: { changes in
            imported = changes["defaultTargetLanguage"] as? String
            return true
        }, status: { _ in })
        sync.start(); defer { sync.stop() }
        let ownSlots = Set(cloud.values.keys)
        let remoteKey = "ay.settings.v2.other-device.defaultTargetLanguage"
        let remote = try CloudSettingsRecord(value: "zh-Hans", timestamp: 100, device: "other-device")
        let bytes = try JSONEncoder().encode(remote)
        cloud.set(bytes, forKey: remoteKey) // Delayed first download.
        sync.merge()
        XCTAssertEqual(imported, "zh-Hans")
        XCTAssertEqual(cloud.data(forKey: remoteKey), bytes)
        XCTAssertTrue(ownSlots.isDisjoint(with: [remoteKey]))
    }

    func testChangingTranslationServiceReusesLocalRecognitionAndClosingClearsTheCache() async throws {
        settings.source = .english; settings.target = .english
        var calls = 0
        let state = AppState(settings: settings, history: HistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            services: ProcessingServices(vision: { _, _ in calls += 1; return [self.region()] },
                aiOCR: { _, _, _, _ in throw AIServiceError.transport }, aiTranslation: { _, _, _, _, _, _ in throw AIServiceError.transport }))
        let original = image()
        state.process(original)
        for _ in 0..<100 where state.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        state.retry()
        for _ in 0..<100 where state.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 1)
        state.closeResult()
        state.process(original)
        for _ in 0..<100 where state.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 2, "Closing must release the screenshot and its recognition cache")
        state.closeResult()
    }

    func testOCRFailureStillDisplaysTheOriginalScreenshotInDarkMode() async throws {
        let state = AppState(settings: settings, history: HistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            services: ProcessingServices(vision: { _, _ in throw ScreenReadingError.noText }, aiOCR: { _, _, _, _ in throw AIServiceError.transport }, aiTranslation: { _, _, _, _, _, _ in throw AIServiceError.transport }))
        state.process(image())
        for _ in 0..<100 { if case .failed = state.phase { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard case .failed = state.phase else { return XCTFail("Expected OCR failure") }
        let screenshot = await attach(TranslationResultView().environmentObject(state).environmentObject(settings).environmentObject(state.history).preferredColorScheme(.dark), name: "识别失败仍然保留原图")
        let cg = try XCTUnwrap(screenshot.cgImage)
        var pixels = [UInt8](repeating: 0, count: 64 * 128 * 4)
        let fraction = try pixels.withUnsafeMutableBytes { bytes -> Double in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 64, height: 128, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 128))
            let raw = bytes.bindMemory(to: UInt8.self)
            return Double(stride(from: 0, to: raw.count, by: 4).filter { raw[$0] > 220 && raw[$0 + 1] > 220 && raw[$0 + 2] > 220 }.count) / (64 * 128)
        }
        XCTAssertGreaterThan(fraction, 0.25, "The white half of the original must remain visible, rather than a black error page")
        state.closeResult()
    }

    func testResultAdaptsToNarrowWideAndTabletWindows() async throws {
        settings.source = .english; settings.target = .english
        let state = AppState(settings: settings, history: HistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), services: services([region()]))
        state.process(image())
        for _ in 0..<100 where state.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.phase, .ready)
        for size in [CGSize(width: 320, height: 740), CGSize(width: 744, height: 1133), CGSize(width: 1024, height: 768), CGSize(width: 507, height: 768)] {
            let image = await attach(TranslationResultView().environmentObject(state).environmentObject(settings).environmentObject(state.history).preferredColorScheme(.dark),
                name: "译图窗口-\(Int(size.width))x\(Int(size.height))", size: size)
            XCTAssertEqual(image.size, size)
        }
        state.closeResult()
    }

    func testSharedKeychainSynchronizesTwoIndependentPreferencesSuites() throws {
        let otherName = suite + ".extension", other = UserDefaults(suiteName: otherName)!
        defer { other.removePersistentDomain(forName: otherName) }
        let main = AppSettings(defaults: defaults, keyStore: keys, syncThroughKeychain: true)
        let a = service("Feather 自签服务")
        try main.saveService(a, keyReplacement: "fixture-key-shared")
        try main.selectService(a.id, for: .translation)
        main.target = .japanese; main.overlayTextScale = 1.2
        let extensionSettings = AppSettings(defaults: other, keyStore: keys, syncThroughKeychain: true)
        XCTAssertEqual(extensionSettings.serviceCatalog, main.serviceCatalog)
        XCTAssertEqual(extensionSettings.translationEngine, .ai)
        XCTAssertEqual(extensionSettings.target, .japanese)
        XCTAssertEqual(extensionSettings.overlayTextScale, 1.2)
        XCTAssertEqual(try extensionSettings.readAPIKey(for: .translation), "fixture-key-shared")
        try keys.save("", for: .sharedPreferences)
        main.refreshSharedPreferences()
        XCTAssertEqual(main.serviceCatalog.services.count, 1, "A missing mirror after re-signing must not wipe local providers")
        try main.removeService(a.id)
        extensionSettings.refreshSharedPreferences()
        XCTAssertTrue(extensionSettings.serviceCatalog.services.isEmpty)
        XCTAssertEqual(extensionSettings.translationEngine, .apple)
        XCTAssertFalse(defaults.dictionaryRepresentation().description.contains("fixture-key-shared"))
        XCTAssertFalse(other.dictionaryRepresentation().description.contains("fixture-key-shared"))
    }

    func testExplicitTransferWorksWhenBothSharedEntitlementsAreMissing() throws {
        let a = service("本地导入服务")
        try settings.saveService(a, keyReplacement: "fixture-transfer-key")
        try settings.selectService(a.id, for: .translation)
        settings.grantConsent(for: .translation)
        settings.interfaceLanguage = .korean
        let now = Date(), token = try settings.configurationTransfer(now: now)
        let otherName = suite + ".isolated", other = UserDefaults(suiteName: otherName)!
        defer { other.removePersistentDomain(forName: otherName) }
        let isolated = AppSettings(defaults: other, keyStore: ServiceTestKeys())
        try isolated.importConfiguration(token, now: now.addingTimeInterval(20))
        XCTAssertEqual(isolated.serviceCatalog, settings.serviceCatalog)
        XCTAssertEqual(isolated.interfaceLanguage, .korean)
        XCTAssertEqual(try isolated.readAPIKey(for: .translation), "fixture-transfer-key")
        XCTAssertFalse(isolated.hasConsent(for: .translation), "Transfer must not silently authorize cloud uploads")
        XCTAssertFalse(other.dictionaryRepresentation().description.contains("fixture-transfer-key"))
        XCTAssertThrowsError(try isolated.importConfiguration(token, now: now.addingTimeInterval(61)))
        XCTAssertThrowsError(try isolated.importConfiguration("wrong token"))
    }

    func testAlreadyChineseScreensDoNotStartAnUnsupportedIdentitySession() {
        XCTAssertTrue(AppState.alreadyInTargetLanguage("请打开设置并选择你需要的翻译语言。", target: .chinese))
        XCTAssertTrue(AppState.alreadyInTargetLanguage("10:22 90%", target: .chinese))
        XCTAssertFalse(AppState.alreadyInTargetLanguage("This delicious cake is made with fresh fruit.", target: .chinese))
    }

    func testVerticalOverlayUsesOriginalGlyphWidthAndNeverPaintsTruncatedText() throws {
        let block = RecognizedBlock(id: UUID(), original: "面白い形ですね", translation: "形状很有趣呢", boundingBox: CGRect(x: 0.6, y: 0.5, width: 0.03, height: 0.2), confidence: 1, sourceLineHeight: 0.02, flow: .vertical, sourceColumnWidth: 0.03)
        let layout = ScreenshotRendering.textLayout(for: block, canvasSize: CGSize(width: 390, height: 844), textScale: 1)
        XCTAssertLessThan(layout.fontSize, 12)
        XCTAssertNotNil(layout.vertical)
        XCTAssertTrue(layout.canRender)
        let enlarged = ScreenshotRendering.textLayout(for: block, canvasSize: CGSize(width: 390, height: 844), textScale: 1.4)
        XCTAssertEqual(enlarged.fontSize, layout.fontSize * 1.4, accuracy: 0.001)
        XCTAssertTrue(enlarged.canRender, "Manual size must not silently hide a complete vertical translation")
        XCTAssertEqual(enlarged.sourceRect, layout.sourceRect)
        XCTAssertEqual(enlarged.textRect.width, layout.textRect.width * 1.4, accuracy: 0.001)
        var long = block; long.translation = String(repeating: "这是一段非常长的译文", count: 50)
        let cannotFit = ScreenshotRendering.textLayout(for: long, canvasSize: CGSize(width: 390, height: 844), textScale: 1)
        XCTAssertFalse(cannotFit.canRender)
        let document = TranslationDocument(id: UUID(), image: image(), blocks: [long], source: .japanese, target: .chinese, createdAt: Date())
        let rendered = ScreenshotRendering.translatedImage(document, palette: [:], textScale: 1)
        let baseline = ScreenshotRendering.translatedImage(TranslationDocument(id: document.id, image: document.image, blocks: [], source: .japanese, target: .chinese, createdAt: Date()), palette: [:], textScale: 1)
        XCTAssertEqual(rendered.pngData(), baseline.pngData(), "An unrenderable translation must leave every original pixel unchanged")
    }

    func testRealVisionReadsSmallUprightJapaneseVerticalColumns() async throws {
        executionTimeAllowance = 180
        let size = CGSize(width: 900, height: 1600)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let originals = ["このケーキは", "おいしいです", "一口食べますか"]
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            for (index, text) in originals.enumerated() {
                for (row, glyph) in text.enumerated() {
                    (String(glyph) as NSString).draw(at: CGPoint(x: 640 - index * 44, y: 180 + row * 34), withAttributes: [.font: UIFont.systemFont(ofSize: 28), .foregroundColor: UIColor.black])
                }
            }
        }
        let attachment = XCTAttachment(image: image); attachment.name = "竖排日文小字原图"; attachment.lifetime = .keepAlways; add(attachment)
        let blocks = try await ScreenReader.recognize(in: image, source: .automatic)
        let text = blocks.map(\.original).joined()
        let recognized = XCTAttachment(string: text); recognized.name = "真实Vision竖排识别"; recognized.lifetime = .keepAlways; add(recognized)
        if let cgImage = image.cgImage, let raster = VisionTextRecognizer.grayscaleImage(cgImage) {
            let columns = VerticalInkDetector.columns(grayscale: raster.bytes, width: raster.width, height: raster.height)
            let detail = XCTAttachment(string: "inkColumns=\(columns.map(\.count)); blocks=\(blocks.map { "\($0.original): \($0.boundingBox); \($0.flow)" })")
            detail.name = "iOS竖排列定位与识别坐标"; detail.lifetime = .keepAlways; add(detail)
            for (index, column) in columns.enumerated() {
                if let strip = VisionTextRecognizer.stripImage(cgImage, glyphs: column) {
                    let capture = XCTAttachment(image: UIImage(cgImage: strip))
                    capture.name = "iOS本地竖排列重排-\(index)"; capture.lifetime = .keepAlways; add(capture)
                }
            }
        }
        XCTAssertTrue(text.contains("ケーキ"), text)
        XCTAssertTrue(text.contains("おいしい"), text)
        XCTAssertTrue(blocks.contains { $0.flow == .vertical }, text)
        let paragraphs = TranslationPlanner.paragraphs(blocks, preference: .quality)
        var translated = paragraphs
        for index in translated.indices where translated[index].flow == .vertical { translated[index].translation = "这块蛋糕真好吃" }
        let document = TranslationDocument(id: UUID(), image: image, blocks: translated, source: .japanese, target: .chinese, createdAt: Date())
        let result = ScreenshotRendering.translatedImage(document, palette: ScreenshotRendering.palette(for: document), textScale: 1)
        let output = XCTAttachment(image: result); output.name = "竖排译文完整字形覆盖"; output.lifetime = .keepAlways; add(output)
        for block in translated where block.flow == .vertical {
            let layout = ScreenshotRendering.textLayout(for: block, canvasSize: size, textScale: 1)
            XCTAssertLessThan(layout.fontSize, 40, "Column height must not become font size")
        }
    }

    func testSystemLanguageIsTheDefaultAndSelectionIsPersistent() {
        XCTAssertEqual(settings.interfaceLanguage, .system)
        settings.interfaceLanguage = .english
        XCTAssertEqual(AppSettings(defaults: defaults, keyStore: keys).interfaceLanguage, .english)
        settings.interfaceLanguage = .system
        XCTAssertEqual(AppSettings(defaults: defaults, keyStore: keys).interfaceLanguage, .system)
    }

    func testBundledInterfaceResourcesHaveRealChineseAndEnglishValues() {
        XCTAssertEqual(AppLocalization.text("Settings", language: .simplifiedChinese), "设置")
        XCTAssertEqual(AppLocalization.text("Chinese", language: .simplifiedChinese), "中文（简体）")
        XCTAssertEqual(AppLocalization.text("Show Original", language: .simplifiedChinese), "显示原图")
        XCTAssertEqual(AppLocalization.text("Settings", language: .traditionalChinese), "設定")
        XCTAssertEqual(AppLocalization.text("Settings", language: .english), "Settings")
    }

    func testSwitchingNamedProvidersRetainsTheirIndependentKeysAndConsent() throws {
        let a = service("日常"), b = service("高质量")
        try settings.saveService(a, keyReplacement: "test-key-A")
        try settings.saveService(b, keyReplacement: "test-key-B")
        try settings.selectService(a.id, for: .translation)
        settings.grantConsent(for: .translation)
        try settings.selectService(b.id, for: .translation)
        XCTAssertEqual(try settings.readAPIKey(for: .translation), "test-key-B")
        XCTAssertFalse(settings.hasConsent(for: .translation))
        try settings.selectService(a.id, for: .translation)
        XCTAssertEqual(try settings.readAPIKey(for: .translation), "test-key-A")
        XCTAssertTrue(settings.hasConsent(for: .translation))
        let restored = AppSettings(defaults: defaults, keyStore: keys)
        XCTAssertEqual(restored.serviceCatalog.services.count, 2)
        XCTAssertEqual(try restored.readAPIKey(for: .translation), "test-key-A")
    }

    func testDeletingOneServiceDoesNotRemoveAnotherCredential() throws {
        let a = service("A"), b = service("B")
        try settings.saveService(a, keyReplacement: "test-A"); try settings.saveService(b, keyReplacement: "test-B")
        try settings.selectService(a.id, for: .ocr); try settings.selectService(b.id, for: .translation)
        try settings.removeService(a.id)
        XCTAssertEqual(settings.ocrEngine, .appleVision)
        XCTAssertEqual(try keys.read(.service(a.id)), "")
        XCTAssertEqual(try settings.readAPIKey(for: .translation), "test-B")
    }

    func testEndpointChangeClearsOnlyTheEditedServicesCredential() throws {
        var a = service("A"); let b = service("B")
        try settings.saveService(a, keyReplacement: "test-A"); try settings.saveService(b, keyReplacement: "test-B")
        a.configuration.baseURL = "https://other.test/v1"
        try settings.saveService(a, keyReplacement: nil)
        XCTAssertEqual(try keys.read(.service(a.id)), "")
        XCTAssertEqual(try keys.read(.service(b.id)), "test-B")
    }

    func testLegacyProfilesMigrateWithoutLosingKeysOrConfigurations() throws {
        defaults.removeObject(forKey: "ai.catalog.initialized")
        defaults.removeObject(forKey: "ai.services.v1")
        let config = AIServiceConfiguration(baseURL: "https://legacy.test/v1", model: "legacy-model")
        defaults.set(try JSONEncoder().encode(config), forKey: "ai.ocr")
        defaults.set(try JSONEncoder().encode(config), forKey: "ai.translation")
        try keys.save("legacy-ocr-test", for: .ocr)
        try keys.save("legacy-translation-test", for: .translation)
        let migrated = AppSettings(defaults: defaults, keyStore: keys)
        XCTAssertEqual(migrated.serviceCatalog.services.count, 2)
        XCTAssertEqual(migrated.configuration(for: .ocr), config)
        XCTAssertEqual(try migrated.readAPIKey(for: .ocr), "legacy-ocr-test")
        XCTAssertEqual(try migrated.readAPIKey(for: .translation), "legacy-translation-test")
        XCTAssertEqual(try keys.read(.ocr), "")
        let data = try XCTUnwrap(defaults.data(forKey: "ai.services.v1"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("legacy-ocr-test"))
        XCTAssertEqual(AppSettings(defaults: defaults, keyStore: keys).serviceCatalog.services.count, 2)
    }

    func testLockedKeychainMigrationCanResumeWithoutErasingLegacyKey() throws {
        defaults.removeObject(forKey: "ai.catalog.initialized")
        defaults.removeObject(forKey: "ai.services.v1")
        defaults.set(try JSONEncoder().encode(AIServiceConfiguration(baseURL: "https://legacy.test/v1", model: "m")), forKey: "ai.ocr")
        try keys.save("protected-test-key", for: .ocr)
        keys.failServiceWrites = true
        let migrated = AppSettings(defaults: defaults, keyStore: keys)
        XCTAssertNotNil(migrated.serviceMigrationError)
        XCTAssertEqual(try keys.read(.ocr), "protected-test-key")
        keys.failServiceWrites = false
        XCTAssertEqual(try migrated.readAPIKey(for: .ocr), "protected-test-key")
        XCTAssertEqual(try keys.read(.ocr), "")
    }

    func testRestorationErasesOnlySourceInkAtTheCorrectImageOrigin() async throws {
        let size = CGSize(width: 200, height: 400)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let source = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            UIColor.blue.setFill(); renderer.fill(CGRect(x: 0, y: 200, width: 200, height: 200))
            UIColor.black.setFill(); renderer.fill(CGRect(x: 90, y: 40, width: 3, height: 23))
        }
        let region = CGRect(x: 0.2, y: 1 - 104.0/400, width: 0.35, height: 64.0/400)
        let glyph = CGRect(x: 89.0/200, y: 1 - 64.0/400, width: 5.0/200, height: 24.0/400)
        let block = RecognizedBlock(id: UUID(), original: "IIII", translation: "好", boundingBox: region, confidence: 1, sourceGlyphBoxes: [glyph])
        let document = TranslationDocument(id: UUID(), image: source, blocks: [block], source: .english, target: .chinese, createdAt: Date())
        let patches = await ScreenshotRendering.restorationsAsync(for: document)
        XCTAssertNotNil(patches[block.id])
        let restored = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            source.draw(at: .zero)
            ScreenshotRendering.drawRestoration(patches[block.id], canvas: size, in: renderer.cgContext)
        }
        // CGImage crops use the same top-left coordinates as the source drawing.
        func red(_ image: UIImage, x: Int, y: Int) throws -> UInt8 {
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            var bytes = [UInt8](repeating: 0, count: 4)
            try bytes.withUnsafeMutableBytes { raw in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes[0]
        }
        XCTAssertLessThan(try red(source, x: 91, y: 50), 20)
        XCTAssertGreaterThan(try red(restored, x: 91, y: 50), 230)
        XCTAssertEqual(try red(restored, x: 91, y: 300), try red(source, x: 91, y: 300))
        let attachment = XCTAttachment(image: restored); attachment.name = "笔画恢复-上下坐标与背景保护"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPaletteMatchesTopAndBottomImageCoordinatesWithoutGrayMaterial() throws {
        let top = region()
        let bottom = RecognizedBlock(id: UUID(), original: "Bottom", translation: "底部", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.04), confidence: 1)
        let document = TranslationDocument(id: UUID(), image: image(), blocks: [top, bottom], source: .english, target: .chinese, createdAt: Date())
        let colors = ScreenshotRendering.palette(for: document)
        XCTAssertTrue(try XCTUnwrap(colors[top.id]).usesDarkText)
        XCTAssertFalse(try XCTUnwrap(colors[bottom.id]).usesDarkText)
        XCTAssertEqual(try XCTUnwrap(colors[top.id]).red, 1, accuracy: 0.02)
        let rendered = ScreenshotRendering.translatedImage(document, palette: colors, textScale: 1)
        XCTAssertEqual(rendered.size.width, 390)
    }

    func testLandscapeMenuKeepsTitleAndSmallBodyAtTheirOriginalRelativeSizes() {
        let imageSize = CGSize(width: 2048, height: 1152)
        let canvas = ImageViewport.fittedSize(image: imageSize, container: CGSize(width: 393, height: 852))
        let body = RecognizedBlock(id: UUID(), original: "YOGUR O FRUTA", translation: "酸奶或水果",
                                   boundingBox: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 20 / 1152.0), confidence: 1)
        let title = RecognizedBlock(id: UUID(), original: "MENU SEMANA", translation: "每周菜单",
                                    boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 40 / 1152.0), confidence: 1)
        let bodyLayout = ScreenshotRendering.textLayout(for: body, canvasSize: canvas, textScale: 1)
        let titleLayout = ScreenshotRendering.textLayout(for: title, canvasSize: canvas, textScale: 1)
        XCTAssertLessThan(bodyLayout.fontSize, 6, "Zoomed-out photo text must not be inflated to a 12pt minimum")
        XCTAssertEqual(titleLayout.fontSize / bodyLayout.fontSize, 2, accuracy: 0.15)
        XCTAssertEqual(bodyLayout.sourceRect.height, 20 * canvas.width / imageSize.width, accuracy: 0.0001)
        let largerCanvas = CGSize(width: canvas.width * 2, height: canvas.height * 2)
        XCTAssertEqual(ScreenshotRendering.textLayout(for: body, canvasSize: largerCanvas, textScale: 1).fontSize,
                       bodyLayout.fontSize * 2, accuracy: 0.1)
    }

    func testLongTranslationFitsRelativeToSourceBeforeApplyingUserMultiplier() {
        var block = region()
        block.translation = String(repeating: "这段译文保留上下文。", count: 5)
        let canvas = CGSize(width: 390, height: 780)
        let short = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 1, text: "你好")
        let normal = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 1)
        let enlarged = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 1.6)
        let reduced = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 0.8)
        XCTAssertLessThan(normal.fontSize, short.fontSize)
        XCTAssertGreaterThanOrEqual(normal.fontSize, short.fontSize * 0.70)
        XCTAssertEqual(enlarged.fontSize, normal.fontSize * 1.6, accuracy: 0.0001)
        XCTAssertEqual(reduced.fontSize, normal.fontSize * 0.8, accuracy: 0.0001)
        XCTAssertEqual(enlarged.sourceRect, normal.sourceRect, "Font scaling must not enlarge the original cover region")
        let singleLine = ScreenshotRendering.textLayout(for: block, canvasSize: canvas, textScale: 1.8, text: "你好")
        XCTAssertGreaterThanOrEqual(singleLine.textRect.height + 0.0001,
                                    UIFont.systemFont(ofSize: singleLine.fontSize, weight: .medium).lineHeight,
                                    "Manual enlargement must keep an entire glyph line visible")
    }

    func testShortTranslationUsesOriginalLineHeightForLatinAndCJKFonts() {
        for text in ["Menu", "菜单", "メニュー", "메뉴"] {
            for height in [CGFloat(220), CGFloat(1152)] {
                let block = RecognizedBlock(id: UUID(), original: "MENU", translation: text,
                                            boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 20 / 1152.0), confidence: 1)
                let layout = ScreenshotRendering.textLayout(for: block, canvasSize: CGSize(width: height * 16 / 9, height: height), textScale: 1)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    .font: UIFont.systemFont(ofSize: layout.fontSize, weight: .medium)
                ]) as CFAttributedString)
                let ink = CTLineGetImageBounds(line, nil)
                let originalHeight = block.boundingBox.height * height
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let fontHeight = UIFont.systemFont(ofSize: layout.fontSize, weight: .medium).lineHeight
                XCTAssertEqual(max(fontHeight, ascent + descent + leading), originalHeight, accuracy: originalHeight * 0.03,
                               "OCR line height must produce the matching typographic line, not an oversized ink box")
                XCTAssertGreaterThan(ink.height, 0)
                XCTAssertGreaterThanOrEqual(layout.textRect.height + originalHeight * 0.02, ascent + descent + leading)
            }
        }
    }

    func testJoinedParagraphKeepsItsOriginalLineSizeInBothRenderers() {
        let first = RecognizedBlock(id: UUID(), original: "This is a sentence wrapping", translation: "内容",
                                    boundingBox: CGRect(x: 0.1, y: 0.8, width: 0.7, height: 0.02), confidence: 1)
        let second = RecognizedBlock(id: UUID(), original: "onto the next line", translation: "内容",
                                     boundingBox: CGRect(x: 0.1, y: 0.775, width: 0.7, height: 0.02), confidence: 1)
        var paragraph = TranslationPlanner.paragraphs([first, second], preference: .quality)[0]
        paragraph.translation = "内容"
        let canvas = CGSize(width: 390, height: 844)
        let line = ScreenshotRendering.textLayout(for: first, canvasSize: canvas, textScale: 1)
        let joined = ScreenshotRendering.textLayout(for: paragraph, canvasSize: canvas, textScale: 1)
        XCTAssertEqual(joined.fontSize, line.fontSize, accuracy: 0.0001)
        XCTAssertGreaterThan(joined.sourceRect.height, line.sourceRect.height * 2)
    }

    func testRealVisionKeepsLargeTitleAndSmallBodySizesInALandscapePhoto() async throws {
        let size = CGSize(width: 2048, height: 1152)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            ("MENU SEMANA" as NSString).draw(at: CGPoint(x: 400, y: 140), withAttributes: [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: UIColor.black
            ])
            ("YOGUR O FRUTA" as NSString).draw(at: CGPoint(x: 200, y: 420), withAttributes: [
                .font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.black
            ])
        }
        let recognized = try await ScreenReader.recognize(in: image, source: .spanish)
        var title = try XCTUnwrap(recognized.first { $0.original.contains("MENU") })
        var body = try XCTUnwrap(recognized.first { $0.original.contains("YOGUR") })
        title.translation = "每周菜单"; body.translation = "酸奶水果"
        let canvas = ImageViewport.fittedSize(image: size, container: CGSize(width: 393, height: 852))
        let large = ScreenshotRendering.textLayout(for: title, canvasSize: canvas, textScale: 1)
        let small = ScreenshotRendering.textLayout(for: body, canvasSize: canvas, textScale: 1)
        XCTAssertGreaterThan(large.fontSize / small.fontSize, 1.7)
        XCTAssertLessThan(small.fontSize, 6)
        let document = TranslationDocument(id: UUID(), image: image, blocks: [title, body], source: .spanish, target: .chinese, createdAt: Date())
        let rendered = ScreenshotRendering.translatedImage(document, palette: [:], textScale: 1)
        let restorations = await ScreenshotRendering.restorationsAsync(for: document)
        let cleanFormat = UIGraphicsImageRendererFormat(); cleanFormat.scale = rendered.scale; cleanFormat.opaque = true
        let cleaned = UIGraphicsImageRenderer(size: rendered.size, format: cleanFormat).image { renderer in
            image.draw(in: CGRect(origin: .zero, size: rendered.size))
            for block in document.blocks {
                ScreenshotRendering.drawRestoration(restorations[block.id], canvas: rendered.size, in: renderer.cgContext)
            }
        }
        XCTAssertTrue(try inkRowHeights(cleaned, threshold: 230).isEmpty,
                      "Resizing the restoration must not leave the old letters as gray outlines")
        let originalInk = try inkRowHeights(image)
        let translatedInk = try inkRowHeights(rendered)
        let pixelScale = CGFloat(try XCTUnwrap(rendered.cgImage).width) / CGFloat(try XCTUnwrap(image.cgImage).width)
        let measurements = "original ink: \(originalInk); translated ink: \(translatedInk); pixel scale: \(pixelScale); OCR title/body heights: \(title.originalLineHeight * size.height), \(body.originalLineHeight * size.height); font sizes: \(large.fontSize), \(small.fontSize)"
        let data = XCTAttachment(string: measurements); data.name = "真实Vision字号像素对照"; data.lifetime = .keepAlways; add(data)
        XCTAssertEqual(originalInk.count, 2)
        XCTAssertEqual(translatedInk.count, 2)
        for (original, translated) in zip(originalInk, translatedInk) {
            let expected = CGFloat(original) * pixelScale
            XCTAssertEqual(CGFloat(translated), expected, accuracy: max(1, expected * 0.20), measurements)
        }
        for (name, screenshot) in [("横屏原图-44与22字号", image),
                                    ("横屏背景恢复-无缩放残边", cleaned),
                                    ("横屏译图-保留标题正文比例", rendered)] {
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    /// Measure actual rendered pixels independently of the layout calculation.
    /// The fixture has two black text rows on white, with no borders or graphics.
    private func inkRowHeights(_ image: UIImage, threshold: UInt8 = 128) throws -> [Int] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        let rowBytes = (width + 15) / 16 * 16
        var pixels = [UInt8](repeating: 255, count: rowBytes * height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: rowBytes,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var ranges: [ClosedRange<Int>] = []
        for row in 0..<height where pixels[(row * rowBytes)..<(row * rowBytes + width)].contains(where: { $0 < threshold }) {
            if let previous = ranges.last, row - previous.upperBound <= 3 {
                ranges[ranges.count - 1] = previous.lowerBound...row
            } else { ranges.append(row...row) }
        }
        return ranges.map { $0.upperBound - $0.lowerBound + 1 }.sorted(by: >)
    }

    func testChineseFullScreenAndSettingsSnapshots() async throws {
        settings.interfaceLanguage = .simplifiedChinese
        await attach(Color.black.overlay { ProcessingEdgeGlow() }, name: "处理中-彩色边缘提示")
        await attach(NavigationStack {
            AIRequestOptionsView(options: .constant(AIRequestOptions(preset: .deepSeekFast, bodyJSON: #"{"temperature":0.2}"#)))
        }.environmentObject(settings).environment(\.locale, settings.interfaceLocale), name: "中文-模型预设与自定义参数")
        await attach(List {
            ForEach(AIProviderPreset.allCases) { preset in
                HStack { ProviderIcon(preset: preset).frame(width: 32, height: 32); Text(preset.name) }
            }
        }.preferredColorScheme(.dark), name: "服务商品牌标志-完整显示")

        executionTimeAllowance = 120
        settings.interfaceLanguage = .simplifiedChinese
        settings.source = .english; settings.target = .chinese
        let fixture = snapshotFixture()
        let provider = service("本地测试替身")
        try settings.saveService(provider, keyReplacement: nil)
        try settings.selectService(provider.id, for: .translation)
        settings.grantConsent(for: .translation)
        var injected = services(fixture.blocks)
        injected.aiTranslation = { blocks, _, _, _, _, _ in
            Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, fixture.translations[$0.id]!) })
        }
        let state = AppState(settings: settings, history: HistoryStore(), services: injected)
        state.process(fixture.image)
        for _ in 0..<100 where state.phase != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.document?.blocks.count, fixture.blocks.count)
        try settings.removeService(provider.id)
        await attach(TranslationResultView().environmentObject(state).environmentObject(settings).environmentObject(state.history), name: "中文-全屏结果-无导航栏与底栏")
        await attach(NavigationStack { SettingsView() }.environmentObject(settings).environmentObject(state.history).environment(\.locale, settings.interfaceLocale), name: "中文-设置")
        await attach(NavigationStack { SettingsView() }.environmentObject(settings).environmentObject(state.history).environment(\.locale, settings.interfaceLocale).preferredColorScheme(.dark), name: "中文-深色设置")
        let a = SavedAIService(name: "DeepSeek 日常翻译", preset: .deepSeek, configuration: .init(baseURL: AIProviderPreset.deepSeek.baseURL, model: "deepseek-chat"))
        let b = SavedAIService(name: "Gemini 图像识别", preset: .gemini, configuration: .init(baseURL: AIProviderPreset.gemini.baseURL, model: "gemini-2.5-flash"))
        try settings.saveService(a, keyReplacement: nil); try settings.saveService(b, keyReplacement: nil)
        await attach(NavigationStack { AIServicesView() }.environmentObject(settings).environment(\.locale, settings.interfaceLocale).preferredColorScheme(.dark), name: "中文-多服务管理")
        await attach(NavigationStack { AIServiceEditor(service: b) }.environmentObject(settings).environment(\.locale, settings.interfaceLocale).preferredColorScheme(.dark), name: "中文-自定义服务名称与接口")
        for language in [InterfaceLanguage.spanish, .japanese, .korean] {
            settings.interfaceLanguage = language
            await attach(NavigationStack { SettingsView() }.environmentObject(settings).environmentObject(state.history).environment(\.locale, settings.interfaceLocale), name: language.name + "-设置")
        }
        state.closeResult()
    }

    private func snapshotFixture() -> (image: UIImage, blocks: [RecognizedBlock], translations: [UUID: String]) {
        let lines: [(String, String, CGFloat, CGFloat)] = [
            ("A clearer view", "看见，即理解", 110, 30),
            ("Translate with context, keep the layout.", "理解上下文，保留原有布局。", 178, 16),
            ("On-device by default:", "默认在设备本地处理", 290, 23),
            ("Free. No account. No ads.", "免费使用，无需账号，没有广告。", 344, 16),
            ("Your providers, your choice:", "服务由你自由选择", 592, 24),
            ("Keep multiple AI services ready.", "保存多个 AI 服务，随点随用。", 650, 16)
        ]
        var blocks: [RecognizedBlock] = [], translations: [UUID: String] = [:]
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844)).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 390, height: 844))
            UIColor(red: 0.05, green: 0.12, blue: 0.22, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 480, width: 390, height: 364))
            for (original, translated, y, size) in lines {
                let font = UIFont.systemFont(ofSize: size, weight: .medium)
                let rect = CGRect(x: 24, y: y, width: 342, height: size * 1.5)
                (original as NSString).draw(in: rect, withAttributes: [
                    .font: font,
                    .foregroundColor: y < 480 ? UIColor.black : UIColor.white
                ])
                let block = RecognizedBlock(id: UUID(), original: original, translation: original,
                    boundingBox: CGRect(x: rect.minX / 390, y: 1 - rect.maxY / 844, width: rect.width / 390, height: rect.height / 844), confidence: 1,
                    sourceLineHeight: font.lineHeight / 844)
                blocks.append(block); translations[block.id] = translated
            }
        }
        return (image, blocks, translations)
    }

    @discardableResult private func attach<Content: View>(_ content: Content, name: String, size: CGSize = CGSize(width: 390, height: 844)) async -> UIImage {
        // Hosting in a real window also captures List/Form/NavigationStack, whose
        // UIKit-backed views aren't drawn by SwiftUI's ImageRenderer.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previousWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window: UIWindow
        if let scene = previousWindow?.windowScene ?? scenes.first { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(250))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        var drawn = false
        let image = renderer.image { _ in drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(drawn, "The native window must render successfully for interface review")
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}

@MainActor
private final class SampledBottomPan: UIPanGestureRecognizer {
    var point = CGPoint.zero
    var movement = CGPoint.zero
    var speed = CGPoint.zero
    override func location(in view: UIView?) -> CGPoint { point }
    override func translation(in view: UIView?) -> CGPoint { movement }
    override func velocity(in view: UIView?) -> CGPoint { speed }
}

@MainActor
private final class ServiceTestKeys: APIKeyStoring {
    private var values: [APIKeySlot: String] = [:]
    var sharedWrites = 0
    var failServiceWrites = false
    func read(_ slot: APIKeySlot) throws -> String { values[slot] ?? "" }
    func save(_ key: String, for slot: APIKeySlot) throws {
        if slot == .sharedPreferences { sharedWrites += 1 }
        if case .service = slot, failServiceWrites { throw KeychainError(status: -25308) }
        values[slot] = key
    }
}

@MainActor
private final class MemoryCloudSettings: CloudKeyValueStoring {
    var values: [String: Any] = [:]
    var dictionaryRepresentation: [String: Any] { values }
    var syncCalls = 0
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func synchronize() -> Bool { syncCalls += 1; return true }
}
