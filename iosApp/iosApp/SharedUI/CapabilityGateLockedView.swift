import SwiftUI
import os
import UIKit
@preconcurrency import Shared
import UniformTypeIdentifiers

struct CapabilityGateLockedView: View {
    let gate: IOSCapabilityGate

    var body: some View {
        ZStack {
            AmberTheme.background.ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(AmberTheme.accentAmber)
                    .frame(width: 58, height: 58)
                    .background(AmberTheme.accentAmber.opacity(0.12), in: Circle())

                Text(gate.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AmberTheme.foreground)

                Text(gate.disabledReason)
                    .font(.footnote)
                    .foregroundStyle(AmberTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 28)

                Text("这是 AmberAgent 的受控能力。默认关闭用于保护工具执行、外部连接和远程操作；可在设置页对应行开启。")
                    .font(.caption)
                    .foregroundStyle(AmberTheme.muted2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 28)
            }
            .padding(.horizontal, 18)
        }
        .navigationBarBackButtonHidden(false)
    }
}
