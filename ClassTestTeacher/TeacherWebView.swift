import SwiftUI
import UIKit
import WebKit

struct TeacherWebView: UIViewRepresentable {
    let urlString: String
    var onLoadError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadError: onLoadError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.keyboardDismissMode = .interactive

        if let url = URL(string: urlString) {
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(req)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let onLoadError: (String) -> Void
        private var downloadDestination: URL?

        init(onLoadError: @escaping (String) -> Void) {
            self.onLoadError = onLoadError
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let nsErr = error as NSError
            if nsErr.code == NSURLErrorCancelled || nsErr.code == 102 { return }
            onLoadError("Не удалось открыть панель управления. Проверьте сеть и адрес.")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse {
                let disp = (http.allHeaderFields["Content-Disposition"] as? String)
                    ?? (http.allHeaderFields["content-disposition"] as? String)
                    ?? ""
                let path = http.url?.path ?? ""
                if disp.lowercased().contains("attachment")
                    || path == "/api/backup"
                    || path == "/api/journal/export"
                    || !navigationResponse.canShowMIMEType {
                    decisionHandler(.download)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            let safeName = suggestedFilename.isEmpty ? "classtest_export.dat" : suggestedFilename
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
            try? FileManager.default.removeItem(at: dest)
            downloadDestination = dest
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let fileURL = downloadDestination else { return }
            DispatchQueue.main.async {
                let vc = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                if let top = self.topViewController() {
                    if let pop = vc.popoverPresentationController {
                        pop.sourceView = top.view
                        pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
                    }
                    top.present(vc, animated: true)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "Да", style: .default) { _ in completionHandler(true) })
            topViewController()?.present(alert, animated: true)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "ОК", style: .default) { _ in completionHandler() })
            topViewController()?.present(alert, animated: true)
        }

        private func topViewController() -> UIViewController? {
            var root = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }?
                .rootViewController
            while let presented = root?.presentedViewController { root = presented }
            return root
        }
    }
}
