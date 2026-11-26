import Foundation

public enum PathCanonicalizer {
    /// Normalizes a file URL so `/var/...` and `/private/var/...` (and any symlinks in
    /// existing ancestor directories) resolve identically even if the leaf file does not exist yet.
    public static func canonicalFileURL(_ url: URL) -> URL {
        guard url.isFileURL else {
            return url.standardized
        }

        let standardized = url.standardizedFileURL
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }

        var trailingComponents: [String] = []
        var cursor = standardized

        while cursor.path != "/" && !fileManager.fileExists(atPath: cursor.path) {
            let component = cursor.lastPathComponent
            if !component.isEmpty && component != "/" {
                trailingComponents.append(component)
            }
            cursor.deleteLastPathComponent()
        }

        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for component in trailingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: false)
        }
        return resolved.standardizedFileURL
    }
}

internal func canonicalFileURL(_ url: URL) -> URL {
    PathCanonicalizer.canonicalFileURL(url)
}
