import AppKit
import Security
import ServiceManagement
import SwiftUI

/// Settings › Privacy: what AIrail reads, every host it has contacted and
/// when, what it keeps on this Mac, what this build is, and the one button
/// that removes all of it. Everything here is measured live, never asserted.
struct PrivacyPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    @ObservedObject private var ledger = NetworkLedger.shared

    @State private var kept = KeptData.measure()
    @State private var confirmingRemoval = false

    private let signing = SigningInfo.current()

    var body: some View {
        Form {
            readsSection
            connectsSection
            keepsSection
            buildSection
            Section {
                Button("Remove All AIrail Data…", role: .destructive) { confirmingRemoval = true }
            } footer: {
                Text("Removes AIrail's preferences, its own Keychain items (the API keys you pasted), the usage ledgers and its launch-at-login registration, then quits. Nothing that belongs to another tool is touched.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
        .onAppear { kept = KeptData.measure() }
        .confirmationDialog("Remove all AIrail data and quit?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove and Quit", role: .destructive) { Task { await removeAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your tools' own sign-ins and transcripts stay exactly as they are.")
        }
    }

    // MARK: What AIrail reads

    private var readsSection: some View {
        Section {
            let accounts = manager.connectedProviderInfos
            if accounts.isEmpty {
                Text("No accounts connected — nothing is read.")
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts) { info in
                ForEach(Footprint.items(for: info.id).filter { $0.host == nil }, id: \.self) { item in
                    footprintRow(item, account: info.displayName)
                }
            }
        } header: {
            Text("What AIrail reads")
        } footer: {
            Text("Read only, and only after you connect the account. Nothing is written back, no refresh token is ever used, and no token is copied to disk.")
        }
    }

    @ViewBuilder
    private func footprintRow(_ item: FootprintItem, account: String) -> some View {
        switch item {
        case .file(let path, let what):
            LabeledContent {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
                }
                .controlSize(.small)
            } label: {
                Text(account)
                Text("\(path) — \(what)")
            }
        case .keychain(let item, let what):
            LabeledContent {
                Button("Open Keychain Access") { Self.openKeychainAccess() }
                    .controlSize(.small)
            } label: {
                Text(account)
                Text("Keychain item “\(item)” — \(what)")
            }
        case .command(let command, let what):
            LabeledContent {
                Text("")
            } label: {
                Text(account)
                Text("Runs `\(command)` — \(what)")
            }
        case .host:
            EmptyView()
        }
    }

    private static func openKeychainAccess() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Where it connects

    private var connectsSection: some View {
        Section {
            ForEach(ledger.entries) { entry in
                LabeledContent {
                    Text("\(UsageFormatting.lastUpdatedString(entry.lastContact)) · HTTP \(entry.status) · \(entry.count.formatted())×")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } label: {
                    Text(entry.host)
                    Text(Footprint.hosts[entry.host] ?? entry.path)
                }
            }
            let quiet = HTTPClient.allowedHosts.subtracting(ledger.entries.map(\.host)).sorted()
            ForEach(quiet, id: \.self) { host in
                LabeledContent {
                    Text("not contacted")
                        .foregroundStyle(.tertiary)
                } label: {
                    Text(host)
                    Text(Footprint.hosts[host] ?? "")
                }
            }
        } header: {
            Text("Where it connects")
        } footer: {
            Text("Since AIrail launched, \(UsageFormatting.lastUpdatedString(ledger.since)). These \(HTTPClient.allowedHosts.count) hosts are the whole list — every other host is refused in code, redirects included.")
        }
    }

    // MARK: What it keeps

    private var keepsSection: some View {
        Section {
            LabeledContent("Preferences", value: kept.preferences)
            LabeledContent("Keychain items", value: kept.keychainItems)
            LabeledContent("Usage ledgers", value: kept.ledgers)
            LabeledContent("Cache, cookies, tokens on disk", value: "None")
        } header: {
            Text("What it keeps")
        } footer: {
            Text("The ledgers hold daily totals, model ids and project folder names per account so charts and pace survive a relaunch — never a token, a key or an email. One ephemeral network session keeps no cache and no cookie jar.")
        }
    }

    // MARK: This build

    private var buildSection: some View {
        Section {
            LabeledContent("Version", value: BuildInfo.label)
            LabeledContent("Signed by", value: signing.signer ?? "no one (an ad-hoc development build)")
            LabeledContent("Hardened Runtime", value: signing.hardenedRuntime ? "On" : "Off")
            LabeledContent("App Sandbox", value: signing.sandboxed ? "On" : "Off — it must read other tools' sign-ins")
            LabeledContent("Notarized", value: signing.developerID ? "Signed with a Developer ID" : "Not yet — no Apple Developer ID")
        } header: {
            Text("This build")
        } footer: {
            Text(signing.developerID
                 ? "Apple has checked this build for malware; macOS opens it without a warning."
                 : "Until there is a Developer ID, macOS shows a one-time warning on first launch and this build is signed with AIrail's own certificate.")
        }
    }

    // MARK: Remove all

    @MainActor
    private func removeAll() async {
        for id in manager.connectedProviderInfos.map(\.id) {
            manager.disconnect(id)
        }
        for account in KeptData.keychainAccounts() {
            KeychainStore.delete(account: account)
        }
        await UsageStore().deleteAll()
        try? await SMAppService.mainApp.unregister()
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        NSApp.terminate(nil)
    }
}

/// What is on this Mac because of AIrail, measured when the pane opens.
struct KeptData {
    var preferences: String
    var keychainItems: String
    var ledgers: String

    static func measure() -> KeptData {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.codeandvin.airail"
        let prefs = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences/\(bundleId).plist")
        let prefsSize = (try? prefs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let accounts = keychainAccounts()
        let ledgerFiles = (try? FileManager.default.contentsOfDirectory(at: UsageStore.defaultDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let ledgerBytes = ledgerFiles.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let format = ByteCountFormatStyle(style: .file)
        return KeptData(
            preferences: prefsSize > 0 ? "\(prefs.lastPathComponent) · \(Int64(prefsSize).formatted(format))" : "None yet",
            keychainItems: accounts.isEmpty ? "None" : "\(accounts.count) (\(accounts.sorted().joined(separator: ", ")))",
            ledgers: ledgerFiles.isEmpty ? "None yet" : "\(ledgerFiles.count) account\(ledgerFiles.count == 1 ? "" : "s") · \(Int64(ledgerBytes).formatted(format))"
        )
    }

    /// AIrail's own Keychain items, by account, listed without a prompt
    /// (attributes only, and they are its own).
    static func keychainAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// What the running binary's signature says, from the Security framework —
/// the same facts `codesign -dvv` prints, so the pane never asserts them.
struct SigningInfo {
    let signer: String?
    let teamId: String?
    let hardenedRuntime: Bool
    let sandboxed: Bool

    /// A Developer ID certificate signed this, which is what notarization needs.
    var developerID: Bool { signer?.hasPrefix("Developer ID Application") == true }

    static func current() -> SigningInfo {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return SigningInfo(signer: nil, teamId: nil, hardenedRuntime: false, sandboxed: false)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return SigningInfo(signer: nil, teamId: nil, hardenedRuntime: false, sandboxed: false)
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 1 << 1 /* kSecCSSigningInformation */), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else {
            return SigningInfo(signer: nil, teamId: nil, hardenedRuntime: false, sandboxed: false)
        }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        let signer = certificates.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return SigningInfo(
            signer: signer,
            teamId: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            hardenedRuntime: flags & 0x10000 /* kSecCodeSignatureRuntime */ != 0,
            sandboxed: (entitlements["com.apple.security.app-sandbox"] as? Bool) == true
        )
    }
}
