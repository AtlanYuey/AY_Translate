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

    private var showsImage: Bool { appState.displayedDocument != nil && (mode != .text || appState.document == nil) }
    private var usesRootDismissGesture: Bool { !showsImage && mode != .text && imageZoom <= 1.01 }

    var body: some View {
        let requestID = appState.appleRequestID
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Color.black
                resultContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .padding(.trailing, 12)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8) + 6)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("result.canvas")
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
            imageZoom = 1
            guard let document = appState.document else { return }
            mode = settings.defaultResultMode
        }
        .task(id: appState.document?.id) {
            guard let document = appState.document else { return }
            let backgroundStart = ContinuousClock.now
            async let colors = ScreenshotRendering.paletteAsync(for: document)
            async let patches = ScreenshotRendering.restorationsAsync(for: document)
            let (sampled, restored) = await (colors, patches)
            guard !Task.isCancelled, appState.document?.id == document.id else { return }
            palette = sampled
            restorations = restored
            let duration = backgroundStart.duration(to: .now).components
            backgroundSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
    }

    @ViewBuilder private var resultContent: some View {
        if let document = appState.displayedDocument, appState.phase != .awaitingConsent {
            ZStack(alignment: .top) {
                if mode == .text && appState.document != nil {
                    FullTextContent(document: document).contentMargins(.bottom, 90)
                } else {
                    ZoomableScreenshot(document: document, showsOriginal: mode == .original, appearance: settings.appearance,
                                       textScale: settings.overlayTextScale, palette: palette, restorations: restorations, resetZoom: resetZoom,
                                       zoomChanged: { imageZoom = $0 }, dismissAction: close) { selectedBlock = $0 }
                        .id(document.id)
                }
                switch appState.phase {
                case .failed:
                    Button { showsRecovery = true } label: {
                        Label("Translation incomplete · Original preserved", systemImage: "exclamationmark.circle")
                            .font(.footnote).padding(.horizontal, 12).padding(.vertical, 8)
                    }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: Capsule()).padding(.top, 14)
                case .reading, .translating, .preparing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(LocalizedStringKey(appState.phase == .reading ? "Reading screen…" : "Translating…")).font(.footnote)
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
                Button(service.name) {
                    do { try settings.selectService(service.id, for: profile); appState.retry() }
                    catch { showsSettings = true }
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
    let palette: [UUID: SampledColor]
    let restorations: [UUID: ScreenshotRendering.RestoredRegion]
    let resetZoom: UUID
    let zoomChanged: (CGFloat) -> Void
    let dismissAction: () -> Void
    let select: (RecognizedBlock) -> Void
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize.zero
    @GestureState private var magnification: CGFloat = 1
    @GestureState private var drag = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            let fitted = ImageViewport.fittedSize(image: document.image.size, container: proxy.size)
            let displayedScale = ImageViewport.scale(scale, magnification: magnification)
            let displayedOffset = ImageViewport.boundedOffset(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), image: fitted, container: proxy.size, scale: displayedScale)
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.94)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: document.image).resizable().frame(width: fitted.width, height: fitted.height)
                    if !showsOriginal {
                        ForEach(document.blocks.filter { $0.placement == .overlay && $0.translation != $0.original }) { block in
                            OverlayTextView(block: block, canvasSize: fitted, appearance: appearance, isRTL: document.target.isRightToLeft, textScale: textScale, color: palette[block.id] ?? SampledColor(red: 1, green: 1, blue: 1), restoration: restorations[block.id]) { select(block) }
                        }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(displayedScale)
                .offset(displayedOffset)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }.onChanged { value in
                zoomChanged(ImageViewport.scale(scale, magnification: value.magnification))
            }.onEnded { value in
                scale = ImageViewport.scale(scale, magnification: value.magnification)
                zoomChanged(scale)
                offset = ImageViewport.boundedOffset(offset, image: fitted, container: proxy.size, scale: scale)
            })
            .simultaneousGesture(DragGesture(minimumDistance: 8).updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                if scale <= 1.01, value.startLocation.y > proxy.size.height - 110,
                   value.translation.height < -100,
                   abs(value.translation.width) < abs(value.translation.height) * 0.65 {
                    dismissAction()
                    return
                }
                offset = ImageViewport.boundedOffset(CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height), image: fitted, container: proxy.size, scale: scale)
            })
            .onChange(of: resetZoom) { _, _ in withAnimation(.snappy) { scale = 1; offset = .zero; zoomChanged(1) } }
            .onChange(of: proxy.size) { _, _ in scale = 1; offset = .zero; zoomChanged(1) }
            .onAppear { zoomChanged(scale) }
        }
    }
}

private struct OverlayTextView: View {
    let block: RecognizedBlock
    let canvasSize: CGSize
    let appearance: TranslationAppearance
    let isRTL: Bool
    let textScale: Double
    let color: SampledColor
    let restoration: ScreenshotRendering.RestoredRegion?
    let onTap: () -> Void
    @State private var revealsOriginal = false

    var body: some View {
        let layout = ScreenshotRendering.textLayout(for: block, canvasSize: canvasSize, textScale: textScale,
                                                   text: revealsOriginal ? block.original : block.translation)
        let patchRect = restoration.map { CGRect(x: $0.rect.minX * canvasSize.width, y: $0.rect.minY * canvasSize.height, width: $0.rect.width * canvasSize.width, height: $0.rect.height * canvasSize.height) } ?? layout.sourceRect
        let drawingRect = layout.textRect.union(patchRect)
        Canvas { context, _ in
            guard layout.canRender, !revealsOriginal else { return }
            let local = ScreenshotRendering.textLayout(for: block, canvasSize: canvasSize, textScale: textScale)
            context.withCGContext { cg in
                cg.translateBy(x: -drawingRect.minX, y: -drawingRect.minY)
                if appearance == .readable {
                    cg.setFillColor(UIColor.black.cgColor)
                    cg.fill(local.sourceRect.insetBy(dx: -local.coverPadding, dy: -local.coverPadding))
                } else if appearance == .natural {
                    ScreenshotRendering.drawRestoration(restoration, canvas: canvasSize, in: cg)
                }
                ScreenshotRendering.drawText(block.translation, layout: local,
                    color: appearance == .readable || !color.usesDarkText ? .white : .black, isRTL: isRTL, in: cg)
            }
        }
        .frame(width: drawingRect.width, height: drawingRect.height)
        .contentShape(Rectangle())
        .position(x: drawingRect.midX, y: drawingRect.midY)
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.15, pressing: { revealsOriginal = $0 }, perform: {})
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
