import SwiftUI

struct RebuildSheet: View {
    @Environment(ServerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverSourcePath") private var sourcePath = Server.defaultSourcePath
    @State private var rebuild = Rebuild(sourcePath: Server.defaultSourcePath)
    @State private var choosingFolder = false
    @State private var showingOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rebuild Server").font(.title3.weight(.semibold))
            source
            Divider()
            ForEach(Rebuild.Step.allCases) { step in
                StepRow(step: step, state: rebuild.state(of: step))
            }
            if !rebuild.output.isEmpty {
                DisclosureGroup("Output", isExpanded: $showingOutput) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(rebuild.output)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("end")
                        }
                        .frame(height: 180)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: rebuild.output) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Run tests first", isOn: $rebuild.runTests)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(rebuild.isRunning)
                Spacer()
                if rebuild.isRunning {
                    // Stops the build or tests; install.sh, once it's started, runs to the end
                    Button(rebuild.isCancelling ? "Cancelling…" : "Cancel") { rebuild.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(!rebuild.canCancel)
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(rebuild.finished ? "Rebuild Again" : "Rebuild") {
                    rebuild.start(model: model)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(rebuild.isRunning || rebuild.sourceProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(rebuild.isRunning)
        .task(id: sourcePath) {
            rebuild.sourcePath = sourcePath
            await rebuild.checkSource()
        }
        .onChange(of: rebuild.states) { _, states in
            if states.values.contains(where: { if case .failed = $0 { true } else { false } }) { showingOutput = true }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sourcePath = url.path }
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("From the files on disk, without pulling:").foregroundStyle(.secondary)
            HStack {
                Text((sourcePath as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { choosingFolder = true }
                    .controlSize(.small)
                    .disabled(rebuild.isRunning)
            }
            if let problem = rebuild.sourceProblem {
                Label(problem, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            } else if let uncommitted = rebuild.uncommitted, uncommitted > 0 {
                Label("Includes ^[\(uncommitted) uncommitted file](inflect: true), in the server or ios/Shared",
                      systemImage: "pencil.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("macOS asks for your password to install it.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StepRow: View {
    let step: Rebuild.Step
    let state: Rebuild.State

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title).fontWeight(state == .running ? .semibold : .regular)
                Text(detail).font(.caption).foregroundStyle(isFailed ? .red : .secondary)
            }
        }
        .opacity(state == .waiting || state == .skipped ? 0.5 : 1)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var detail: String {
        switch state {
        case .waiting, .running: step.command
        case .done(let summary): "\(step.command) · \(summary)"
        case .failed(let reason): reason
        case .skipped: "Skipped"
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .waiting, .skipped: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
