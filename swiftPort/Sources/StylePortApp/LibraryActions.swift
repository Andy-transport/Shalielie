import CoreLocation
import MapKit
import Photos
import SwiftUI
import UIKit

/// PhotoKit library operations. None of these delete assets from the library.
enum LibraryActions {
    static func update(_ assets: [PHAsset], _ change: @escaping (PHAssetChangeRequest, PHAsset) -> Void) async throws {
        try await PhotoLibraryService().requireReadWriteAccess()
        try await PHPhotoLibrary.shared().performChanges {
            for asset in assets { change(PHAssetChangeRequest(for: asset), asset) }
        }
    }

    @MainActor
    static func copy(_ assets: [PHAsset]) async throws {
        var items: [[String: Any]] = []
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let photo = resources.first(where: { $0.type == .fullSizePhoto })
                    ?? resources.first(where: { $0.type == .photo }) else { throw LibraryError.assetUnavailable }
            items.append([photo.uniformTypeIdentifier: try await PhotoLibraryService.data(for: photo)])
        }
        UIPasteboard.general.setItems(items, options: [.localOnly: true])
    }

    static func duplicate(_ assets: [PHAsset]) async throws {
        try await PhotoLibraryService().requireReadWriteAccess()
        struct Copy {
            let asset: PHAsset
            let photo: URL
            let video: URL?
            let filename: String
        }
        var copies: [Copy] = []
        defer {
            for copy in copies {
                try? FileManager.default.removeItem(at: copy.photo)
                if let video = copy.video { try? FileManager.default.removeItem(at: video) }
            }
        }
        for asset in assets {
            let resources = PHAssetResource.assetResources(for: asset)
            guard let photo = resources.first(where: { $0.type == .fullSizePhoto })
                    ?? resources.first(where: { $0.type == .photo }) else { throw LibraryError.assetUnavailable }
            let paired = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo })
            let file = try await PhotoLibraryService.temporaryCopy(of: photo)
            do {
                let video: URL?
                if let paired { video = try await PhotoLibraryService.temporaryCopy(of: paired) } else { video = nil }
                copies.append(Copy(asset: asset, photo: file, video: video, filename: photo.originalFilename))
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
        }
        let prepared = copies
        try await PHPhotoLibrary.shared().performChanges {
            for copy in prepared {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = copy.filename
                request.addResource(with: .photo, fileURL: copy.photo, options: options)
                if let video = copy.video { request.addResource(with: .pairedVideo, fileURL: video, options: nil) }
                request.creationDate = copy.asset.creationDate
                request.location = copy.asset.location
                request.isFavorite = copy.asset.isFavorite
            }
        }
    }

    static func albums() -> [PHAssetCollection] {
        let fetched = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        return (0..<fetched.count).map { fetched.object(at: $0) }
            .filter { $0.canPerform(.addContent) }
            .sorted { ($0.localizedTitle ?? "").localizedStandardCompare($1.localizedTitle ?? "") == .orderedAscending }
    }

    static func add(_ assets: [PHAsset], to album: PHAssetCollection, movingFrom source: PHAssetCollection?) async throws {
        guard album.canPerform(.addContent), source?.localIdentifier != album.localIdentifier else {
            throw LibraryError.saveFailed("Choose a different editable destination album.")
        }
        if let source, !source.canPerform(.removeContent) {
            throw LibraryError.saveFailed("The source album can't be changed.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
            if let source { PHAssetCollectionChangeRequest(for: source)?.removeAssets(assets as NSArray) }
        }
    }
}

struct LibrarySelectionActions: View {
    let assets: [PHAsset]
    let sourceAlbum: PHAssetCollection?
    var changed: () -> Void
    @State private var busy = false
    @State private var hiding = false
    @State private var sheet: Editor?
    @State private var message: String?
    private enum Editor: String, Identifiable {
        case album, move, date, location
        var id: String { rawValue }
    }
    private var allFavorite: Bool { !assets.isEmpty && assets.allSatisfy(\.isFavorite) }
    private var allHidden: Bool { !assets.isEmpty && assets.allSatisfy(\.isHidden) }

    var body: some View {
        Menu {
            Button { run("Copied") { try await LibraryActions.copy(assets) } } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button { run("Duplicated") { try await LibraryActions.duplicate(assets) } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button {
                let value = !allFavorite
                run(value ? "Added to Favorites" : "Removed from Favorites") {
                    try await LibraryActions.update(assets) { request, _ in request.isFavorite = value }
                }
            } label: { Label(allFavorite ? "Remove from Favorites" : "Favorite", systemImage: allFavorite ? "heart.slash" : "heart") }
            Button { hiding = true } label: { Label(allHidden ? "Unhide" : "Hide", systemImage: allHidden ? "eye" : "eye.slash") }
            Divider()
            Button { sheet = .album } label: { Label("Add to Album…", systemImage: "rectangle.stack.badge.plus") }
            Button { sheet = .move } label: { Label("Move Between Albums…", systemImage: "folder") }
            Divider()
            Button { sheet = .date } label: { Label("Adjust Date & Time…", systemImage: "calendar.badge.clock") }
            Button { sheet = .location } label: { Label("Adjust Location…", systemImage: "mappin.and.ellipse") }
        } label: {
            if busy { ProgressView() }
            else { Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
        }
        .disabled(assets.isEmpty || busy)
        .confirmationDialog(allHidden ? "Unhide selected photos?" : "Hide selected photos?", isPresented: $hiding) {
            Button(allHidden ? "Unhide" : "Hide") {
                let value = !allHidden
                run(value ? "Hidden" : "Unhidden") {
                    try await LibraryActions.update(assets) { request, _ in request.isHidden = value }
                }
            }
        } message: { Text("This changes the selected photos in your library. Hidden photos remain in the Hidden album.") }
        .sheet(item: $sheet) { editor in
            switch editor {
            case .album, .move:
                AlbumActionSheet(assets: assets, moving: editor == .move, initialSource: sourceAlbum, completed: changed)
            case .date: DateActionSheet(assets: assets, completed: changed)
            case .location: LocationActionSheet(assets: assets, completed: changed)
            }
        }
        .alert("Library", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func run(_ success: String, action: @escaping () async throws -> Void) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action(); changed(); message = success }
            catch { message = error.localizedDescription }
        }
    }
}

private struct AlbumActionSheet: View {
    let assets: [PHAsset]
    let moving: Bool
    let initialSource: PHAssetCollection?
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [PHAssetCollection] = []
    @State private var source = ""
    @State private var destination = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if moving {
                    Picker("From Album", selection: $source) {
                        Text("Choose an Album").tag("")
                        ForEach(albums.filter { $0.canPerform(.removeContent) }, id: \.localIdentifier) {
                            Text($0.localizedTitle ?? "Album").tag($0.localIdentifier)
                        }
                    }
                }
                Picker("To Album", selection: $destination) {
                    Text("Choose an Album").tag("")
                    ForEach(albums, id: \.localIdentifier) { Text($0.localizedTitle ?? "Album").tag($0.localIdentifier) }
                }
                Text(moving ? "Selected photos are added to the destination and removed only from the chosen source album. They stay in your library and other albums."
                     : "The selected photos stay in your library and existing albums.").font(.footnote).foregroundStyle(.secondary)
                if albums.isEmpty { Text("Create an editable album in Photos first.") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(moving ? "Move Photos" : "Add to Album")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(moving ? "Move" : "Add") { save() }
                        .disabled(busy || destination.isEmpty || (moving && (source.isEmpty || source == destination)))
                }
            }
            .interactiveDismissDisabled(busy)
            .task { albums = LibraryActions.albums(); source = initialSource?.localIdentifier ?? "" }
        }
    }

    private func save() {
        guard let target = albums.first(where: { $0.localIdentifier == destination }) else { return }
        let origin = moving ? albums.first(where: { $0.localIdentifier == source }) : nil
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await LibraryActions.add(assets, to: target, movingFrom: origin); completed(); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct DateActionSheet: View {
    let assets: [PHAsset]
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var preserveIntervals = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("New Date & Time", selection: $date)
                if assets.count > 1 { Toggle("Keep Time Differences", isOn: $preserveIntervals) }
                Text(preserveIntervals ? "The first selected photo moves to this date and time. The same time offset is applied to the others."
                     : "All selected photos get this date and time.").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Adjust Date & Time")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Adjust") { save() }.disabled(busy) }
            }
            .interactiveDismissDisabled(busy)
            .onAppear { date = assets.first?.creationDate ?? Date() }
        }
    }

    private func save() {
        let selected = date
        let delta = selected.timeIntervalSince(assets.first?.creationDate ?? selected)
        let relative = preserveIntervals
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await LibraryActions.update(assets) { request, asset in
                    request.creationDate = relative ? asset.creationDate?.addingTimeInterval(delta) ?? selected : selected
                }
                completed(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct LocationActionSheet: View {
    let assets: [PHAsset]
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var search = ""
    @State private var camera: MapCameraPosition = .automatic
    @State private var busy = false
    @State private var error: String?
    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = Double(latitude), let lon = Double(longitude), lat.isFinite, lon.isFinite,
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search for a Place", text: $search).submitLabel(.search).onSubmit { findPlace() }
                    MapReader { proxy in
                        Map(position: $camera) {
                            if let coordinate { Marker("Selected Location", coordinate: coordinate) }
                        }
                        .onTapGesture { point in
                            if let coordinate = proxy.convert(point, from: .local) { choose(coordinate) }
                        }
                    }
                    .frame(height: 240)
                    HStack { Text("Latitude"); TextField("-90…90", text: $latitude).multilineTextAlignment(.trailing) }
                    HStack { Text("Longitude"); TextField("-180…180", text: $longitude).multilineTextAlignment(.trailing) }
                } footer: { Text("Tap the map, search for a place, or enter coordinates. This location applies to all selected photos.") }
                Button("Remove Location", role: .destructive) { save(nil) }.disabled(busy)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Adjust Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Adjust") { save(coordinate) }.disabled(busy || coordinate == nil) }
            }
            .interactiveDismissDisabled(busy)
            .onAppear { if let coordinate = assets.first?.location?.coordinate { choose(coordinate) } }
        }
    }

    private func choose(_ point: CLLocationCoordinate2D) {
        latitude = String(format: "%.6f", point.latitude)
        longitude = String(format: "%.6f", point.longitude)
        camera = .region(MKCoordinateRegion(center: point, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
    }

    private func findPlace() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
                let response = try await MKLocalSearch(request: request).start()
                guard let item = response.mapItems.first else { error = "No matching place found."; return }
                choose(item.placemark.coordinate)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save(_ point: CLLocationCoordinate2D?) {
        busy = true
        let location = point.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        Task { @MainActor in
            defer { busy = false }
            do {
                try await LibraryActions.update(assets) { request, _ in request.location = location }
                completed(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
