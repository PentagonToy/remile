import Foundation
import AppKit
import Darwin

enum RuntimeDiagnostics {
    static func memory() -> [String: Any] {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return ["available": false, "scope": "mainProcessOnly"] }
        return ["available": true, "scope": "mainProcessOnly", "residentBytes": info.resident_size, "peakResidentBytes": info.resident_size_max]
    }
    @MainActor static func snapshot(_ home: HomeModel) -> [String: Any] {
        let project = home.texProject
        return ["ok": true, "memory": memory(), "decoration": ["ticks": DecorativeMotionDiagnostics.ticks, "applicationActive": NSApp.isActive, "keyWindow": NSApp.keyWindow != nil], "automation": ["transport": "directoryEvents", "idlePolling": false],
                "cache": ["activeBuildFolders": TeXCache.activeCount, "budgetBytes": TeXCache.budgetBytes],
                "workspace": ["sourceFiles": project?.buffers.count ?? 0, "sourceBytes": project?.buffers.values.reduce(0) { $0 + $1.utf8.count } ?? 0,
                              "cachedSourceHashes": project?.cachedSourceHashCount ?? 0,
                              "citationLibraryLoads": project?.citations.libraryLoads ?? 0, "citationBibliographyPreparations": project?.citations.bibliographyPreparations ?? 0, "compiling": project?.compiling ?? false,
                              "searchHits": home.results.count, "openWindows": RemileWindows.shared.models.count]]
    }
}
