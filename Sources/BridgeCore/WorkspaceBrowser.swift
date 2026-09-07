import Foundation

public enum WorkspaceBrowser {
    public static func listing(path: String?) throws -> [String: Any] {
        let manager = FileManager.default
        let directory = path.map { URL(fileURLWithPath: $0) } ?? manager.homeDirectoryForCurrentUser
        guard path == nil || path!.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()
        let children = try manager.contentsOfDirectory(at: resolved, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])
        let folders = try children.filter {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values.isDirectory == true && values.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return ["directory": resolved.path, "directories": folders.map(\.path)]
    }
}
