import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Every photo the app may see: the whole library with full access, or the person's
/// selection with limited access.
struct LibraryTab: View {
    @Environment(\.portQueue) private var queue
    @AppStorage(AppSettings.librarySortKey) private var sort = LibrarySort.captured
    @AppStorage(AppSettings.libraryAscendingKey) private var ascending = false
    @StateObject private var model = AssetListModel(
        scope: .library,
        sort: LibrarySort(rawValue: UserDefaults.standard.string(forKey: AppSettings.librarySortKey) ?? "")
            ?? .captured,
        ascending: UserDefaults.standard.bool(forKey: AppSettings.libraryAscendingKey)
    )
    @State private var status = PhotoLibraryService.status
    @State private var importingFiles = false
    @State private var importError: String?
    @State private var showingConvert = false
    @AppStorage(AppSettings.welcomeSeenKey) private var welcomeSeen = false
    /// Pickglow-style start screen: the full grid is only shown after the
    /// person chooses to browse it, so launch never dumps all photos at once.
    @State private var libraryRevealed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                // Large title in the button row, as in Photos, instead of a band of its own.
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar(libraryRevealed ? .visible : .hidden, for: .navigationBar)
                .toolbar {
                    if libraryRevealed {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("首页") { libraryRevealed = false }
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if libraryRevealed, status == .authorized || status == .limited {
                            SortMenu()
                        }
                        if libraryRevealed {
                            Menu {
                                if status == .limited {
                                    Button {
                                        LimitedLibrary.presentPicker()
                                    } label: {
                                        Label("Select More Photos…", systemImage: "photo.badge.plus")
                                    }
                                }
                                Button {
                                    importingFiles = true
                                } label: {
                                    Label("Import HEIC (and MOV) Files…", systemImage: "folder")
                                }
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                        }
                    }
                }
                .fileImporter(
                    isPresented: $importingFiles,
                    allowedContentTypes: [.heic, .heif, .quickTimeMovie],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls):
                        do {
                            // Copy while the picker still grants access: passing the
                            // security-scoped URLs to the async port queue was the
                            // import bug -- by the time the queue read them, access
                            // was gone and the job failed silently.
                            let copied = try copyImportedFiles(urls)
                            guard !copied.isEmpty else {
                                importError = "没有可导入的照片文件，请选择 HEIC 照片（可同时选同名 MOV 做实况照片）。"
                                return
                            }
                            queue?.port(files: copied)
                        } catch {
                            importError = error.localizedDescription
                        }
                    case .failure(let error):
                        importError = error.localizedDescription
                    }
                }
                .alert("导入失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                    Button("确定") { importError = nil }
                } message: { Text(importError ?? "") }
        }
        .task {
            status = await PhotoLibraryService.requestAccess()
            // Start screen first: do not load the grid until the person
            // chooses to browse it.
        }
        .onChange(of: scenePhase) { _, phase in
            // Access can change in Settings while the app is in the background.
            guard phase == .active else { return }
            let now = PhotoLibraryService.status
            if now != status {
                status = now
                if libraryRevealed, now == .authorized || now == .limited { model.load() }
            }
        }
        .onChange(of: sort) { _, sort in model.setSort(sort, ascending: ascending) }
        .onChange(of: ascending) { _, ascending in model.setSort(sort, ascending: ascending) }
        .fullScreenCover(isPresented: Binding(get: { !welcomeSeen }, set: { if !$0 { welcomeSeen = true } })) {
            WelcomeView(
                onSkip: { welcomeSeen = true },
                onContinue: { welcomeSeen = true },
                onSelectPhotos: { selectPhotos(); welcomeSeen = true },
                onBrowseAll: { reveal(); welcomeSeen = true }
            )
        }
    }

    /// Copy Files picks into the app temp folder immediately, while the
    /// picker access is still live. Returns local (non-security-scoped) URLs.
    private func copyImportedFiles(_ urls: [URL]) throws -> [URL] {
        var copied: [URL] = []
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let directory = try TemporaryFiles.newDirectory()
            let destination = directory.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            copied.append(destination)
        }
        return copied
    }

    private func reveal() {
        libraryRevealed = true
        if status == .authorized || status == .limited { model.load() }
    }

    private func selectPhotos() {
        if status == .limited { LimitedLibrary.presentPicker() }
        reveal()
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .authorized, .limited:
            if libraryRevealed {
                gridContent
            } else {
                PickglowHomeView(
                    status: status,
                    photoCount: model.assets.count,
                    onSelectPhotos: selectPhotos,
                    onImportFiles: { importingFiles = true },
                    onBrowseAll: reveal,
                    onConvert: { showingConvert = true }
                )
                .sheet(isPresented: $showingConvert) { ConvertToHEIFView() }
            }
        case .notDetermined:
            ProgressView()
        default:
            ContentUnavailableView {
                Label("No Access to Photos", systemImage: "lock")
            } description: {
                Text("Floating light reads each original HEIC and its Live Photo video, and saves the styled result. Allow access in Settings.")
            } actions: {
                Button("Open Settings") { LimitedLibrary.openSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var gridContent: some View {
        AssetGridView(model: model) {
            if status == .limited {
                ContentUnavailableView {
                    Label("No Photos Selected", systemImage: "photo.badge.plus")
                } description: {
                    Text("Floating light only sees the photos you choose. Select the photos you want to style.")
                } actions: {
                    Button("Select Photos…") { LimitedLibrary.presentPicker() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo",
                    description: Text("Photos you take or save appear here.")
                )
            }
        }
    }
}
