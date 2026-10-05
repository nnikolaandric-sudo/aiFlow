import Foundation

// Minimal stand-in so the REAL DirectoryCache.swift compiles outside the app
// bundle. Only what DirectoryCache touches: the browse key set used when it
// prefetches subfolders. The revalidation gate under test is the app's own
// code — nothing here stands in for it.

struct FileItem: Identifiable {
    let id: String
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey, .isHiddenKey, .labelNumberKey,
    ]
}
