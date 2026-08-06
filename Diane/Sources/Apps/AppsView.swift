import DianeKit
import SwiftUI

/// The tile-grid launcher (M9e design, Page 4): every module the household
/// has ON, plus grayed tiles for what the future lands here. Off modules
/// disappear entirely — the switchboard is "what the family sees, on every
/// client". Long-press pins a module to the fourth tab (device-local).
struct AppsView: View {
    let context: SignedInContext
    @Environment(HouseholdClock.self) private var clock
    @Environment(FourthTabStore.self) private var fourthTab

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(NavigationLogic.enabledModules(clock.modules)) { module in
                        NavigationLink(value: module) {
                            tile(title: module.title, systemImage: module.systemImage)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                fourthTab.pin(module)
                            } label: {
                                Label(
                                    fourthTab.pinned == module
                                        ? "Pinned to the tab bar" : "Pin to the tab bar",
                                    systemImage: "pin"
                                )
                            }
                            .disabled(fourthTab.pinned == module)
                        }
                    }
                    ForEach(FutureModule.allCases) { future in
                        tile(title: future.title, systemImage: future.systemImage, comingLater: true)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Apps")
            .navigationDestination(for: DianeModule.self) { module in
                ModuleScreen(module: module, context: context)
            }
            .toolbar { SettingsAvatarButton(context: context) }
        }
    }

    private func tile(title: String, systemImage: String, comingLater: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30))
                .foregroundStyle(comingLater ? Color.secondary : Color.accentColor)
            Text(title)
                .font(.headline)
            if comingLater {
                Text("Coming later")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
        .opacity(comingLater ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(comingLater ? "\(title), coming later" : title)
    }
}

/// The top-bar rule (M9e): the trailing avatar on every top-level page opens
/// the Settings PAGE as a push, never a sheet.
struct SettingsAvatarButton: ToolbarContent {
    let context: SignedInContext

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                SettingsView(context: context, asPage: true)
            } label: {
                MemberAvatarView(
                    name: context.session.memberName,
                    colorHex: context.session.memberColor,
                    avatar: nil,
                    size: 30
                )
            }
            .accessibilityLabel("Settings")
        }
    }
}
