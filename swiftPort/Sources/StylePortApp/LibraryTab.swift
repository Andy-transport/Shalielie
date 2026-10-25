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
                    if case .success(let urls) = result { queue?.port(files: urls) }
                }
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
                    onBrowseAll: reveal
                )
            }
        case .notDetermined:
            ProgressView()
        default:
            ContentUnavailableView {
                Label("No Access to Photos", systemImage: "lock")
            } description: {
                Text("浮光 reads each original HEIC and its Live Photo video, and saves the styled result. Allow access in Settings.")
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
                    Text("浮光 only sees the photos you choose. Select the photos you want to style.")
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
