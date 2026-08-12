import SwiftUI

@main
struct GhostlightApp: App {
    var body: some Scene {
        WindowGroup("Ghostlight") {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = SessionViewModel()

    var body: some View {
        Group {
            if let viewerURL = viewModel.viewerURL {
                connectedView(viewerURL: viewerURL)
            } else {
                connectionView
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ghostlight")
                    .font(.largeTitle.bold())
                Text("Connect to a Ghostlight control plane to open its browser viewer.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Control-plane URL", text: $viewModel.controlPlaneURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        viewModel.connect()
                    }

                HStack {
                    Button("Connect") {
                        viewModel.connect()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isConnecting)

                    if viewModel.isConnecting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if case let .failed(message) = viewModel.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(32)
    }

    private func connectedView(viewerURL: URL) -> some View {
        VStack(spacing: 0) {
            ViewerWebView(url: viewerURL, reloadToken: viewModel.reloadToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") {
                    viewModel.reloadViewer()
                }
                Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right") {
                    viewModel.disconnect()
                }
            }
            .padding(12)
        }
    }
}
