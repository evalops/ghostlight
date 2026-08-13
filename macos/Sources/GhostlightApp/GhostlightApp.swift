import AppKit
import SwiftUI

@main
struct GhostlightApp: App {
    var body: some Scene {
        WindowGroup("Ghostlight") {
            ContentView()
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = SessionViewModel()
    @FocusState private var addressFocused: Bool
    @State private var showingConnection = false
    @State private var showingFileImporter = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if viewModel.session == nil || viewModel.streamURL == nil {
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
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { viewModel.attach(url) }
        }
        .onChange(of: addressFocused) { _, focused in
            viewModel.setAddressFocused(focused)
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
                Text("Use the private address and API token from your Ghostlight host.")
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

            VStack(alignment: .leading, spacing: 8) {
                Text("API TOKEN")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                SecureField("Required", text: $viewModel.apiToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(viewModel.connect)
                Text("Held in memory for this app session. It is not written to preferences.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if case let .failed(message) = viewModel.controlState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            .disabled(viewModel.controlState == .connecting)
            .keyboardShortcut(.defaultAction)
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

            Button(action: viewModel.newTab) {
                Image(systemName: "plus")
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canControl)
            .help("New tab")

            Spacer(minLength: 6)
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
                    .onSubmit(viewModel.navigate)
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
                    reloadToken: streamURL.hashValue,
                    onNavigationStarted: viewModel.viewerNavigationStarted,
                    onNavigationFinished: viewModel.viewerNavigationFinished,
                    onNavigationFailed: viewModel.viewerNavigationFailed,
                    onMediaReady: viewModel.viewerMediaReady
                )

                switch viewModel.surfaceState {
                case .idle, .loadingPage:
                    surfaceOverlay(title: "Waking your browser", detail: "Connecting the native window to the live session.", progress: true)
                case .pageReady:
                    surfaceOverlay(title: "Starting the stream", detail: "The viewer is ready. Waiting for the first decoded frame.", progress: true)
                case let .failed(message):
                    surfaceOverlay(title: "Stream unavailable", detail: message, progress: false)
                case .mediaReady:
                    EmptyView()
                }
            }
        }
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
