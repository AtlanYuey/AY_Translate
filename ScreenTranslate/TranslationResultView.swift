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
    @State private var palette: [UUID: SampledColor] = [:]
    @State private var imageZoom: CGFloat = 1

    var body: some View {
        let requestID = appState.appleRequestID
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                Color.black
                resultContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                controls
                    .padding(.trailing, 18)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 12) + 12)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 45).onEnded { value in
                if appState.phase == .ready, mode != .text, imageZoom <= 1.01,
                   value.startLocation.y > geometry.size.height - 110,
                   value.translation.height < -100,
                   abs(value.translation.width) < abs(value.translation.height) * 0.65 {
                    close()
                }
            })
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
        .alert("Recognition Note", isPresented: $showsNotice) { Button("OK", role: .cancel) {} } message: {
            Text(settings.text(appState.notice ?? ""))
        }
        .task(id: appState.document?.id) {
            guard let document = appState.document else { return }
            palette = ScreenshotRendering.palette(for: document)
            imageZoom = 1
            mode = document.blocks.contains(where: { $0.placement == .overlay }) ? settings.defaultResultMode : .text
        }
    }

    @ViewBuilder private var resultContent: some View {
        switch appState.phase {
        case .awaitingConsent: consentView
        case .reading, .translating, .preparing:
            ProcessingView(phase: appState.phase, completed: appState.translatedBlockCount, total: appState.totalBlockCount)
                .foregroundStyle(.white)
        case .failed(let message): failureView(message)
        case .ready:
            if let document = appState.document {
                if mode == .text {
                    FullTextContent(document: document).contentMargins(.bottom, 90)
                } else {
                    ZoomableScreenshot(document: document, showsOriginal: mode == .original, appearance: settings.appearance,
                                       textScale: settings.overlayTextScale, palette: palette, resetZoom: resetZoom,
                                       zoomChanged: { imageZoom = $0 }) { selectedBlock = $0 }
                        .id(document.id)
                }
            }
        case .idle: EmptyView()
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Menu {
                if let document = appState.document {
                    Button("Copy Translation", systemImage: "doc.on.doc") { UIPasteboard.general.string = document.translatedText }
                    Button("Copy Original", systemImage: "doc.on.doc") { UIPasteboard.general.string = document.originalText }
                    Button(LocalizedStringKey(mode == .text ? "Translated" : "Full Text"), systemImage: "text.alignleft") { mode = mode == .text ? .overlay : .text }
                    Button("Reset Zoom", systemImage: "arrow.counterclockwise") { resetZoom = UUID() }
                    Divider()
                }
                engineMenu(.ocr)
                engineMenu(.translation)
                Button("Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                if appState.notice != nil { Button("Recognition Note", systemImage: "info.circle") { showsNotice = true } }
            } label: {
                Image(systemName: appState.notice == nil ? "ellipsis" : "ellipsis.circle").floatingResultIcon()
            }
            .accessibilityLabel("More Actions").accessibilityIdentifier("result.more")
            if appState.phase == .ready, appState.document != nil {
                Button { mode = mode == .original ? .overlay : .original } label: {
                    Image(systemName: mode == .original ? "text.viewfinder" : "rectangle.on.rectangle").floatingResultIcon()
                }
                .accessibilityLabel(LocalizedStringKey(mode == .original ? "Show Translation" : "Show Original"))
                .accessibilityIdentifier("result.original")
            }
            Button(action: close) { Image(systemName: "xmark").floatingResultIcon() }
                .accessibilityLabel("Close").accessibilityIdentifier("result.close")
        }
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
                    Button("Try Again") { appState.retry() }.buttonStyle(.borderedProminent)
                    Button("Use Free Apple Engines") { appState.useAppleEngines() }
                }
                if appState.document != nil {
                    Button("Read Recognized Text") { mode = .text; appState.viewRecognizedText() }
                }
                Button("Configure Engines") { showsSettings = true }
            }.padding(30).padding(.vertical, 70)
        }.background(Color(uiColor: .systemBackground))
    }
}

private extension Image {
    func floatingResultIcon() -> some View {
        self.font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.primary).frame(width: 48, height: 48)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
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
    let resetZoom: UUID
    let zoomChanged: (CGFloat) -> Void
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
                            OverlayTextView(block: block, canvasSize: fitted, appearance: appearance, isRTL: document.target.isRightToLeft, textScale: textScale, color: palette[block.id] ?? SampledColor(red: 1, green: 1, blue: 1)) { select(block) }
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
    let onTap: () -> Void
    @State private var revealsOriginal = false

    var body: some View {
        let rect = CGRect(x: block.boundingBox.minX * canvasSize.width, y: (1 - block.boundingBox.maxY) * canvasSize.height, width: max(block.boundingBox.width * canvasSize.width, 24), height: max(block.boundingBox.height * canvasSize.height, 16))
        let fontSize = ScreenshotRendering.fittedFontSize(for: revealsOriginal ? block.original : block.translation, in: rect, textScale: textScale)
        Text(revealsOriginal ? block.original : block.translation)
            .font(.system(size: fontSize, weight: .medium))
            .lineLimit(max(1, Int(rect.height / (fontSize * 1.15))))
            .truncationMode(.tail)
            .multilineTextAlignment(isRTL ? .trailing : .leading)
            .padding(.horizontal, 2)
            .frame(width: rect.width, height: rect.height, alignment: isRTL ? .trailing : .leading)
            .foregroundStyle(appearance == .readable || !color.usesDarkText ? Color.white : Color.black)
            .background { background }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .position(x: rect.midX, y: rect.midY)
            .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
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
