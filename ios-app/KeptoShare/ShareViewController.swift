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
/// share links as plain text). The link is also copied to the clipboard
/// before opening the app, so if the handoff fails the user can still
/// paste it in Kepto manually.
///
/// The extension shows a spinner + status line while it works: the first
/// version was a blank view (black in dark mode) while the URL loaded,
/// which looked exactly like a hang or a crash.
final class ShareViewController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    /// True once the extension has finished (or shown a final alert), so
    /// a late URL load or the timeout guard cannot complete it twice.
    private var isDone = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Đang mở Kepto…"
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        // Safety net: if the shared item never loads (a slow or stuck
        // item provider), show the no-link alert instead of sitting on
        // the spinner forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.isDone else { return }
            self.showNoLinkAlert()
        }

        extractURL { [weak self] url in
            guard let self, !self.isDone else { return }
            guard let url else {
                self.showNoLinkAlert()
                return
            }
            // Clipboard first: the fallback if the app handoff fails.
            UIPasteboard.general.string = url.absoluteString
            guard let appURL = Self.appURL(for: url) else {
                self.showOpenFailedAlert()
                return
            }
            self.extensionContext?.open(appURL) { [weak self] success in
                guard let self else { return }
                if success {
                    self.finish()
                } else {
                    // The kepto:// scheme did not open (e.g. the app
                    // build predates the scheme): tell the user instead
                    // of silently vanishing — the link is on the
                    // clipboard, so they can paste it in the app.
                    self.showOpenFailedAlert()
                }
            }
        }
    }

    private func finish() {
        guard !isDone else { return }
        isDone = true
        extensionContext?.completeRequest(returningItems: nil)
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
        guard !isDone else { return }
        isDone = true
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

    private func showOpenFailedAlert() {
        guard !isDone else { return }
        isDone = true
        let alert = UIAlertController(
            title: "Kepto",
            message: "Không mở được app Kepto. Link đã được copy vào clipboard — mở app Kepto và dán để lưu.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            self.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
    }

    /// Finds the first http(s) URL in the extension context's input items:
    /// a URL attachment first, then the first URL inside a shared text.
    /// A URL load that yields nothing falls back to text instead of
    /// giving up — some hosts vend the link as text only.
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
                        self.extractTextURL(providers: providers, completion: completion)
                    }
                }
            }
            return
        }
        extractTextURL(providers: providers, completion: completion)
    }

    private func extractTextURL(providers: [NSItemProvider], completion: @escaping (URL?) -> Void) {
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
