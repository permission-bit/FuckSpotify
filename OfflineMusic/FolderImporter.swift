import Foundation
import SwiftData
import UniformTypeIdentifiers

extension Importer {
    static func importFolders(_ result: Result<[URL], Error>, context: ModelContext) {
        guard case .success(let urls) = result else { return }
        for url in urls { importFolder(.success([url]), context: context) }
    }

    static func importFolder(_ result: Result<[URL], Error>, context: ModelContext) {
        guard case .success(let urls) = result, let folder = urls.first else { return }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])?.compactMap { item -> URL? in
            guard let url = item as? URL, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else { return nil }
            return url
        } ?? []
        Importer.importFiles(.success(files), context: context)
    }
}
