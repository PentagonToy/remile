import Foundation
import WebKit
import ImageIO

/// Reading-only image requests use the app's offline gate and a small, per-preview memory cache.
@MainActor final class MarkdownRemoteImages: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "remile-image"
    nonisolated static func sourceURL(for remote: URL) -> URL? {
        guard ["http", "https"].contains(remote.scheme?.lowercased() ?? ""), remote.host != nil,
              remote.user == nil, remote.password == nil else { return nil }
        var parts = URLComponents(); parts.scheme = scheme; parts.host = "load"
        parts.queryItems = [URLQueryItem(name: "url", value: remote.absoluteString)]
        return parts.url
    }
    private final class CachedImage: NSObject {
        let data: Data, mime: String
        init(_ data: Data, mime: String) { self.data = data; self.mime = mime }
    }
    private final class Group {
        let id = UUID(), url: URL
        var tasks: [ObjectIdentifier: WKURLSchemeTask] = [:]
        var download: MarkdownImageDownload?
        var watch: UUID?
        init(_ url: URL) { self.url = url }
    }
    private let gate: NetworkAccessGate
    private let cache = NSCache<NSURL, CachedImage>()
    private var failedUntil: [URL: Date] = [:]
    private var groups: [URL: Group] = [:]
    private var requests: [ObjectIdentifier: URL] = [:]
    private var pending: [URL] = []
    private var running = 0
    private var pumping = false

    init(gate: NetworkAccessGate = NetworkAccess.gate) {
        self.gate = gate; super.init(); cache.totalCostLimit = 12 * 1024 * 1024; cache.countLimit = 32
    }
    deinit {
        for group in groups.values { group.download?.cancel(); if let watch = group.watch { gate.release(watch) } }
    }
    func clearCache() { cache.removeAllObjects(); clearFailures() }
    func clearFailures() { failedUntil.removeAll() }
    func cancelAll() {
        let previous = Array(groups.values)
        groups.removeAll(); requests.removeAll(); pending.removeAll(); running = 0
        for group in previous {
            group.download?.cancel()
            if let watch = group.watch { gate.release(watch) }
            for task in group.tasks.values { task.didFailWithError(URLError(.cancelled)) }
        }
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let source = urlSchemeTask.request.url,
              source.scheme == Self.scheme, source.host == "load",
              let value = URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let remote = URL(string: value), Self.sourceURL(for: remote) != nil else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL)); return
        }
        do { try gate.requireOnline() } catch { urlSchemeTask.didFailWithError(error); return }
        if let image = cache.object(forKey: remote as NSURL) { deliver(image, to: urlSchemeTask); return }
        if let until = failedUntil[remote], until > Date() { urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return }
        failedUntil.removeValue(forKey: remote)
        let key = ObjectIdentifier(urlSchemeTask)
        requests[key] = remote
        if let group = groups[remote] { group.tasks[key] = urlSchemeTask }
        else { let group = Group(remote); group.tasks[key] = urlSchemeTask; groups[remote] = group; pending.append(remote) }
        startPending()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = requests.removeValue(forKey: key), let group = groups[url] else { return }
        group.tasks.removeValue(forKey: key)
        if group.tasks.isEmpty {
            groups.removeValue(forKey: url)
            if group.download != nil { running -= 1; group.download?.cancel() }
            if let watch = group.watch { gate.release(watch) }
            startPending()
        }
    }
    private func startPending() {
        guard !pumping else { return }; pumping = true; defer { pumping = false }
        while running < 3, !pending.isEmpty {
            let url = pending.removeFirst()
            guard let group = groups[url], group.download == nil else { continue }
            let id = group.id
            let download = MarkdownImageDownload(url: url) { [weak self] result in
                Task { @MainActor [weak self] in self?.finished(url, id: id, result: result) }
            }
            do {
                group.watch = try gate.watch { [weak download] in download?.cancel() }
                group.download = download; running += 1; download.start()
            } catch {
                download.cancel(); finished(url, id: id, result: .failure(error))
            }
        }
    }
    private func finished(_ url: URL, id: UUID, result: Result<MarkdownImageDownload.Image, Error>) {
        guard let group = groups[url], group.id == id else { return }
        groups.removeValue(forKey: url)
        if group.download != nil { running -= 1 }
        if let watch = group.watch { gate.release(watch) }
        for key in group.tasks.keys { requests.removeValue(forKey: key) }
        if gate.offline {
            for task in group.tasks.values { task.didFailWithError(NetworkAccessGate.Offline()) }
        } else {
            switch result {
            case .success(let value):
                let image = CachedImage(value.data, mime: value.mime)
                cache.setObject(image, forKey: url as NSURL, cost: image.data.count)
                for task in group.tasks.values { deliver(image, to: task) }
            case .failure(let error):
                let native = error as NSError
                if native.domain != NSURLErrorDomain || native.code != NSURLErrorCancelled {
                    if failedUntil.count >= 32, let oldest = failedUntil.min(by: { $0.value < $1.value })?.key { failedUntil.removeValue(forKey: oldest) }
                    failedUntil[url] = Date().addingTimeInterval(30)
                }
                for task in group.tasks.values { task.didFailWithError(error) }
            }
        }
        startPending()
    }
    private func deliver(_ image: CachedImage, to task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        task.didReceive(URLResponse(url: url, mimeType: image.mime, expectedContentLength: image.data.count, textEncodingName: nil))
        task.didReceive(image.data); task.didFinish()
    }
}

/// A delegate enforces the byte ceiling as chunks arrive, including responses without Content-Length.
private final class MarkdownImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Image { let data: Data, mime: String }
    static let byteLimit = 8 * 1024 * 1024
    private var data = Data(), mime = ""
    private var failure: Error?
    private var completion: ((Result<Image, Error>) -> Void)?
    private var session: URLSession!
    private var task: URLSessionDataTask!
    init(url: URL, completion: @escaping (Result<Image, Error>) -> Void) {
        self.completion = completion; super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url); request.setValue("image/*", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
    }
    func start() { task.resume() }
    func cancel() { task.cancel(); session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let type = response.mimeType?.lowercased(), type.hasPrefix("image/"),
              response.expectedContentLength <= Int64(Self.byteLimit) else {
            failure = URLError(.badServerResponse); completionHandler(.cancel); return
        }
        mime = type; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard chunk.count <= Self.byteLimit - data.count else { failure = URLError(.dataLengthExceedsMaximum); dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callback = completion; completion = nil
        let result: Result<Image, Error>
        if let error = failure ?? error { result = .failure(error) }
        else if data.isEmpty || mime.isEmpty { result = .failure(URLError(.zeroByteResource)) }
        else if mime == "image/svg+xml" {
            if let clean = MarkdownSVG.sanitised(data) { result = .success(Image(data: clean, mime: mime)) }
            else { result = .failure(URLError(.cannotDecodeContentData)) }
        }
        else if let image = CGImageSourceCreateWithData(data as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
                let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
                width.doubleValue * height.doubleValue > 16_000_000 { result = .failure(URLError(.dataLengthExceedsMaximum)) }
        else { result = .success(Image(data: data, mime: mime)) }
        data = Data(); callback?(result); session.finishTasksAndInvalidate()
    }
}
