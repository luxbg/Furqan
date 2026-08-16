import SwiftUI

/// Shows two facing mushaf pages at a time, right-to-left: the lower
/// (odd) page number sits on the right, matching how a physical mushaf
/// opens. `rightPage` is always odd; `rightPage + 1` is the left page.
///
/// The current spread, plus whichever neighbor spread the drag is
/// heading toward, are laid out side by side and dragged 1:1 with the
/// cursor so the page visibly follows the gesture. Release either
/// commits to the neighbor (spring-animated the rest of the way) or
/// snaps back to the current spread, based on drag distance and flick
/// velocity - see DragPhysics below.
struct ContentView: View {
    @State private var rightPage = 1
    @State private var dragOffset: CGFloat = 0
    /// Cached from the GeometryReader for use by keyboard-triggered
    /// page turns, which have no geometry of their own to read.
    @State private var containerWidth: CGFloat = 0
    /// Right-page numbers whose WKWebView should stay mounted (and
    /// therefore loaded), oldest-visited first, capped at
    /// `maxMountedSpreads`. Recency-based rather than a fixed distance
    /// from `rightPage`, so paging several spreads out and back still
    /// finds everything in between already loaded - see
    /// `registerVisit(_:)`.
    @State private var mountedRightPages: [Int] = [1]
    @State private var recitationBar = RecitationBarState()
    @State private var recitationSession: RecitationSession?
    private let maxMountedSpreads = 20
    /// How many extra spreads beyond the immediate neighbor to
    /// speculatively warm, in whichever direction the user just paged -
    /// see `preload(ahead:direction:count:)`.
    private let preloadLookahead = 2
    private let store = QuranPageStore()

    private let pageBackground = Color(hex: "242322")

    private enum DragPhysics {
        static let commitFraction: CGFloat = 0.35
        static let commitFloor: CGFloat = 120
        static let commitCeiling: CGFloat = 260
        static let flickPredictedFraction: CGFloat = 0.6
        static let flickMinRealDrag: CGFloat = 44
        /// Resistance applied when dragging past the first/last spread,
        /// where there's no neighbor to reveal.
        static let reboundFactor: CGFloat = 0.3
        static let reboundCap: CGFloat = 80
        static let commitSpring = Animation.spring(response: 0.32, dampingFraction: 0.88)
        static let snapBackSpring = Animation.spring(response: 0.28, dampingFraction: 0.82)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Keyed by page number rather than a fixed
                // previous/current/next slot, so a spread that's
                // already loaded keeps the same WKWebView instance as
                // it moves between roles across a commit. Keying by
                // slot instead would repurpose each slot's WKWebView
                // to a different page's SVG on every commit, forcing
                // a reload that briefly flashes the outgoing page's
                // stale content back onscreen before it catches up.
                //
                // Dragging right (positive translation) reveals the
                // previous spread sliding in from the right, mirroring
                // the arrow-key/transition convention that "forward"
                // (toward higher page numbers) moves content leftward.
                ForEach(visibleRightPages, id: \.self) { right in
                    spreadView(for: right)
                        .offset(x: xOffset(for: right, containerWidth: geo.size.width))
                }

                // Sits above the page WKWebViews so the drag is never
                // swallowed by their own event handling.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragGesture(width: geo.size.width))
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            withAnimation(.easeOut(duration: 0.2)) {
                                recitationBar.toggle()
                            }
                        }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, newWidth in containerWidth = newWidth }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(pageBackground)
        .overlay(alignment: .bottom) {
            RecitationControlBar(state: recitationBar) {
                let session = RecitationSession(
                    currentPages: { rightPage...(rightPage + 1) },
                    barState: recitationBar
                )
                recitationSession = session
                session.start()
            } onStopReciting: {
                recitationSession?.stop()
                recitationSession = nil
            }
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handleKeyDown($0) }
            preload(ahead: rightPage, direction: .forward, count: preloadLookahead)
        }
    }

    /// The immediate neighbor spreads are always mounted (needed for
    /// the drag itself to reveal them), unioned with whatever recency
    /// history `mountedRightPages` has retained. Without the recency
    /// cache, a spread that drops out of the immediate neighbor window
    /// gets torn down - its WKWebView along with it - and revisiting it
    /// forces a full reload, which briefly shows the background color
    /// where its content should be while the reload's JS is still
    /// repositioning the crops.
    private var visibleRightPages: [Int] {
        let required = [adjacentRightPage(before: rightPage), rightPage, adjacentRightPage(after: rightPage)].compactMap { $0 }
        return Set(required).union(mountedRightPages).sorted()
    }

    /// Moves `right` to the most-recently-visited end, then evicts the
    /// least-recently-visited pages (never one of `right`'s own
    /// immediate neighbors, since those must stay mounted regardless of
    /// recency) once the cap is exceeded.
    private func registerVisit(_ right: Int) {
        mountedRightPages.removeAll { $0 == right }
        mountedRightPages.append(right)
        let required = Set([adjacentRightPage(before: right), right, adjacentRightPage(after: right)].compactMap { $0 })
        while mountedRightPages.count > maxMountedSpreads {
            guard let evictIndex = mountedRightPages.firstIndex(where: { !required.contains($0) }) else { break }
            mountedRightPages.remove(at: evictIndex)
        }
    }

    /// Speculatively warms a few spreads beyond the immediate neighbor,
    /// in the direction the user just turned, by feeding them through
    /// `registerVisit(_:)` - mounting them off-screen so their
    /// WKWebViews load in the background. Cheap bet: if the user keeps
    /// paging the same way, those spreads are already loaded by the
    /// time they're reached; if they reverse instead, the speculative
    /// entries just age out of the recency cache like anything else.
    private func preload(ahead right: Int, direction: SpreadDirection, count: Int) {
        var cursor = right
        for _ in 0..<count {
            let next = direction == .forward ? adjacentRightPage(after: cursor) : adjacentRightPage(before: cursor)
            guard let next else { break }
            registerVisit(next)
            cursor = next
        }
    }

    /// `stepsAway` is how many spreads `right` sits from the current
    /// one; the carried-offset math in `commit(toward:)` shifts
    /// `rightPage` and `dragOffset` together by exactly one spread, so
    /// this stays visually continuous for every mounted page, not just
    /// the immediate neighbor being dragged.
    private func xOffset(for right: Int, containerWidth: CGFloat) -> CGFloat {
        let stepsAway = (right - rightPage) / 2
        return -CGFloat(stepsAway) * containerWidth + dragOffset
    }

    @ViewBuilder
    private func spreadView(for right: Int) -> some View {
        HStack(spacing: -60) {
            pageView(for: right + 1)
            pageView(for: right)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pageView(for page: Int) -> some View {
        if let url = store.svgURL(for: page) {
            MushafPageView(svgURL: url, isOpenerPage: page <= 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            pageBackground
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                dragOffset = resistedOffset(for: value.translation.width)
            }
            .onEnded { value in
                let translation = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let commitThreshold = min(max(width * DragPhysics.commitFraction, DragPhysics.commitFloor), DragPhysics.commitCeiling)
                let commits = abs(translation) >= commitThreshold
                    || (abs(predicted) >= width * DragPhysics.flickPredictedFraction
                        && abs(translation) >= DragPhysics.flickMinRealDrag)

                if translation < 0, commits, adjacentRightPage(before: rightPage) != nil {
                    commit(toward: .backward, width: width)
                } else if translation > 0, commits, adjacentRightPage(after: rightPage) != nil {
                    commit(toward: .forward, width: width)
                } else {
                    snapBack()
                }
            }
    }

    private func resistedOffset(for translation: CGFloat) -> CGFloat {
        if translation > 0, adjacentRightPage(after: rightPage) == nil {
            return min(translation * DragPhysics.reboundFactor, DragPhysics.reboundCap)
        }
        if translation < 0, adjacentRightPage(before: rightPage) == nil {
            return max(translation * DragPhysics.reboundFactor, -DragPhysics.reboundCap)
        }
        return translation
    }

    private enum SpreadDirection { case forward, backward }

    /// Swaps `rightPage` to the neighbor immediately, carrying
    /// `dragOffset` over to the value that renders at the exact same
    /// on-screen position under the new page - so the swap itself is
    /// visually a no-op - then animates the rest of the way to 0.
    /// Deferring the `rightPage` swap to an animation completion
    /// callback instead (as an earlier version did) is prone to races:
    /// if a new drag starts before the callback fires, or the callback
    /// fires late, gestures can get dropped or a stale callback can
    /// stomp an in-progress drag's offset out from under it.
    private func commit(toward direction: SpreadDirection, width: CGFloat) {
        dragOffset += direction == .forward ? -width : width
        rightPage = direction == .forward ? nextRightPage(rightPage) : previousRightPage(rightPage)
        registerVisit(rightPage)
        preload(ahead: rightPage, direction: direction, count: preloadLookahead)
        withAnimation(DragPhysics.commitSpring) {
            dragOffset = 0
        }
    }

    private func snapBack() {
        withAnimation(DragPhysics.snapBackSpring) {
            dragOffset = 0
        }
    }

    private func adjacentRightPage(after right: Int) -> Int? {
        let target = min(right + 2, oddPageAtOrBelow(store.pageCount))
        return target != right ? target : nil
    }

    private func adjacentRightPage(before right: Int) -> Int? {
        let target = max(right - 2, 1)
        return target != right ? target : nil
    }

    private func nextRightPage(_ right: Int) -> Int { adjacentRightPage(after: right) ?? right }
    private func previousRightPage(_ right: Int) -> Int { adjacentRightPage(before: right) ?? right }

    private func oddPageAtOrBelow(_ page: Int) -> Int {
        page % 2 == 0 ? page - 1 : page
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 123: // left arrow -> forward in reading order (right-to-left)
            if adjacentRightPage(after: rightPage) != nil { commit(toward: .forward, width: containerWidth) }
            return nil
        case 124: // right arrow -> backward in reading order
            if adjacentRightPage(before: rightPage) != nil { commit(toward: .backward, width: containerWidth) }
            return nil
        default:
            return event
        }
    }
}
