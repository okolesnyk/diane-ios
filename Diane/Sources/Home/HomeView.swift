import DianeKit
import SwiftUI

/// The tile-grid launcher — renamed Home (owner 2026-08-08): every module
/// the household has ON, plus grayed tiles for what the future lands here.
/// Off modules disappear entirely — the switchboard is "what the family
/// sees, on every client". Long-press pins a module to the bottom menu
/// (device-local): replace the main Calendar slot, or add/remove one of
/// the up-to-two extra tabs (owner 2026-08-10).
///
/// Opening a tile NEVER shows a back button (owner 2026-08-08): a module
/// page always wears the root chrome — title left, avatar right — exactly
/// as if it sat in the bottom menu. The tile of the module that IS in the
/// bottom menu selects that tab instead of pushing a twin; re-tapping Home
/// in the bottom menu returns pushed modules to this grid.
struct HomeView: View {
    let context: SignedInContext
    /// Owned by RootTabView so re-tapping the Home tab can pop to the grid.
    @Binding var path: NavigationPath
    /// What the module tabs currently show — their tiles switch tabs.
    let pinnedModules: [DianeModule]
    let selectPinnedTab: (DianeModule) -> Void

    @Environment(HouseholdClock.self) private var clock
    @Environment(PinnedTabsStore.self) private var pinnedTabs

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                DianeTopBar(context: context, title: "Home")
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(NavigationLogic.enabledModules(clock.modules)) { module in
                            Button {
                                if pinnedModules.contains(module) {
                                    selectPinnedTab(module)
                                } else {
                                    path.append(module)
                                }
                            } label: {
                                tile(title: module.title, systemImage: module.systemImage)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    pinnedTabs.pin(module)
                                } label: {
                                    Label(
                                        pinnedTabs.pinned.first == module
                                            ? "Pinned to the tab bar" : "Pin to the tab bar",
                                        systemImage: "pin"
                                    )
                                }
                                .disabled(pinnedTabs.pinned.first == module)
                                // Up to two EXTRA bottom items (owner
                                // 2026-08-10) — add here, remove here.
                                if pinnedTabs.pinned.dropFirst().contains(module) {
                                    Button {
                                        pinnedTabs.remove(module)
                                    } label: {
                                        Label("Remove from the tab bar", systemImage: "pin.slash")
                                    }
                                } else if !pinnedTabs.pinned.contains(module),
                                          pinnedTabs.pinned.count < PinnedTabsStore.maxSlots {
                                    Button {
                                        pinnedTabs.add(module)
                                    } label: {
                                        Label("Add to the tab bar", systemImage: "plus.circle")
                                    }
                                }
                            }
                        }
                        ForEach(FutureModule.allCases) { future in
                            tile(title: future.title, systemImage: future.systemImage, comingLater: true)
                        }
                    }
                    .padding(16)
                }
            }
            .dianeRootChrome()
            .navigationDestination(for: DianeModule.self) { module in
                ModuleScreen(module: module, context: context, open: { path.append($0) })
            }
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
