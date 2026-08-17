import SwiftUI

/// Full-screen overlay that presents the developer profile card above the
/// Settings screen. Presented by double-tapping "RAKIB" in the About card.
///
/// The card uses a glass material, a soft shadow, and a spring scale from
/// 0.92 to 1.0 with a fade. Respects Reduce Motion (fade only, no scale)
/// and VoiceOver, and is dismissible by close button, tapping outside, or
/// dragging the card down.
public struct DeveloperProfileOverlay: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hapticService: HapticServiceProtocol = ServiceContainer.shared.hapticService
    @State private var cardScale: CGFloat = 0.92

    public init(isPresented: Binding<Bool>) {
        _isPresented = isPresented
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)

            developerCard
                .scaleEffect(cardScale)
                .animation(
                    reduceMotion ? .linear(duration: 0) : AppTheme.defaultSpring,
                    value: cardScale
                )
                .onAppear { cardScale = 1 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
        .transition(.opacity)
    }

    private var developerCard: some View {
        VStack(spacing: 16) {
            Image("DeveloperPortrait")
                .resizable()
                .scaledToFill()
                .frame(width: 144, height: 144)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 2))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                .accessibilityLabel("FluxDL developer portrait")

            VStack(spacing: 4) {
                Text(LegalDocuments.developerName)
                    .font(.title.bold())
                Text("Developer of FluxDL")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button(action: dismiss) {
                Label("Close", systemImage: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall))
                    .foregroundStyle(Color.blue)
            }
            .accessibilityLabel("Close developer profile")
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusLarge, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .padding(.horizontal, 32)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onEnded { value in
                    if value.translation.height > 100 { dismiss() }
                }
        )
        .accessibilityElement(children: .contain)
    }

    private func dismiss() {
        hapticService.selectionChanged()
        isPresented = false
    }
}