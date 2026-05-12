import SafariServices
import os

private let extensionLog = Logger(subsystem: "com.void.smarttube.safariextension", category: "Extension")

// MARK: - SafariWebExtensionHandler
//
// Required entry point for a Safari Web Extension target.
// All redirect logic lives in content.js (document_start), so this handler
// only needs to exist — it does not need to process any native messages.

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        extensionLog.debug("message from browser: \(String(describing: message), privacy: .public)")
        context.completeRequest(returningItems: nil)
    }
}
