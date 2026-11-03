import SwiftUI
import Translation
import UIKit

struct TranslationResultView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var settings: AppSettings
    @State private var mode: ResultMode = .overlay
    @State private var selectedBlock: RecognizedBlock?
    @State private var showsSettings = false

    private enum ResultMode: String, CaseIterable, Identifiable {
        case overlay = "Translated", original = "Original", text = "Full Text"
        var id: Self { self }
    }

    var body: some View {
        // Capture this render's request ID. An older view-bound session must
        // never apply its responses to a newer screenshot or language pair.
        let appleRequestID = appState.appleRequestID
        NavigationStack {
            Group {
                switch appState.phase {
                case .awaitingConsent:
                    consentView
                case .reading, .translating, .preparing:
                    ProcessingView(phase: appState.phase, completed: appState.translatedBlockCount, total: appState.totalBlockCount)
                case .failed(let message):
                    failureView(message)
                case .ready:
                    if let document = appState.document {
                        if mode == .text {
                            FullTextContent(document: document)
                        } else {
                            ZoomableScreenshot(document: document, showsOriginal: mode == .original, appearance: settings.appearance, textScale: settings.overlayTextScale) { selectedBlock = $0 }
                                .id(document.id)
                        }
                    }
                case .idle:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
            .navigationTitle(appState.document?.target.name ?? "Translate Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { appState.closeResult() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let document = appState.document {
                        Menu {
                            Button("Copy Translation", systemImage: "doc.on.doc") { UIPasteboard.general.string = document.translatedText }
                            Button("Copy Original", systemImage: "doc.on.doc") { UIPasteboard.general.string = document.originalText }
                        } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy text")
                    }
                    Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Engine and display settings")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if appState.phase == .ready { displayControls }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = appState.notice, appState.phase == .ready {
                    Text(notice).font(.footnote).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity).background(.bar)
                }
            }
        }
        .translationTask(appState.translationConfiguration) { session in
            await appState.translate(using: session, processID: appleRequestID)
        }
        .sheet(item: $selectedBlock) { block in
            TextDetailSheet(block: block, isRTL: appState.document?.target.isRightToLeft ?? false)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSettings = false } } }
            }
        }
        .onChange(of: appState.document?.id, initial: true) { _, _ in
            mode = appState.document?.blocks.contains(where: { $0.placement == .overlay }) == false ? .text : .overlay
        }
    }

    private var displayControls: some View {
        VStack(spacing: 8) {
            Picker("Result view", selection: $mode) {
                ForEach(ResultMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if mode == .overlay {
                HStack {
                    Image(systemName: "textformat.size")
                    Slider(value: $settings.overlayTextScale, in: 0.8...1.8, step: 0.1)
                        .accessibilityLabel("Translation text size")
                    Text(settings.overlayTextScale, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.caption)
                }
                Text("Pinch to zoom · Drag to pan · Tap text to read in full")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).background(.bar)
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
            }.padding(28)
        }
    }

    private func failureView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                Text(message).font(.headline).multilineTextAlignment(.center)
                if appState.hasSourceImage {
                    Button("Try Again") { appState.retry() }.buttonStyle(.borderedProminent)
                    Menu("Retry OCR with…") {
                        ForEach(OCREngine.allCases) { engine in Button(engine.name) { appState.retry(using: engine) } }
                    }.buttonStyle(.bordered)
                    Button("Use Free Apple Engines") { appState.useAppleEngines() }
                }
                if appState.document != nil {
                    Button("Read Recognized Text") { mode = .text; appState.viewRecognizedText() }
                }
                Button("Configure Engines") { showsSettings = true }
            }.padding(30)
        }
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
            Text(phase == .reading ? "Reading screen…" : "Translating…").font(.title3.weight(.semibold))
            Text(phase == .reading ? "Finding text and its position" : "Preserving meaning and the original layout")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct ZoomableScreenshot: View {
    let document: TranslationDocument
    let showsOriginal: Bool
    let appearance: TranslationAppearance
    let textScale: Double
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
                        ForEach(document.blocks.filter { $0.placement == .overlay }) { block in
                            OverlayTextView(block: block, canvasSize: fitted, appearance: appearance, isRTL: document.target.isRightToLeft, textScale: textScale) { select(block) }
                        }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .scaleEffect(displayedScale)
                .offset(displayedOffset)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                Button {
                    withAnimation(.snappy) { scale = 1; offset = .zero }
                } label: {
                    Label("Reset Zoom", systemImage: "arrow.counterclockwise").labelStyle(.iconOnly).padding(12).background(.regularMaterial, in: Circle())
                }.padding(12).accessibilityLabel("Reset zoom and position")
            }
            .contentShape(Rectangle())
            .clipped()
            .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }.onEnded { value in
                scale = ImageViewport.scale(scale, magnification: value.magnification)
                offset = ImageViewport.boundedOffset(offset, image: fitted, container: proxy.size, scale: scale)
            })
            .simultaneousGesture(DragGesture(minimumDistance: 8).updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                offset = ImageViewport.boundedOffset(CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height), image: fitted, container: proxy.size, scale: scale)
            })
            .onChange(of: proxy.size) { _, _ in scale = 1; offset = .zero }
        }
    }
}

private struct OverlayTextView: View {
    let block: RecognizedBlock
    let canvasSize: CGSize
    let appearance: TranslationAppearance
    let isRTL: Bool
    let textScale: Double
    let onTap: () -> Void
    @State private var revealsOriginal = false

    var body: some View {
        let rect = CGRect(x: block.boundingBox.minX * canvasSize.width, y: (1 - block.boundingBox.maxY) * canvasSize.height, width: max(block.boundingBox.width * canvasSize.width, 24), height: max(block.boundingBox.height * canvasSize.height, 16))
        let fontSize = max(12, min(rect.height / 1.15, max(12, min(rect.height * 0.65, 28)) * textScale))
        Text(revealsOriginal ? block.original : block.translation)
            .font(.system(size: fontSize, weight: .medium))
            .lineLimit(max(1, Int(rect.height / (fontSize * 1.15))))
            .truncationMode(.tail)
            .multilineTextAlignment(isRTL ? .trailing : .leading)
            .padding(.horizontal, 2)
            .frame(width: rect.width, height: rect.height, alignment: isRTL ? .trailing : .leading)
            .foregroundStyle(appearance == .readable ? Color.white : Color.primary)
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
        case .natural: Rectangle().fill(.ultraThinMaterial)
        case .readable: Color.black.opacity(0.88)
        case .minimal: Color(uiColor: .systemBackground).opacity(0.78)
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
