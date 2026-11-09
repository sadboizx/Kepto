import UIKit
import UniformTypeIdentifiers

/// Share Extension: "Save to Kepto" in the iOS share sheet.
///
/// It does NOT save by itself — the extension has no access to the app's
/// Keychain/API key (no App Groups on a Feather-signed build), so it hands
/// the link to the main app via the `kepto://save?url=...` URL scheme.
/// The app opens and saves it automatically (Save sheet, auto-save on).
///
/// Accepts a shared URL, or a text containing an http(s) URL (some apps
/// share links as plain text). Shows a small alert when no link is found.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        extractURL { [weak self] url in
            guard let self else { return }
            if let url, let appURL = Self.appURL(for: url) {
                self.extensionContext?.open(appURL) { _ in
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
            } else {
                self.showNoLinkAlert()
            }
        }
    }

    /// kepto://save?url=<percent-encoded link>
    private static func appURL(for url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "kepto"
        components.host = "save"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url
    }

    private func showNoLinkAlert() {
        let alert = UIAlertController(
            title: "Kepto",
            message: "Không tìm thấy link trong nội dung đã chia sẻ.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            self.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }

    /// Finds the first http(s) URL in the extension context's input items:
    /// a URL attachment first, then the first URL inside a shared text.
    private func extractURL(completion: @escaping (URL?) -> Void) {
        guard let extensionContext else { completion(nil); return }
        let providers = extensionContext.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        // Try URL attachments first.
        let urlProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        if let provider = urlProviders.first {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                DispatchQueue.main.async {
                    if let url = item as? URL {
                        completion(url)
                    } else if let string = item as? String, let url = URL(string: string) {
                        completion(url)
                    } else {
                        completion(nil)
                    }
                }
            }
            return
        }
        // Fall back to plain text containing a link.
        let textProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }
        guard let provider = textProviders.first else {
            completion(nil)
            return
        }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            DispatchQueue.main.async {
                guard let text = item as? String else {
                    completion(nil)
                    return
                }
                completion(Self.firstURL(in: text))
            }
        }
    }

    private static func firstURL(in text: String) -> URL? {
        // NSDataDetector would be heavier; a simple regex is enough for a
        // shared link (TikTok/Instagram/X links have no spaces in them).
        let pattern = "https?://[^\\s\"'<>]+"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }
}
