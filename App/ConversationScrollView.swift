import SwiftUI
import UIKit

/// Keep content-size changes separate from the reader's scroll intent.
struct ConversationScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var followingChanged: (Bool) -> Void = { _ in }
    var latestRequest = 0
    @State private var scroll = ConversationScrollState()
    @State private var scrollRequest = 0
    @Namespace private var bottom

    private struct Metrics: Equatable {
        let height: CGFloat
        let viewport: CGFloat
        let top: CGFloat
        let distance: CGFloat
        init(_ geometry: ScrollGeometry) {
            height = geometry.contentSize.height
            viewport = geometry.visibleRect.height
            top = geometry.visibleRect.minY
            distance = height - geometry.visibleRect.maxY
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // History is paged by the caller. Use measured row heights here;
                // lazy estimates can leave an empty viewport after large updates.
                VStack(alignment: .leading, spacing: 24) {
                    content()
                    Color.clear.frame(height: 1).id(bottom)
                }
                .frame(maxWidth: 850).padding(24).frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .defaultScrollAnchor(.top, for: .alignment)
            .onScrollGeometryChange(for: Metrics.self, of: Metrics.init) { old, new in
                scroll.geometryChanged(distanceFromBottom: Double(new.distance))
                // Follow the measured end only after the new layout is available.
                if scroll.shouldFollow && (old.height != new.height || old.viewport != new.viewport || new.top > new.height) {
                    scrollRequest += 1
                }
            }
            .onScrollPhaseChange { _, phase, context in
                let userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                scroll.userScrollChanged(active: userScrolling,
                                         distanceFromBottom: Double(Metrics(context.geometry).distance))
                if phase == .idle && scroll.shouldFollow { scrollRequest += 1 }
            }
            .onChange(of: scroll.shouldFollow) { _, following in followingChanged(following) }
            .onChange(of: latestRequest) { _, _ in
                scroll.requestLatest()
                scrollRequest += 1
            }
            .task(id: scrollRequest) {
                await Task.yield()
                guard !Task.isCancelled, scroll.shouldFollow else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(bottom, anchor: .bottom) }
            }
        }
    }
}
