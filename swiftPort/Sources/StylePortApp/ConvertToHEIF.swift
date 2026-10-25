import CoreImage
import ImageIO
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// RAW / JPEG / PNG (and HEIC) -> HEIF, done on the iPhone itself.
///
/// iOS has a native HEVC/HEIF encoder (ImageIO), so no Mac/Windows command-line
/// tool is needed. This is a plain format conversion, not a style port:
/// the output is a normal HEIF file saved back to Photos, and Photos will
/// show its thumbnail normally. It does NOT give a converted photo the
/// iPhone HDR tile structure that "Add Photographic Style" needs, so a
/// converted HEIF still cannot gain the style palette -- that only works
/// on original iPhone HEICs. What it does fix, on-device, is the
/// "no embedded thumbnail" case: a re-saved HEIC copy is decoded and
/// re-encoded as a clean HEIF instead of being rejected for a missing
/// thumbnail item.
struct ConvertToHEIFView: View {
    @State private var importing = false
    @State private var files: [URL] = []
    @State private var converting = false
    @State private var done: [String] = []
    @State private var error: String?

    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.jpeg, .png, .tiff, .heic, .heif, .rawImage]
        if let dng = UTType(filenameExtension: "dng") { types.append(dng) }
        if let cr2 = UTType(filenameExtension: "cr2") { types.append(cr2) }
        if let nef = UTType(filenameExtension: "nef") { types.append(nef) }
        return types
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("在 iPhone 本机把 RAW、JPG、PNG 转成 HEIF，存回照片 App，不用 Mac 或 Windows 命令行工具。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("无内嵌缩略图的 HEIC 副本也会走同一条路：先解码原图，再由 iOS 编码器重新生成一份干净的 HEIF，照片 App 能正常显示缩略图。注意：转出的普通 HEIF 没有 iPhone 原图的 HDR 结构，所以仍不能用「添加摄影风格」加调色板，调色板只支持 iPhone 原图 HEIC。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button { importing = true } label: {
                        Label(files.isEmpty ? "选择文件" : "再选文件", systemImage: "folder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if !files.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(files, id: \.self) { file in
                                Text(file.lastPathComponent).font(.subheadline).lineLimit(1)
                            }
                        }
                        Button {
                            Task { await convertAll() }
                        } label: {
                            Text(converting ? "转换中…" : "转换为 HEIF 并存入照片")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(converting)
                    }

                    if !done.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("已存入照片：").font(.headline)
                            ForEach(done, id: \.self) { name in
                                Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("转换 HEIF")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    do { files = try copyImportedFiles(urls) }
                    catch { error = error.localizedDescription }
                case .failure(let err):
                    error = err.localizedDescription
                }
            }
            .alert("转换失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("确定") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

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

    private func convertAll() async {
        converting = true
        defer { converting = false }
        do {
            try await PhotoLibraryService().requireAddAccess()
        } catch {
            self.error = error.localizedDescription
            return
        }
        var saved: [String] = []
        for file in files {
            do {
                let output = try Self.convert(file: file)
                try await saveToPhotos(output)
                saved.append(output.lastPathComponent)
            } catch {
                self.error = "\(file.lastPathComponent)：\(error.localizedDescription)"
                return
            }
        }
        done = saved
        files = []
    }

    private func saveToPhotos(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            request.addResource(with: .photo, fileURL: url, options: options)
        }
    }

    /// Decode (CGImageSource, or Core Image for RAW) and re-encode as HEIF.
    static func convert(file: URL) throws -> URL {
        let ext = file.pathExtension.lowercased()
        let isRaw = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"].contains(ext)
        var cgImage: CGImage?
        var properties: [String: Any] = [:]
        if isRaw {
            if let ciImage = CIImage(contentsOf: file) {
                let context = CIContext()
                cgImage = context.createCGImage(ciImage, from: ciImage.extent)
            }
        } else if let source = CGImageSourceCreateWithURL(file as CFURL, nil) {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                properties = props
            }
        }
        guard let image = cgImage else {
            throw LibraryError.assetUnavailable
        }
        let base = (file.lastPathComponent as NSString).deletingPathExtension
        let output = try TemporaryFiles.newDirectory().appendingPathComponent(base + "_HEIF.HEIC")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw LibraryError.saveFailed("无法创建 HEIF 编码器")
        }
        var destProps: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.92]
        if let orientation = properties[kCGImagePropertyOrientation as String] {
            destProps[kCGImagePropertyOrientation as String] = orientation
        }
        if let exif = properties[kCGImagePropertyExifDictionary as String] {
            destProps[kCGImagePropertyExifDictionary as String] = exif
        }
        CGImageDestinationAddImage(destination, image, destProps as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LibraryError.saveFailed("HEIF 编码失败")
        }
        return output
    }
}
