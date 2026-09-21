import SwiftUI

struct SidePanelTabStrip: View {
    @Binding var selection: SidePanelTab
    let tabs: [SidePanelTab]
    let effectiveTab: SidePanelTab

    var body: some View {
        if #available(macOS 26.0, *) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.self) { tab in
                    tabButton(for: tab)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Side panel tab")
            .padding(4)
            .glassEffect(in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .padding(.horizontal, 12)
            .padding(.top, 12)
        } else {
            Picker(selection: $selection) {
                ForEach(tabs, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            } label: {
                Text("Side panel tab")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func tabButton(for tab: SidePanelTab) -> some View {
        let isSelected = effectiveTab == tab
        Button {
            selection = tab
        } label: {
            Text(tab.rawValue)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background {
                    if isSelected {
                        Capsule().fill(Color.accentColor)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
