import Foundation

/// Checks resources that native MLX code cannot report safely once entered.
/// Keep this pure and injectable so a missing app resource is testable without
/// loading a translation model.
enum TranslationPreflight {
    static func hasBundledMetalLibrary(resourceRoot: URL? = Bundle.main.resourceURL,
                                       fileManager: FileManager = .default) -> Bool {
        guard let resourceRoot,
              let enumerator = fileManager.enumerator(
                at: resourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else {
            return false
        }

        for case let url as URL in enumerator where url.pathExtension == "metallib" {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else { continue }
            return true
        }
        return false
    }
}
