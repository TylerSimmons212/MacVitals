import SwiftUI

/// First launch: what Mac Vitals does, and the optional permissions that let it see more.
/// Nothing is required; every permission is explained by what it unlocks, and each can be
/// changed later in Settings › Permissions.
struct WelcomeView: View {
    let onFinish: () -> Void
    @Environment(Permissions.self) private var permissions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 30)
                .padding(.bottom, 20)

            PermissionList()
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .glassCard(cornerRadius: 22, padding: 0)
                .padding(.horizontal, 28)
                .entrance(delay: 0.12)

            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
        }
        .frame(width: 640)
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.25))
                    .frame(width: 96, height: 96)
                    .blur(radius: 24)
                    .scaleEffect(glow ? 1.08 : 0.92)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
            }
            .onAppear {
                // One gentle pulse on arrival, not a loop (nothing animates continuously).
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2)) { glow = true }
            }
            .entrance()

            VStack(spacing: 6) {
                Text("Welcome to Mac Vitals")
                    .font(.largeTitle.weight(.bold))
                Text("Mac Vitals works right away. These optional permissions let it see more of your Mac. Allow the ones you want now, or later in Settings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }
            .entrance(delay: 0.06)
        }
    }

    private var footer: some View {
        HStack {
            Label(summary, systemImage: permissions.grantedCount == PermissionKind.allCases.count ? "checkmark.seal.fill" : "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(.smooth, value: permissions.grantedCount)
            Spacer()
            Button(action: onFinish) {
                Text(permissions.hasFullDiskAccess ? "Get Started" : "Continue")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .pointerStyle(.link)
        }
    }

    private var summary: String {
        let count = permissions.grantedCount
        if count == PermissionKind.allCases.count { return "All set. Mac Vitals can see everything it needs." }
        if count == 0 { return "Nothing is required. You can change these any time." }
        return "\(count) of \(PermissionKind.allCases.count) allowed. You can change these any time."
    }
}
