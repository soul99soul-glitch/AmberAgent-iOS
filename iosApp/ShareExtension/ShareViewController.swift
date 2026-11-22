import UIKit
import UniformTypeIdentifiers

/// Minimal native Share Extension entry point: extracts shared text or URLs, stores them
/// in the App Group handoff store, and opens Amber's main timeline (`amber://share/<id>`)
/// with prefilled composer text so the user can send locally or tap "交给 Mac".
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var didStartExtraction = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartExtraction else { return }
        didStartExtraction = true
        Task { @MainActor in
            await processSharedItems()
        }
    }

    private func setupUI() {
        view.backgroundColor = UIColor.systemBackground

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.text = "正在投喂到 Amber…"

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 3
        detailLabel.text = "打开 Amber 主时间线后可直接发送，或点按「交给 Mac」"

        closeButton.setTitle("完成", for: .normal)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(closeButton)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }

    @objc private func handleClose() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @MainActor
    private func processSharedItems() async {
        let extracted = await extractSharedPayload()
        guard let payload = extracted, payload.formattedPrefillText != nil else {
            statusLabel.text = "没有检测到可投喂的文字或链接"
            detailLabel.text = "当前试点支持从其他 App 分享纯文本与网页链接。"
            closeButton.isHidden = false
            return
        }

        let store = AmberShareHandoffStore.shared
        guard store?.save(payload) == true else {
            statusLabel.text = "无法写入共享队列"
            detailLabel.text = "请返回 Amber 后重试。"
            closeButton.isHidden = false
            return
        }

        if let scheme = Bundle.main.object(forInfoDictionaryKey: "AmberHostURLScheme") as? String,
           let url = AmberShareHandoffStore.shareDeepLinkURL(for: payload.id, scheme: scheme),
           await extensionContext?.open(url) == true {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        statusLabel.text = "已准备好投喂内容"
        detailLabel.text = "切换到 Amber 时将自动预填到当前主时间线输入框。"
        closeButton.isHidden = false
    }

    private func extractSharedPayload() async -> AmberSharePayload? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        var texts: [String] = []
        var urls: [String] = []
        var titles: [String] = []

        for item in items {
            if let title = item.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                titles.append(title)
            }
            let providers = item.attachments ?? []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(from: provider) {
                    urls.append(url.absoluteString)
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = await loadText(from: provider) {
                    texts.append(text)
                }
            }
            if texts.isEmpty,
               let body = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines),
               !body.isEmpty {
                texts.append(body)
            }
        }

        let mergedTitle = titles.first
        let mergedText = texts.isEmpty ? nil : texts.joined(separator: "\n")
        let mergedURL = urls.isEmpty ? nil : urls.joined(separator: "\n")
        guard mergedTitle != nil || mergedText != nil || mergedURL != nil else { return nil }
        return AmberSharePayload(title: mergedTitle, text: mergedText, urlString: mergedURL)
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let str = item as? String, let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
                } else if let attributed = item as? NSAttributedString {
                    let trimmed = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

}
