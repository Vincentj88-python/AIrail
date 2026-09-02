import SwiftUI

/// Settings › Accounts. The one place accounts are added, inspected, and
/// removed: a source list with +/− on the left, the selected account on the
/// right — the same shape as Xcode's Accounts pane.
struct AccountsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager

    @State private var selection: String?
    @State private var showingAddSheet = LaunchOptions.opensAddAccount
    @State private var confirmingRemoval = false

    private var connected: [ProviderInfo] {
        manager.connectedProviderInfos
    }

    private var selectedInfo: ProviderInfo? {
        selection.flatMap { id in connected.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 0) {
            accountList
                .frame(width: 210)
            Divider()
            Group {
                if let info = selectedInfo {
                    AccountDetailView(
                        info: info,
                        settings: settings,
                        manager: manager,
                        onDisconnect: { confirmingRemoval = true }
                    )
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 520)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: connected.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
            selectFirstIfNeeded()
        }
        .sheet(isPresented: $showingAddSheet) {
            AddAccountSheet(manager: manager) { connectedId in
                selection = connectedId
            }
        }
        .confirmationDialog(
            "Remove \(selectedInfo?.displayName ?? "this account")?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                if let id = selection { manager.disconnect(id) }
            }
        } message: {
            Text("AIrail forgets this account and stops reading its usage. The tool's own sign-in is not affected.")
        }
    }

    // MARK: List

    private var accountList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(connected) { info in
                    AccountRow(
                        info: info,
                        snapshot: manager.snapshot(for: info.id),
                        error: manager.lastErrors[info.id]
                    )
                    .tag(info.id)
                }
                if connected.isEmpty {
                    Text("No accounts")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                        .selectionDisabled()
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 0) {
                Button { showingAddSheet = true } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .help("Add Account")
                .accessibilityLabel("Add account")
                Divider().frame(height: 16)
                Button { confirmingRemoval = true } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .disabled(selectedInfo == nil)
                .help("Remove Account")
                .accessibilityLabel("Remove account")
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 4)
            .background(.bar)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            if connected.isEmpty {
                Text("No accounts yet")
                    .font(.headline)
                Text("AIrail shows demo data until you connect an account. It never asks for a password — it uses the sign-in a tool already has on this Mac, read-only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                Button("Add Account…") { showingAddSheet = true }
                    .padding(.top, 4)
            } else {
                Text("Select an account")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private func selectFirstIfNeeded() {
        if selection == nil { selection = connected.first?.id }
    }
}

// MARK: - Row

private struct AccountRow: View {
    let info: ProviderInfo
    let snapshot: UsageSnapshot?
    let error: ConnectionError?

    var body: some View {
        HStack(spacing: 10) {
            LogoMark(
                color: info.color,
                symbolName: info.symbolName,
                brandIconPath: info.brandIconPath,
                percent: nil,
                size: 28
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(info.displayName)
                    .font(.body)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : .orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        if let error { return error.shortDescription }
        if let plan = snapshot?.plan { return "\(plan) · \(snapshot?.status.label ?? "")" }
        return snapshot?.status.label ?? "connecting…"
    }
}

// MARK: - Detail

private struct AccountDetailView: View {
    let info: ProviderInfo
    @ObservedObject var settings: AppSettings
    @ObservedObject var manager: ProviderManager
    var onDisconnect: () -> Void

    private var snapshot: UsageSnapshot? { manager.snapshot(for: info.id) }
    private var error: ConnectionError? { manager.lastErrors[info.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)
            Form {
                Section("How it connects") {
                    Text(info.connection.explainer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let caveat = info.connection.caveat {
                        Label {
                            Text(caveat)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Toggle("Show on rail", isOn: showOnRailBinding)
                    LabeledContent("Last read") {
                        Text(lastReadText)
                            .foregroundStyle(error == nil ? Color.secondary : .orange)
                    }
                    if let account = snapshot?.account {
                        LabeledContent("Account") {
                            Text(account)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Button("Refresh") {
                    Task { await manager.refresh(info.id) }
                }
                .disabled(manager.refreshingIds.contains(info.id))
                Spacer()
                Button("Disconnect…", role: .destructive, action: onDisconnect)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            LogoMark(
                color: info.color,
                symbolName: info.symbolName,
                brandIconPath: info.brandIconPath,
                percent: snapshot?.ringPercent,
                size: 44
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(info.displayName)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if manager.refreshingIds.contains(info.id) {
                ProgressView().controlSize(.small)
            }
            if let status = snapshot?.status {
                StatusPill(status: status)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let plan = snapshot?.plan { parts.append("\(plan) plan") }
        parts.append("via \(info.connection.toolName)")
        return parts.joined(separator: " · ")
    }

    private var lastReadText: String {
        if let error { return error.errorDescription ?? error.shortDescription }
        if let snapshot { return UsageFormatting.lastUpdatedString(snapshot.lastUpdated) }
        return "—"
    }

    private var showOnRailBinding: Binding<Bool> {
        Binding(
            get: { settings.isShownOnRail(info.id) },
            set: { settings.setShownOnRail($0, providerId: info.id) }
        )
    }
}

// MARK: - Add Account

private struct AddAccountSheet: View {
    @ObservedObject var manager: ProviderManager
    var onConnected: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var connectingId: String?
    @State private var failure: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Account")
                .font(.title2.weight(.semibold))
            Text("AIrail never asks for a password. Pick a tool and it uses the sign-in that tool already has on this Mac, read-only.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(manager.connectableProviderInfos) { info in
                    tile(info)
                }
            }
            .padding(.top, 4)

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            Text("Looking for ChatGPT? It shares one OpenAI account with Codex, and ChatGPT itself doesn't publish usage limits. Connect Codex to see the Codex limits that come with your ChatGPT plan.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(connectingId != nil)
            }
        }
        .padding(24)
        .frame(width: 540)
        .animation(.default, value: failure)
    }

    private func tile(_ info: ProviderInfo) -> some View {
        let isConnecting = connectingId == info.id
        let supported = info.connection.isSupported
        return Button {
            connect(info)
        } label: {
            HStack(spacing: 12) {
                LogoMark(
                    color: info.color,
                    symbolName: info.symbolName,
                    brandIconPath: info.brandIconPath,
                    percent: nil,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.displayName)
                        .font(.headline)
                    Text(info.connection.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else if supported, !info.installed {
                    Text("Not detected")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!supported || connectingId != nil)
        .opacity(supported ? 1 : 0.55)
        .accessibilityLabel("\(info.displayName), \(info.connection.summary)")
        .accessibilityHint(supported ? "Connects this account." : "Not available yet.")
    }

    private func connect(_ info: ProviderInfo) {
        failure = nil
        connectingId = info.id
        Task {
            do {
                try await manager.connect(info.id)
                connectingId = nil
                onConnected(info.id)
                dismiss()
            } catch {
                connectingId = nil
                failure = "\(info.displayName): \(error.localizedDescription)"
            }
        }
    }
}
