import Foundation
import WebKit

/// Downloads the normal source export using this account's existing web session.
@MainActor final class OverleafSourceDownload: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    private let web: WKWebView
    private let url: URL
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("remile-source-" + UUID().uuidString + ".zip")
    private var continuation: CheckedContinuation<Data, Error>?
    private var downloading = false
    private var transfer: WKDownload?
    private var timer: Task<Void, Never>?
    static let limit = 64 * 1024 * 1024
    init(project: String, profile: UUID) {
        url = URL(string: "https://www.overleaf.com/Project/" + project + "/download/zip")!
        let config = WKWebViewConfiguration(); config.websiteDataStore = OverleafWebIdentity.dataStore(profile)
        web = WKWebView(frame: .zero, configuration: config)
        super.init(); web.navigationDelegate = self
    }
    func load() async throws -> Data {
        try NetworkAccess.requireOnline()
        let lease = try NetworkAccess.gate.watch { [weak self] in Task { @MainActor in self?.finish(.failure(NetworkAccessGate.Offline())) } }
        defer { NetworkAccess.gate.release(lease); timer?.cancel(); web.stopLoading(); web.navigationDelegate = nil; transfer?.cancel { _ in }; try? FileManager.default.removeItem(at: file) }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { result in
                continuation = result
                timer = Task { [weak self] in
                    for _ in 0..<240 {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        guard let self else { return }
                        let size = (try? self.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        if size > Self.limit { self.finish(.failure(OverleafSourceArchive.Failure.invalid)); return }
                    }
                    self?.finish(.failure(OverleafSourceArchive.Failure.download))
                }
                web.load(URLRequest(url: url))
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
    }
    private func finish(_ value: Result<Data, Error>) { guard let continuation else { return }; self.continuation = nil; continuation.resume(with: value) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.request.url == url else { decisionHandler(.cancel); finish(.failure(action.request.url.map(OverleafWebClient.isLoginURL) == true ? OverleafWebClient.Failure.signIn : .response)); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let http = response.response as? HTTPURLResponse else { decisionHandler(.cancel); finish(.failure(OverleafWebClient.Failure.response)); return }
        OverleafLiveDiagnostics.note("source-response", code: http.statusCode)
        guard http.statusCode == 200 else {
            decisionHandler(.cancel)
            finish(.failure(http.statusCode == 401 ? OverleafWebClient.Failure.signIn : http.statusCode == 403 ? .permission : .response)); return
        }
        guard http.expectedContentLength <= Self.limit, ["application/zip", "application/x-zip-compressed", "application/octet-stream"].contains(http.mimeType?.lowercased() ?? "") else { decisionHandler(.cancel); finish(.failure(OverleafSourceArchive.Failure.download)); return }
        OverleafLiveDiagnostics.note("source-mime", code: ["application/zip", "application/x-zip-compressed", "application/octet-stream"].firstIndex(of: http.mimeType?.lowercased() ?? "") ?? -1)
        downloading = true; decisionHandler(.download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { OverleafLiveDiagnostics.note("source-download-started"); transfer = download; download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) { OverleafLiveDiagnostics.note("source-destination"); completionHandler(file) }
    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard request.url == url else { decisionHandler(.cancel); finish(.failure(OverleafSourceArchive.Failure.download)); return }; decisionHandler(.allow)
    }
    func downloadDidFinish(_ download: WKDownload) {
        OverleafLiveDiagnostics.note("source-download-finished")
        do { guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= Self.limit else { throw OverleafSourceArchive.Failure.invalid }; finish(.success(try Data(contentsOf: file))) }
        catch { finish(.failure(error)) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { OverleafLiveDiagnostics.note("source-download-error", code: (error as NSError).code); finish(.failure(OverleafSourceArchive.Failure.download)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { OverleafLiveDiagnostics.note("source-navigation-error", code: (error as NSError).code); if !downloading && (error as NSError).code != NSURLErrorCancelled { finish(.failure(OverleafSourceArchive.Failure.download)) } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { OverleafLiveDiagnostics.note("source-navigation-error", code: (error as NSError).code); if !downloading && (error as NSError).code != NSURLErrorCancelled { finish(.failure(OverleafSourceArchive.Failure.download)) } }
}
