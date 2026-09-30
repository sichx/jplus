import Foundation

/// What the app keeps on this Mac that Jira can supply again: downloaded
/// attachments, the search index, remembered issue titles, and cached
/// network responses such as avatars. Accounts, recent issues, search
/// history and settings aren't part of it.
enum LocalData {
    /// Bytes used on disk.
    static func diskUsage() async -> Int64 {
        let locations = [AttachmentStore.folder] + SearchIndex.savedFiles()
        let files = await Task.detached { locations.reduce(0) { $0 + size(of: $1) } }.value
        // An empty URL cache still reports its database file (about 80 kB);
        // don't show that as something stored.
        let network = Int64(URLCache.shared.currentDiskUsage)
        return files + (network > emptyURLCacheSize ? network : 0)
    }

    private static let emptyURLCacheSize: Int64 = 128 * 1024

    /// Deletes all of it, for every saved account, then tells open windows
    /// so they drop what they hold in memory.
    static func clear(accountIDs: [UUID]) async {
        AttachmentStore.shared.clear()
        SearchIndex.deleteAll()
        for id in accountIDs {
            IssueTitleCache.clear(in: AccountDefaults.store(for: id))
        }
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: .jplusLocalDataCleared, object: nil)
    }

    /// Size of a file, or of everything inside a folder.
    nonisolated private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        func fileSize(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return fileSize(url)
        }
        var total = fileSize(url)
        for case let file as URL in enumerator { total += fileSize(file) }
        return total
    }
}

extension Notification.Name {
    /// Posted after Settings clears downloaded and cached data.
    static let jplusLocalDataCleared = Notification.Name("co.interactivelabs.jplus.localDataCleared")
}
