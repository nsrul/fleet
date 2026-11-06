import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.light.rawValue

    var body: some View {
        WorkspaceColumns(model: model)
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 1080, minHeight: 680)
        .background {
            if model.panelSolidity >= 0.999 {
                Palette.windowBackground
            }
        }
        .background {
            WindowOpacity(transparent: model.panelSolidity < 0.999)
        }
        .background {
            if model.isPreview {
                PreviewWindowFrame()
            }
        }
        .preferredColorScheme(AppAppearance(rawValue: appearanceRaw)?.colorScheme ?? .light)
        .onAppear {
            model.applyAppearance(appearanceRaw)
        }
        .onChange(of: appearanceRaw) { _, newValue in
            model.applyAppearance(newValue)
        }
        .task {
            await model.bootstrap()
        }
        .sheet(isPresented: $model.showNewAgent) {
            NewAgentSheet(model: model)
        }
        .sheet(isPresented: $model.showSplitPicker) {
            SplitPickerSheet(model: model)
        }
        .alert(
            "Stop session?",
            isPresented: Binding(
                get: { model.pendingStopID != nil },
                set: { presented in
                    if !presented { model.pendingStopID = nil }
                }
            )
        ) {
            Button("Stop", role: .destructive) {
                if let id = model.pendingStopID {
                    model.stopSession(id)
                }
            }
            Button("Cancel", role: .cancel) {
                model.pendingStopID = nil
            }
        } message: {
            Text("The process receives a termination request. Other sessions keep running.")
        }
        .overlay(alignment: .bottom) {
            if let notice = model.errorNotice {
                errorToast(notice)
                    .padding(.bottom, 18)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.errorNotice)
    }

    private func errorToast(_ notice: UserNotice) -> some View {
        CappedWidth(maxWidth: 480) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.error)
                    .accessibilityHidden(true)
                Text(notice.title)
                    .font(Typography.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    model.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

/// Uses the content’s own width, and only wraps once that width passes the cap.
private struct CappedWidth: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let limit = min(proposal.width ?? maxWidth, maxWidth)
        let ideal = subview.sizeThatFits(.unspecified)
        if ideal.width <= limit {
            return ideal
        }
        return subview.sizeThatFits(ProposedViewSize(width: limit, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}
