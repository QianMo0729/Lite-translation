import SwiftUI

struct PanelView: View {
    static let width: CGFloat = 380

    @Bindable var model: PanelModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("输入要翻译的词或句子", text: $model.query, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...3)
                .focused($queryFocused)
                .onSubmit { model.onSubmit(model.query) }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            if model.phase != .idle {
                Divider()
                answer
            }
            if !model.contextNote.isEmpty {
                Divider()
                footer
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        // The panel is sized to this, so it grows as the answer streams in.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.onHeightChange($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: model.focusRequests) { queryFocused = true }
        .onExitCommand { model.onClose() }
    }

    @ViewBuilder
    private var answer: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .working(let status):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(14)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if let action = model.failureAction {
                    Button(action.title, action: action.run).controlSize(.small)
                }
            }
            .padding(14)
        case .answering, .done:
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.headline.isEmpty {
                        Text(model.headline).font(.system(size: 20, weight: .semibold))
                    }
                    if !model.detail.isEmpty {
                        Text(model.detail)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(model.headline.isEmpty ? HierarchicalShapeStyle.primary : .secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: model.contextUsed ? "text.viewfinder" : "eye.slash")
            Text(model.contextNote)
            if let action = model.contextAction {
                Button(action.title, action: action.run)
                    .buttonStyle(.link)
            }
            Spacer(minLength: 8)
            Text(model.timingNote)
                .monospacedDigit()
                .help(model.timingDetail)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
