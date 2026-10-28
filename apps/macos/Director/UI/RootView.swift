import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearanceRaw = AppAppearance.light.rawValue

    var body: some View {
        WorkspaceColumns(model: model)
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 1080, minHeight: 680)
        .background(Palette.windowBackground)
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
            if let message = model.errorMessage {
                errorToast(message)
                    .padding(.bottom, 18)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.errorMessage)
    }

    private func errorToast(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.error)
            Text(message)
                .font(Typography.captionRegular)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: 520, alignment: .leading)
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
