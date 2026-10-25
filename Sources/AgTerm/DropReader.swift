import AgTermCore
import AppKit

/// Turns whatever was dropped on a terminal into text to type, the way Terminal.app does:
/// files become escaped paths; images without a file (from a browser or a screenshot tool) are
/// saved to a temporary folder first, so agents like Claude Code can open them by path.
enum DropReader {
    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .png, .tiff, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    /// Where saved images and received file promises go. The system clears it after a few days.
    static let dropFolder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-drops", isDirectory: true)

    /// Reads the pasteboard and calls `completion` on the main queue with the text to insert,
    /// or nil when nothing usable was dropped. File promises finish asynchronously.
    static func text(from pasteboard: NSPasteboard, completion: @escaping (String?) -> Void) {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !fileURLs.isEmpty {
            return completion(DropText.forPaths(fileURLs.map(\.path)))
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty, let folder = makeDropFolder() {
            return receive(promises, into: folder, completion: completion)
        }
        if let image = NSImage(pasteboard: pasteboard), let path = save(image) {
            return completion(DropText.forPaths([path]))
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            return completion(url.absoluteString + " ")
        }
        completion(pasteboard.string(forType: .string))
    }

    private static func receive(_ promises: [NSFilePromiseReceiver], into folder: URL,
                                completion: @escaping (String?) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var paths: [Int: String] = [:]
        for (index, promise) in promises.enumerated() {
            group.enter()
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .init()) { url, error in
                if error == nil {
                    lock.lock()
                    paths[index] = url.path
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ordered = paths.keys.sorted().compactMap { paths[$0] }
            completion(ordered.isEmpty ? nil : DropText.forPaths(ordered))
        }
    }

    private static func save(_ image: NSImage) -> String? {
        guard let folder = makeDropFolder(),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        var url = folder.appendingPathComponent("image-\(stamp).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("image-\(stamp)-\(n).png")
            n += 1
        }
        do {
            try png.write(to: url, options: .atomic)
            return url.path
        } catch {
            NSLog("agterm: couldn't save dropped image: %@", error.localizedDescription)
            return nil
        }
    }

    private static func makeDropFolder() -> URL? {
        do {
            try FileManager.default.createDirectory(at: dropFolder, withIntermediateDirectories: true)
            return dropFolder
        } catch {
            NSLog("agterm: couldn't create %@: %@", dropFolder.path, error.localizedDescription)
            return nil
        }
    }
}
