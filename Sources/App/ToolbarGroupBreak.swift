import SwiftUI

/// A fixed break between two `.primaryAction` toolbar groups, so each side gets its own capsule.
///
/// `ToolbarSpacer` is the only control that draws one and it arrived in macOS 26; below that the
/// break is absent and the items share a capsule. Every call site wants the same break, so the
/// availability check lives here rather than at each of them.
struct ToolbarGroupBreak: ToolbarContent {
    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }
}
