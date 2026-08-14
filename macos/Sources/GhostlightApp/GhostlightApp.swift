import AppKit
import SwiftUI

@main
struct GhostlightApp: App {
    @StateObject private var viewModel = SessionViewModel()

    var body: some Scene {
        WindowGroup("Ghostlight") {
            ContentView(viewModel: viewModel)
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            GhostlightCommands(viewModel: viewModel)
        }
    }
}

private struct GhostlightCommands: Commands {
    @ObservedObject var viewModel: SessionViewModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { viewModel.perform(.newTab) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!viewModel.canPerform(.newTab))
            Button("Close Tab") { viewModel.perform(.closeTab) }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!viewModel.canPerform(.closeTab))
        }

        CommandMenu("Navigate") {
            Button("Open Location…") { viewModel.perform(.focusLocation) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!viewModel.canPerform(.focusLocation))
            Divider()
            Button("Back") { viewModel.perform(.goBack) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!viewModel.canPerform(.goBack))
            Button("Forward") { viewModel.perform(.goForward) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!viewModel.canPerform(.goForward))
            Button("Reload Page") { viewModel.perform(.reload) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!viewModel.canPerform(.reload))
            Divider()
            Button("Show Next Tab") { viewModel.perform(.nextTab) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!viewModel.canPerform(.nextTab))
            Button("Show Previous Tab") { viewModel.perform(.previousTab) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!viewModel.canPerform(.previousTab))
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: SessionViewModel
    @FocusState private var addressFocused: Bool
    @State private var showingConnection = false
    @State private var showingFileImporter = false
    @State private var showingShortcutEditor = false
    @State private var showingChromePairing = false
    @State private var showingHome = true
    @State private var homeQuery = ""
    @State private var newSpaceName = ""
    @State private var nativeClientName = Host.current().localizedName ?? "This Mac"

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if viewModel.session == nil {
                connectionView
            } else {
                browserShell
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(isPresented: $showingConnection) {
            connectionPanel(compact: true)
                .frame(width: 460)
                .padding(28)
        }
        .sheet(isPresented: $showingShortcutEditor) {
            ShortcutEditorView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingChromePairing) {
            ChromePairingView(viewModel: viewModel)
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { viewModel.attach(url) }
        }
        .onChange(of: addressFocused) { _, focused in
            viewModel.setAddressFocused(focused)
        }
        .onChange(of: viewModel.session?.id) { _, sessionID in
            if sessionID != nil { showingHome = true }
        }
        .onChange(of: viewModel.addressFocusRequest) { _, _ in
            addressFocused = true
        }
        .onChange(of: viewModel.controlOrigin) { _, _ in
            viewModel.refreshPairingStatus()
        }
    }

    private var connectionView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                brandMark
                Text("Your browser, without the distance.")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .tracking(-1.2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ghostlight keeps Chromium running on your Linux host while this Mac feels like the browser itself.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .frame(maxWidth: 460, alignment: .leading)
                Spacer()
                Label("Persistent tabs · Native controls · WebRTC stream", systemImage: "sparkles")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.47, green: 0.29, blue: 0.95).opacity(0.17), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Divider()

            connectionPanel(compact: false)
                .frame(width: 420)
                .padding(44)
        }
    }

    private func connectionPanel(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if compact {
                Text("Connection")
                    .font(.title2.bold())
            } else {
                Text("Open your workspace")
                    .font(.title2.bold())
                Text(viewModel.hasPairedCredential
                     ? "This Mac has a native client token in Keychain for this control address."
                     : "Enter the control address and operator API token.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("CONTROL PLANE")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                TextField("http://192.168.4.50:8080", text: $viewModel.controlOrigin)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(viewModel.connect)
            }

            if viewModel.hasPairedCredential {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(Color(red: 0.43, green: 0.24, blue: 0.92))
                        .frame(width: 28, height: 28)
                        .background(Color(red: 0.43, green: 0.24, blue: 0.92).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Paired")
                            .font(.headline)
                        Text("Future launches use the Keychain credential.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API TOKEN")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    SecureField("Operator token", text: $viewModel.apiToken)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(viewModel.connectWithOperatorToken)
                    Text("Pairing uses this token once. The app stores only the enrolled client token in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("MAC NAME")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    TextField("This Mac", text: $nativeClientName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if case let .failed(message) = viewModel.controlState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = viewModel.pairingError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.hasPairedCredential {
                Button(action: viewModel.connect) {
                    HStack {
                        if case .connecting = viewModel.controlState {
                            ProgressView().controlSize(.small)
                        }
                        Text(viewModel.controlState == .connecting ? "Connecting…" : "Open Ghostlight")
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color(red: 0.43, green: 0.24, blue: 0.92))
                .disabled(viewModel.forgettingPairingInProgress || viewModel.controlState == .connecting)
                .keyboardShortcut(.defaultAction)

                Button(role: .destructive) {
                    Task { _ = await viewModel.forgetPairing() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.forgettingPairingInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Text(viewModel.forgettingPairingInProgress ? "Forgetting…" : "Forget Pairing")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.forgettingPairingInProgress || viewModel.controlState == .connecting)
            } else {
                Button {
                    Task { _ = await viewModel.pairThisMac(clientName: nativeClientName) }
                } label: {
                    HStack {
                        if viewModel.pairingInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Text(viewModel.pairingInProgress ? "Pairing…" : "Pair This Mac")
                        Spacer()
                        Image(systemName: "key.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color(red: 0.43, green: 0.24, blue: 0.92))
                .disabled(viewModel.pairingInProgress || viewModel.controlState == .connecting)
                .keyboardShortcut(.defaultAction)

                Button("Open with API Token", action: viewModel.connectWithOperatorToken)
                    .frame(maxWidth: .infinity)
                    .disabled(viewModel.pairingInProgress || viewModel.controlState == .connecting)
            }
        }
    }

    private var browserShell: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            navigationBar
            Divider()
            viewerSurface
        }
        .background(.bar)
    }

    private var tabStrip: some View {
        HStack(spacing: 5) {
            brandMark
                .scaleEffect(0.72)
                .frame(width: 30)
                .padding(.trailing, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(viewModel.session?.tabs ?? []) { tab in
                        tabButton(tab)
                    }
                }
            }

            Button {
                viewModel.newTab()
                showingHome = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canControl)
            .help("New tab")

            Spacer(minLength: 6)
            commandBadge
            controlBadge
            Button {
                showingConnection = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("Connection settings")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(.ultraThinMaterial)
    }

    private func tabButton(_ tab: BrowserTab) -> some View {
        Button {
            viewModel.activateTab(tab.id)
            showingHome = false
        } label: {
            HStack(spacing: 7) {
                Image(systemName: tab.loading ? "circle.dotted" : "globe")
                    .font(.caption)
                    .foregroundStyle(tab.active ? Color.accentColor : .secondary)
                Text((tab.title ?? "").isEmpty ? tab.url : tab.title ?? tab.url)
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
                if tab.active && viewModel.canControl {
                    Button {
                        viewModel.closeTab(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(tab.active ? Color(nsColor: .controlBackgroundColor) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canControl && !tab.active)
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            navButton("house", help: "Home") { showingHome = true }
            navButton("chevron.left", help: "Back", action: viewModel.goBack)
            navButton("chevron.right", help: "Forward", action: viewModel.goForward)
            navButton("arrow.clockwise", help: "Reload", action: viewModel.reload)

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Search or enter address", text: $viewModel.addressDraft)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit(openAddressDraft)
                if viewModel.activeTab?.loading == true {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.55)))
            .disabled(!viewModel.canControl)

            Button {
                showingFileImporter = true
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canControl)
            .help("Attach file")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.bar)
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canControl)
        .help(help)
    }

    @ViewBuilder
    private var viewerSurface: some View {
        if let streamURL = viewModel.streamURL {
            ZStack {
                ViewerWebView(
                    url: streamURL,
                    credential: viewModel.viewerBootstrap?.viewerCredential,
                    reloadToken: streamURL.hashValue ^ (viewModel.viewerBootstrap?.expiresAt.hashValue ?? 0),
                    onNavigationStarted: viewModel.viewerNavigationStarted,
                    onNavigationFinished: viewModel.viewerNavigationFinished,
                    onNavigationFailed: viewModel.viewerNavigationFailed,
                    onMediaReady: viewModel.viewerMediaReady,
                    onWebContentProcessTerminated: viewModel.viewerProcessTerminated
                )

                if showingHome {
                    nativeHome
                } else {
                    switch viewModel.surfaceState {
                    case .idle, .loadingPage:
                        surfaceOverlay(title: "Waking your browser", detail: "Connecting the native window to the live session.", progress: true)
                    case .pageReady:
                        surfaceOverlay(title: "Starting the stream", detail: "The viewer is ready. Waiting for the first decoded frame.", progress: true)
                    case let .failed(message):
                        streamUnavailableSurface(message)
                    case .mediaReady:
                        EmptyView()
                    }
                }
            }
        } else if showingHome {
            nativeHome
        } else {
            streamUnavailableSurface(viewModel.surfaceFailureMessage ?? "The live view is not connected.")
        }
    }

    private func streamUnavailableSurface(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Live view unavailable")
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                Button("Open Home") { showingHome = true }
                Button(viewModel.streamRecoveryInProgress ? "Reconnecting…" : "Reconnect Live View") {
                    viewModel.retryStream()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.streamRecoveryInProgress)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var nativeHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Home")
                            .font(.system(size: 30, weight: .semibold))
                        Text(viewModel.session?.name ?? "Browser")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show current page") { showingHome = false }
                        .buttonStyle(.bordered)
                }

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search the web or enter an address", text: $homeQuery)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .onSubmit(openHomeQuery)
                    Text("RETURN")
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.7)))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Shortcuts")
                            .font(.headline)
                        Spacer()
                        Button("Edit") { showingShortcutEditor = true }
                            .buttonStyle(.borderless)
                            .disabled(viewModel.workspacePreferences == nil)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(viewModel.shortcuts) { shortcut in
                            destinationButton(shortcut)
                        }
                    }
                    if viewModel.workspacePreferences == nil {
                        ProgressView("Loading shortcuts")
                            .controlSize(.small)
                    }
                    if let error = viewModel.preferencesError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Spaces")
                            .font(.headline)
                        Spacer()
                        TextField("New space", text: $newSpaceName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Button("Save current tabs") {
                            let name = newSpaceName
                            Task {
                                if await viewModel.createActivitySpace(named: name) { newSpaceName = "" }
                            }
                        }
                        .disabled(!viewModel.canControl || newSpaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(viewModel.activitySpaces) { space in
                        HStack {
                            Image(systemName: space.state == "active" ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                                .foregroundStyle(space.state == "active" ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(space.name)
                                Text("\(space.tabs.count) tabs · \(space.state.capitalized)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if space.state == "active" {
                                Button("Update") { Task { await viewModel.parkActivitySpace(space) } }
                            } else {
                                Button("Open") {
                                    Task { await viewModel.activateActivitySpace(space) }
                                    showingHome = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                if !viewModel.recentURLs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent")
                            .font(.headline)
                        ForEach(Array(viewModel.recentURLs.prefix(5)), id: \.self) { url in
                            Button {
                                viewModel.navigate(to: url)
                                showingHome = false
                            } label: {
                                Label(url, systemImage: "clock.arrow.circlepath")
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(!viewModel.canControl)
                        }
                    }
                }

                if !viewModel.chromeHandoffs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("From Chrome")
                                .font(.headline)
                            Spacer()
                            Text("Opens only when you choose")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(viewModel.chromeHandoffs) { handoff in
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer.and.arrow.down")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((handoff.title ?? "").isEmpty ? handoff.url : handoff.title ?? handoff.url)
                                        .lineLimit(1)
                                    Text("\(handoff.deviceName) · \(handoff.url)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Dismiss") { viewModel.dismissChromeHandoff(handoff) }
                                    .buttonStyle(.borderless)
                                    .disabled(viewModel.openingChromeHandoffIDs.contains(handoff.id))
                                Button(viewModel.openingChromeHandoffIDs.contains(handoff.id) ? "Opening…" : "Open") {
                                    viewModel.openChromeHandoff(handoff)
                                    showingHome = false
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!viewModel.canControl || viewModel.openingChromeHandoffIDs.contains(handoff.id))
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }

                if !viewModel.chromeBookmarks.isEmpty || !viewModel.chromeReadingList.isEmpty {
                    HStack(alignment: .top, spacing: 28) {
                        chromeLibraryColumn(
                            title: "Chrome bookmarks",
                            symbol: "bookmark",
                            items: Array(viewModel.chromeBookmarks.prefix(6))
                        )
                        chromeLibraryColumn(
                            title: "Reading List",
                            symbol: "text.book.closed",
                            items: Array(viewModel.chromeReadingList.filter { !$0.read }.prefix(6))
                        )
                    }
                }

                if let error = viewModel.chromeSyncError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Open tabs")
                            .font(.headline)
                        ForEach(Array((viewModel.session?.tabs ?? []).prefix(4))) { tab in
                            Button {
                                viewModel.activateTab(tab.id)
                                showingHome = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: tab.active ? "circle.fill" : "circle")
                                        .font(.system(size: 7))
                                        .foregroundStyle(tab.active ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((tab.title ?? "").isEmpty ? tab.url : tab.title ?? tab.url)
                                            .lineLimit(1)
                                        Text(tab.url)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tools")
                            .font(.headline)
                        homeTool("Upload a file to this session", symbol: "paperclip", enabled: viewModel.canControl) {
                            showingFileImporter = true
                        }
                        homeTool("New browser tab", symbol: "plus.square", enabled: viewModel.canControl) {
                            viewModel.newTab()
                            showingHome = true
                        }
                        homeTool("Connection settings", symbol: "slider.horizontal.3") {
                            showingConnection = true
                        }
                        homeTool("Connect your Chrome", symbol: "laptopcomputer.and.arrow.down") {
                            showingChromePairing = true
                        }
                    }
                    .frame(width: 220, alignment: .leading)
                }
            }
            .padding(.horizontal, 46)
            .padding(.vertical, 38)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func chromeLibraryColumn(title: String, symbol: String, items: [ChromeLibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            if items.isEmpty {
                Text("You’re caught up.")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button {
                    viewModel.openChromeLibraryItem(item)
                    showingHome = false
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((item.title ?? "").isEmpty ? item.url ?? "Untitled" : item.title ?? "Untitled")
                            .lineLimit(1)
                        Text("\(item.deviceName) · \(item.url ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canControl)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func destinationButton(_ shortcut: WorkspaceShortcut) -> some View {
        Button {
            viewModel.navigate(to: shortcut.url)
            showingHome = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcut.name).fontWeight(.medium)
                    Text(URL(string: shortcut.url)?.host ?? shortcut.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.separator.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canControl)
    }

    private func homeTool(
        _ title: String,
        symbol: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func openHomeQuery() {
        guard SessionViewModel.navigationTarget(for: homeQuery) != nil else { return }
        viewModel.navigate(to: homeQuery)
        showingHome = false
    }

    private func openAddressDraft() {
        guard SessionViewModel.navigationTarget(for: viewModel.addressDraft) != nil else { return }
        viewModel.navigate()
        showingHome = false
    }

    private func surfaceOverlay(title: String, detail: String, progress: Bool) -> some View {
        VStack(spacing: 12) {
            if progress { ProgressView().controlSize(.regular) }
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
    }

    private var brandMark: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                Image(systemName: "key.fill")
                    .rotationEffect(.degrees(-90))
                    .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 1))
            }
            .frame(width: 34, height: 34)
            Text("Ghostlight")
                .font(.system(.headline, design: .rounded).weight(.semibold))
        }
    }

    @ViewBuilder
    private var commandBadge: some View {
        switch viewModel.commandStatus {
        case .idle:
            EmptyView()
        case let .pending(count):
            Label(count == 1 ? "Sending" : "Sending \(count)", systemImage: "clock")
                .foregroundStyle(.secondary)
                .help("Waiting for the browser to finish")
        case let .failed(code, message):
            Button {
                viewModel.retryFailedCommand()
            } label: {
                Label("Command failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canControl)
            .help("\(code): \(message). Retry with the same command identifier.")
        }
    }

    @ViewBuilder
    private var controlBadge: some View {
        switch viewModel.controlState {
        case .controller:
            Label("Control", systemImage: "cursorarrow.rays")
                .foregroundStyle(.green)
        case .observer:
            Label("Observing", systemImage: "eye")
                .foregroundStyle(.secondary)
        case .expired:
            Label("Lease expired", systemImage: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case .connecting:
            Label("Connecting", systemImage: "ellipsis")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Offline", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        case .disconnected:
            EmptyView()
        }
    }
}

private struct ChromePairingView: View {
    @ObservedObject var viewModel: SessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var deviceName = Host.current().localizedName.map { "Chrome on \($0)" } ?? "My Chrome"
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Connect your Chrome")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Install the Continue in Ghostlight extension, generate a one-time code here, and paste it into the extension. The code expires after 10 minutes.")
                .foregroundStyle(.secondary)

            TextField("Device name", text: $deviceName)
                .textFieldStyle(.roundedBorder)

            if let pairing = viewModel.chromePairing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pairing code")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(pairing.pairingCode)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("This code pairs one Chrome and cannot be used again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = viewModel.chromeSyncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !viewModel.chromeDevices.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Connected devices")
                            .font(.headline)
                        Spacer()
                        Button("Refresh") { Task { await viewModel.refreshChromeDevices() } }
                            .buttonStyle(.borderless)
                    }
                    ForEach(viewModel.chromeDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("Can send selected tabs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                Task { await viewModel.revokeChromeDevice(device) }
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            HStack {
                Button(viewModel.chromePairing == nil ? "Generate code" : "Generate another code") {
                    isCreating = true
                    Task {
                        _ = await viewModel.createChromePairing(deviceName: deviceName)
                        isCreating = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isCreating { ProgressView().controlSize(.small) }
            }
        }
        .padding(26)
        .frame(width: 540)
        .task { await viewModel.refreshChromeDevices() }
    }
}

private struct ShortcutEditorView: View {
    @ObservedObject var viewModel: SessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var shortcuts: [WorkspaceShortcut]
    @State private var searchURL: String
    @State private var newName = ""
    @State private var newURL = ""
    @State private var saving = false

    init(viewModel: SessionViewModel) {
        self.viewModel = viewModel
        _shortcuts = State(initialValue: viewModel.shortcuts)
        _searchURL = State(
            initialValue: viewModel.workspacePreferences?.searchURL ?? WorkspacePreferences.defaultSearchURL
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Search Provider") {
                    TextField("https://example.com/search?q={query}", text: $searchURL)
                    Text("Use one {query} placeholder in an HTTP(S) search URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Shortcuts") {
                    ForEach($shortcuts) { $shortcut in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Name", text: $shortcut.name)
                                TextField("https://example.com", text: $shortcut.url)
                                    .font(.caption)
                            }
                            Button { move(shortcut.id, by: -1) } label: {
                                Image(systemName: "arrow.up")
                            }
                            .disabled(shortcuts.first?.id == shortcut.id)
                            Button { move(shortcut.id, by: 1) } label: {
                                Image(systemName: "arrow.down")
                            }
                            .disabled(shortcuts.last?.id == shortcut.id)
                            Button(role: .destructive) {
                                shortcuts.removeAll { $0.id == shortcut.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }

                Section("Add Shortcut") {
                    TextField("Name", text: $newName)
                    TextField("https://example.com", text: $newURL)
                    Button("Add") { addShortcut() }
                        .disabled(!isValid(name: newName, url: newURL) || shortcuts.count >= 24)
                }
            }
            .navigationTitle("Edit Shortcuts")
            .frame(minWidth: 560, minHeight: 420)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            if await viewModel.replaceHomePreferences(
                                searchURL: searchURL,
                                shortcuts: shortcuts
                            ) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(
                        saving
                            || !WorkspacePreferences.isValidSearchURLTemplate(searchURL)
                            || shortcuts.contains { !isValid(name: $0.name, url: $0.url) }
                    )
                }
            }
        }
    }

    private func addShortcut() {
        shortcuts.append(
            WorkspaceShortcut(
                id: UUID().uuidString.lowercased(),
                name: newName.trimmingCharacters(in: .whitespacesAndNewlines),
                url: newURL.trimmingCharacters(in: .whitespacesAndNewlines),
                position: shortcuts.count
            )
        )
        newName = ""
        newURL = ""
    }

    private func move(_ id: String, by offset: Int) {
        guard let source = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard shortcuts.indices.contains(destination) else { return }
        shortcuts.swapAt(source, destination)
    }

    private func isValid(name: String, url: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let components = URLComponents(string: url),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return false }
        return true
    }
}
