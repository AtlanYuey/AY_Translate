import SwiftUI
import Translation
import UIKit

struct TranslationResultView: View {
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ResultDisplayMode = .overlay
    @State private var selectedBlock: RecognizedBlock?
    @State private var showsSettings = false
    @State private var showsNotice = false
    @State private var resetZoom = UUID()
    @State private var showsTiming = false
    @State private var backgroundSeconds: Double = 0
    @State private var palette: [UUID: SampledColor] = [:]
    @State private var restorations: [UUID: ScreenshotRendering.RestoredRegion] = [:]
    @State private var imageZoom: CGFloat = 1
    @State private var isClosing = false
    @State private var showsRecovery = false
    @State private var settingsAfterRecovery = false
    private struct RenderingID: Hashable { let document: UUID; let showUnchanged: Bool }
    private var renderingID: RenderingID? {
        guard appState.phase == .ready, let id = appState.document?.id else { return nil }
        return RenderingID(document: id, showUnchanged: settings.showsUnchangedText)
    }
    @State private var preparedDocumentID: RenderingID?

    private var showsImage: Bool { appState.displayedDocument != nil && (mode != .text || appState.document == nil) }
    private var preparingImage: Bool { appState.phase == .ready && appState.document != nil && preparedDocumentID != renderingID }
    private var processing: Bool { appState.isProcessing || preparingImage }
    private var usesRootDismissGesture: Bool { !processing && !showsImage && mode != .text && imageZoom <= 1.01 }

    var body: some View {
        let requestID = appState.appleRequestID
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                // Before the shared image arrives, keep the host visible. An
                // opaque black loading canvas was the flash after screenshot.
                if appState.hasSourceImage || (appState.phase != .idle && appState.phase != .loading) { Color.black }
                else { Color.clear }
                resultContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if processing { ProcessingEdgeGlow() }
                controls
                    .padding(.trailing, 12)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8) + 6)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("result.canvas")
            .accessibilityValue(Text(processing ? "Processing…" : "Ready"))
            .simultaneousGesture(DragGesture(minimumDistance: 45).onEnded { value in
                // The image handles its own drag to avoid competing parent and
                // child recognizers. This fallback also lets loading/error
                // screens be dismissed from their bottom margin.
                if usesRootDismissGesture,
                   value.startLocation.y > geometry.size.height - 110,
                   value.translation.height < -100,
                   abs(value.translation.width) < abs(value.translation.height) * 0.65 {
                    close()
                }
            }, including: usesRootDismissGesture ? .all : .subviews)
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .environment(\.locale, settings.interfaceLocale)
        .translationTask(appState.translationConfiguration) { session in
            await appState.translate(using: session, processID: requestID)
        }
        .sheet(item: $selectedBlock) { block in
            TextDetailSheet(block: block, isRTL: appState.document?.target.isRightToLeft ?? false)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSettings = false } }
                }
            }
        }
        .sheet(isPresented: $showsRecovery, onDismiss: {
            if settingsAfterRecovery && !isClosing { showsSettings = true }
            settingsAfterRecovery = false
        }) {
            if case .failed(let message) = appState.phase {
                failureView(message).presentationDetents([.medium, .large])
            }
        }
        .alert("Processing Time", isPresented: $showsTiming) { Button("OK", role: .cancel) {} } message: {
            Text(AppLocalization.formatted("OCR %.2f s · Translation %.2f s · Background %.2f s", appState.recognitionSeconds, appState.translationSeconds, backgroundSeconds, language: settings.interfaceLanguage))
        }
        .alert("Recognition Note", isPresented: $showsNotice) { Button("OK", role: .cancel) {} } message: {
            Text(settings.text(appState.notice ?? ""))
        }
        .onChange(of: appState.document?.id, initial: true) { _, _ in
            palette = [:]
            restorations = [:]
            backgroundSeconds = 0
            preparedDocumentID = nil
            imageZoom = 1
            guard appState.document != nil else { return }
            mode = settings.defaultResultMode
        }
        .task(id: renderingID) {
            // Vision/model decoding and inpainting must not allocate their
            // largest buffers at the same time inside the Share extension.
            guard appState.phase == .ready, let document = appState.document else { return }
            let preparation = renderingID
            let showUnchanged = settings.showsUnchangedText
            appState.beginRendering(id: document.id)
            let backgroundStart = ContinuousClock.now
            async let colors = ScreenshotRendering.paletteAsync(for: document)
            async let patches = ScreenshotRendering.restorationsAsync(for: document, showUnchanged: showUnchanged)
            let (sampled, restored) = await (colors, patches)
            guard !Task.isCancelled, appState.document?.id == document.id else { return }
            palette = sampled
            restorations = restored
            let duration = backgroundStart.duration(to: .now).components
            backgroundSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            preparedDocumentID = preparation
            appState.finishRendering(id: document.id)
        }
    }

    @ViewBuilder private var resultContent: some View {
        if let document = appState.displayedDocument, appState.phase != .awaitingConsent {
            ZStack(alignment: .top) {
                if mode == .text && appState.document != nil {
                    FullTextContent(document: document).contentMargins(.bottom, 90)
                } else {
                    ZoomableScreenshot(document: document, showsOriginal: mode == .original || processing, appearance: settings.appearance,
                                       textScale: settings.overlayTextScale, showUnchanged: settings.showsUnchangedText, allowsTextDetails: settings.showsTextDetailsOnTap, palette: palette, restorations: restorations, resetZoom: resetZoom,
                                       zoomChanged: { imageZoom = $0 }, allowsDismiss: !processing, dismissAction: { if !processing { close() } }) { selectedBlock = $0 }
                        .id(document.id)
                }
                switch appState.phase {
                case .ready where preparingImage:
                    ProgressView("Preparing image…").font(.footnote).padding(12)
                        .glassEffect(.regular, in: Capsule()).padding(.top, 14)
                case .failed:
                    Button { showsRecovery = true } label: {
                        Label("Translation incomplete · Original preserved", systemImage: "exclamationmark.circle")
                            .font(.footnote).padding(.horizontal, 12).padding(.vertical, 8)
                    }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule()).padding(.top, 14)
                case .loading, .reading, .translating, .preparing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(LocalizedStringKey(appState.phase == .reading ? "Reading screen…" : "Translating…")).font(.footnote)
                        Text(verbatim: "→ " + document.target.nativeName).font(.footnote.weight(.medium))
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule()).padding(.top, 14)
                default: EmptyView()
                }
            }
        } else {
            switch appState.phase {
            case .awaitingConsent: consentView
            case .failed(let message): failureView(message)
            case .idle: EmptyView()
            default: ProgressView()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if appState.document != nil {
                Menu {
                    resultMenu
                } label: {
                    Image(systemName: mode == .original ? "text.viewfinder" : "rectangle.on.rectangle").floatingResultIcon()
                } primaryAction: {
                    mode = mode == .original ? .overlay : .original
                }
                .accessibilityLabel(LocalizedStringKey(mode == .original ? "Show Translation" : "Show Original"))
                .accessibilityHint("Touch and hold for copy, engines and settings")
                .accessibilityIdentifier("result.original")
            } else {
                Menu { resultMenu } label: { Image(systemName: "ellipsis").floatingResultIcon() }
                    .accessibilityLabel("More Actions").accessibilityIdentifier("result.more")
            }
            Button(action: close) { Image(systemName: "xmark").floatingResultIcon() }
                .accessibilityLabel("Close").accessibilityIdentifier("result.close")
        }
        .padding(3)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    @ViewBuilder private var resultMenu: some View {
                if let document = appState.document {
                    Button("Copy Translation", systemImage: "doc.on.doc") { UIPasteboard.general.string = document.translatedText }
                    Button("Copy Original", systemImage: "doc.on.doc") { UIPasteboard.general.string = document.originalText }
                    Button(LocalizedStringKey(mode == .text ? "Translated" : "Full Text"), systemImage: "text.alignleft") { mode = mode == .text ? .overlay : .text }
                    Button("Reset Zoom", systemImage: "arrow.counterclockwise") { resetZoom = UUID() }
                    Divider()
                }
                engineMenu(.ocr)
                engineMenu(.translation)
                Menu("Target Language") {
                    ForEach(AppLanguage.targetLanguages) { language in
                        Button(language.nativeName) { settings.target = language; appState.retry() }
                    }
                }
                Button("Processing Time", systemImage: "stopwatch") { showsTiming = true }
                Button("Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                if case .failed = appState.phase {
                    Button("Translation Details", systemImage: "exclamationmark.circle") { showsRecovery = true }
                    Button("Try Again", systemImage: "arrow.clockwise") { appState.retry() }
                }
                if appState.notice != nil { Button("Recognition Note", systemImage: "info.circle") { showsNotice = true } }
    }

    private func engineMenu(_ profile: AIProfile) -> some View {
        Menu {
            Button(LocalizedStringKey(profile == .ocr ? "Apple Vision · Free" : "Apple Translation · Free"), systemImage: "apple.logo") {
                try? settings.selectService(nil, for: profile)
                appState.retry()
            }
            ForEach(settings.serviceCatalog.services.filter { profile != .ocr || $0.supportsVision }) { service in
                Button {
                    do { try settings.selectService(service.id, for: profile); appState.retry() }
                    catch { showsSettings = true }
                } label: {
                    Label { Text(service.name) } icon: { ProviderIcon(preset: service.preset) }
                }
            }
        } label: { Text(LocalizedStringKey(profile == .ocr ? "OCR Engine" : "Translation Engine")) }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        appState.closeResult()
        if let onClose { onClose() } else { dismiss() }
    }

    private var consentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Use your selected AI service?", systemImage: "cloud").font(.title2.bold())
                Text("Only the AI engines you selected send data. Your provider may charge for requests and apply its own retention policy.")
                ForEach(appState.consentDestinations, id: \.self) { Text($0).font(.callout.weight(.medium)) }
                Text("Permission is remembered for this endpoint and model. You can revoke it in Privacy settings.").font(.footnote).foregroundStyle(.secondary)
                Button("Continue with AI") { appState.allowCloudProcessing() }.buttonStyle(.borderedProminent)
                Button("Use Free Apple Engines") { appState.useAppleEngines() }.buttonStyle(.bordered)
            }.padding(28).padding(.vertical, 70)
        }.background(Color(uiColor: .systemBackground))
    }

    private func failureView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                Text(settings.text(message)).font(.headline).multilineTextAlignment(.center)
                if appState.hasSourceImage {
                    Button("Try Again") { showsRecovery = false; appState.retry() }.buttonStyle(.borderedProminent)
                    Button("Use Free Apple Engines") { showsRecovery = false; appState.useAppleEngines() }
                }
                if appState.document != nil {
                    Button("Read Recognized Text") { showsRecovery = false; mode = .text; appState.viewRecognizedText() }
                }
                Button("Configure Engines") {
                    if showsRecovery { settingsAfterRecovery = true; showsRecovery = false }
                    else { showsSettings = true }
                }
            }.padding(30).padding(.vertical, 70)
        }.background(Color(uiColor: .systemBackground))
    }
}

private extension Image {
    func floatingResultIcon() -> some View {
        self.font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary).frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

private struct ProcessingView: View {
    let phase: AppState.Phase
    let completed: Int
    let total: Int
    var body: some View {
        VStack(spacing: 18) {
            if phase == .translating && total > 0 {
                ProgressView(value: Double(completed), total: Double(total)).frame(width: 180)
            } else { ProgressView().controlSize(.large) }
            Text(LocalizedStringKey(phase == .reading ? "Reading screen…" : "Translating…")).font(.title3.weight(.semibold))
            Text(LocalizedStringKey(phase == .reading ? "Finding text and its position" : "Preserving meaning and the original layout"))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct ZoomableScreenshot: View {
    let document: TranslationDocument
    let showsOriginal: Bool
    let appearance: TranslationAppearance
    let textScale: Double
    let showUnchanged: Bool
    let allowsTextDetails: Bool
    let palette: [UUID: SampledColor]
    let restorations: [UUID: ScreenshotRendering.RestoredRegion]
    let resetZoom: UUID
    let zoomChanged: (CGFloat) -> Void
    let allowsDismiss: Bool
    let dismissAction: () -> Void
    let select: (RecognizedBlock) -> Void

    var body: some View {
        GeometryReader { proxy in
            let fitted = ImageViewport.fittedSize(image: document.image.size, container: proxy.size)
            let layouts = ScreenshotRendering.textLayouts(for: document.blocks, canvasSize: fitted, textScale: textScale)
            NativeZoomScroll(size: fitted, resetID: resetZoom, zoomChanged: zoomChanged, allowsDismiss: allowsDismiss, dismissAction: dismissAction) {
                ZStack(alignment: .topLeading) {
                    Image(uiImage: document.image).resizable().frame(width: fitted.width, height: fitted.height)
                    if !showsOriginal {
                        Canvas { context, _ in
                            context.withCGContext { cg in
                                for block in document.blocks where block.shouldOverlay(showUnchanged: showUnchanged) {
                                    guard let layout = layouts[block.id] else { continue }
                                    guard layout.canRender else { continue }
                                    if appearance == .natural {
                                        ScreenshotRendering.drawRestoration(restorations[block.id], canvas: fitted, in: cg)
                                    } else if appearance == .readable {
                                        cg.setFillColor(UIColor.black.cgColor)
                                        cg.fill(layout.sourceRect.insetBy(dx: -layout.coverPadding, dy: -layout.coverPadding))
                                    }
                                }
                            }
                        }.frame(width: fitted.width, height: fitted.height).allowsHitTesting(false)
                        ForEach(document.blocks.filter { $0.shouldOverlay(showUnchanged: showUnchanged) }) { block in
                            if let layout = layouts[block.id] {
                            OverlayTextView(block: block, layout: layout, canvasSize: fitted, appearance: appearance, isRTL: document.target.isRightToLeft, textScale: textScale, color: palette[block.id] ?? SampledColor(red: 1, green: 1, blue: 1), restoration: restorations[block.id]) { select(block) }
                                .allowsHitTesting(allowsTextDetails)
                            }
                        }
                    }
                }.frame(width: fitted.width, height: fitted.height)
            }
        }
    }
}

private struct OverlayTextView: View {
    let block: RecognizedBlock
    let layout: ScreenshotRendering.TextLayout
    let canvasSize: CGSize
    let appearance: TranslationAppearance
    let isRTL: Bool
    let textScale: Double
    let color: SampledColor
    let restoration: ScreenshotRendering.RestoredRegion?
    let onTap: () -> Void

    var body: some View {
        let drawingRect = layout.textRect.insetBy(dx: -layout.fontSize * 0.08, dy: -layout.fontSize * 0.08)
        Canvas { context, _ in
            guard layout.canRender else { return }
            context.withCGContext { cg in
                cg.translateBy(x: -drawingRect.minX, y: -drawingRect.minY)
                ScreenshotRendering.drawText(block.translation, layout: layout,
                    color: appearance == .readable || !color.usesDarkText ? .white : .black, isRTL: isRTL, in: cg)
            }
        }
        .frame(width: drawingRect.width, height: drawingRect.height)
        .contentShape(Rectangle())
        .position(x: drawingRect.midX, y: drawingRect.midY)
        .onTapGesture(perform: onTap)

        .accessibilityLabel("\(block.original), \(block.translation)")
        .accessibilityHint("Tap to read and copy the full translation")
    }

    @ViewBuilder private var background: some View {
        switch appearance {
        case .natural: Color(red: color.red, green: color.green, blue: color.blue)
        case .readable: Color.black.opacity(0.88)
        case .minimal: Color.clear
        }
    }
}

private struct TextDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let block: RecognizedBlock
    let isRTL: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section("Original") {
                    Text(block.original).textSelection(.enabled)
                    Button("Copy Original") { UIPasteboard.general.string = block.original }
                }
                Section("Translation") {
                    Text(block.translation).textSelection(.enabled).frame(maxWidth: .infinity, alignment: isRTL ? .trailing : .leading)
                        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                    Button("Copy Translation") { UIPasteboard.general.string = block.translation }
                }
            }
            .navigationTitle("Full Translation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct FullTextContent: View {
    let document: TranslationDocument
    var body: some View {
        List {
            Section("Original") { Text(document.originalText).textSelection(.enabled) }
            Section("Translation") {
                Text(document.translatedText).textSelection(.enabled)
                    .environment(\.layoutDirection, document.target.isRightToLeft ? .rightToLeft : .leftToRight)
            }
        }
    }
}
