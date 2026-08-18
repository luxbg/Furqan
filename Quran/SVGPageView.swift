import SwiftUI
import WebKit

/// Renders a full mushaf page - running headers, page number, and
/// Quranic text - as independently-cropped regions within a SINGLE
/// WKWebView. Each region is a `<use>` reference into one shared,
/// hidden copy of the page's SVG markup, so the document (hundreds of
/// glyph paths) is parsed once per page instead of once per region:
/// that redundant 4x re-parse - not the crop or the layout - was what
/// page turns were actually spending their time on.
struct MushafPageView: NSViewRepresentable {
    let svgURL: URL
    /// Pages 1-2 only: give the Quranic text more crop padding than
    /// normal pages (0.03) so it reads a bit smaller/less zoomed.
    var isOpenerPage: Bool = false
    /// Live-recitation word masking, driven by `RecitationProgress`.
    /// `.unmasked` (the default) leaves every word at its normal color -
    /// no recitation session in progress, or this page's ayahs are already
    /// fully revealed for the session.
    var wordDisplayState: WordDisplayState = .unmasked

    enum WordDisplayState: Equatable {
        case unmasked
        /// `revealedIDs` empty means every word on the page is hidden
        /// (not yet reached). `highlightedIDs` (a slot can be more than one
        /// SVG glyph - see `WordSlot.svgElementIds`) are always also
        /// included in `revealedIDs`.
        case masked(revealedIDs: Set<String>, highlightedIDs: Set<String>)
    }

    /// The only tunable knob for pages 1-2 - not used by any other page.
    private enum OpenerLayout {
        static let contentPadFraction: Double = 0.35
    }

    private func jsonLiteral<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// JS call that fully applies `state` to whichever md-word-* elements
    /// need it - see `__applyWordMask`/`__clearWordMask` in the page's own
    /// script for what actually runs.
    private func wordMaskJSCall(for state: WordDisplayState) -> String {
        switch state {
        case .unmasked:
            return "__clearWordMask();"
        case .masked(let revealedIDs, let highlightedIDs):
            let revealedJSON = jsonLiteral(Array(revealedIDs))
            let highlightedJSON = jsonLiteral(Array(highlightedIDs))
            return "__applyWordMask(\(revealedJSON), \(highlightedJSON));"
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL == svgURL else {
            context.coordinator.loadedURL = svgURL
            loadFreshPage(into: webView, context: context)
            return
        }

        guard context.coordinator.appliedWordDisplayState != wordDisplayState else { return }
        context.coordinator.appliedWordDisplayState = wordDisplayState
        webView.evaluateJavaScript(wordMaskJSCall(for: wordDisplayState))
    }

    private func loadFreshPage(into webView: WKWebView, context: Context) {
        guard let svgMarkup = try? String(contentsOf: svgURL, encoding: .utf8) else { return }
        let inlinedSVG = svgMarkup.replacingOccurrences(
            of: #"^\s*<\?xml[^>]*\?>"#,
            with: "",
            options: .regularExpression
        )
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <style>
        html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden; background: transparent; }
        .source { position: absolute; visibility: hidden; width: 0; height: 0; }
        .page { display: flex; flex-direction: column; width: 100%; height: 100%; box-sizing: border-box; gap: 2px; }
        .header-row { flex: 0 0 30px; display: flex; align-items: center; justify-content: center; gap: 360px; padding: 6px 10px 0; box-sizing: border-box; }
        .header-row svg { width: 160px; height: 30px; }
        .content-row { flex: 1 1 auto; min-height: 0; position: relative; }
        #crop-content { display: block; width: 100%; height: 100%; }
        #crop-hizbMarker { position: absolute; width: 70px; height: 70px; }
        .footer-row { flex: 0 0 14px; display: flex; align-items: center; justify-content: center; padding-bottom: 6px; box-sizing: border-box; }
        .footer-row svg { width: 22px; height: 14px; }
        .crop { fill: #FFFFFF; visibility: hidden; }
        </style></head><body>
        <div class="source">\(inlinedSVG)</div>
        <div class="page">
            <div class="header-row">
                <svg class="crop" id="crop-surahNameHeader"><use href="#md-non-quranic-header-surah-name"/></svg>
                <svg class="crop" id="crop-juzNameHeader"><use href="#md-non-quranic-header-juz-name"/></svg>
            </div>
            <div class="content-row">
                <svg class="crop" id="crop-content"><use href="#md-page-inner"/></svg>
                <svg class="crop" id="crop-hizbMarker"><use href="#md-non-quranic-margin-juz-hisb"/></svg>
            </div>
            <div class="footer-row">
                <svg class="crop" id="crop-pageNumberFooter"><use href="#md-non-quranic-page-number"/></svg>
            </div>
        </div>
        <script>
        // Live-recitation word masking. Operates on the original md-word-*
        // <g> elements (inside the hidden .source div, never displayed
        // directly) - inline styles set here render through the <use
        // href="#md-page-inner"> clone in #crop-content, since a <use>
        // instance carries inline style set on its referenced element.
        // Global (not wrapped in the IIFE below) so later calls from
        // evaluateJavaScript can reach them after the initial load.
        // Placeholder line - a stand-in "notebook rule" shown under a
        // stretch of not-yet-recited words, so masked text leaves a
        // visible slot rather than a gap. One line per masked *run*
        // spanning consecutive hidden words on a line (bridging the
        // inter-word gaps so it reads as one continuous rule, not a
        // dashed one) - a run breaks wherever a revealed/highlighted word
        // interrupts it. Lines are pooled per md-line-* group and appended
        // there, so they clone into the <use href="#md-page-inner"> the
        // same way word glyphs do.
        //
        // Geometry (per-word bbox, per-line baseline y) is expensive -
        // getBBox forces layout - so it's computed once via
        // __initWordGeometry, called eagerly right after page load
        // (below) rather than lazily on the first mask call. Doing it
        // lazily meant the *first* recite tap paid for that layout pass
        // synchronously, which is what made the very first word-hide feel
        // slow to catch up.
        // Each md-line-* group interleaves md-word-* glyphs with
        // md-aya-mark-* ornaments (the circular ayah-number markers) as
        // plain siblings, in reading order. `items` merges both, sorted
        // left-to-right, so a mark - whether it sits between two hidden
        // words or right at a line's outer edge - always breaks a run
        // instead of being invisible to it. That both keeps the rule from
        // being drawn under a marker's ornament and stops a run from
        // being clipped short of the marker's true edge (a run bounded by
        // word boxes alone would fall short of a line's real start/end
        // whenever the outermost item on that side is a marker, not a
        // word - that was the "line doesn't start at the true edge" bug).
        var __wordLines = null; // [{ lineEl, items: [{kind, id?, x, right}], y, strokeWidth, pool: [line] }]
        // The page's outer text-column margins - every fully-justified
        // line's outermost ink should reach both, but per-line/per-word
        // bboxes wobble by a pixel or two depending on which glyph or
        // ornament happens to sit at the edge (kashida stretching isn't
        // pixel-identical letter to letter). Snapping each line's
        // outermost run to this shared margin - only when it's already
        // close, see __edgeSnapTolerance below - is what makes a fully
        // masked line "start under the first word" instead of stopping a
        // hair short of it.
        var __columnLeft = null;
        var __columnRight = null;

        function __initWordGeometry() {
            if (__wordLines) return;
            __wordLines = [];
            var lineEls = document.querySelectorAll('.source [id^="md-line-"]');
            for (var i = 0; i < lineEls.length; i++) {
                var lineEl = lineEls[i];
                var items = [];
                var children = lineEl.children;
                for (var c = 0; c < children.length; c++) {
                    var child = children[c];
                    if (/^md-word-/.test(child.id)) {
                        var box = child.getBBox();
                        items.push({ kind: 'word', id: child.id, x: box.x, right: box.x + box.width });
                    } else if (/^md-aya-mark-/.test(child.id)) {
                        var mbox = child.getBBox();
                        var mpad = mbox.width * 0.15;
                        items.push({ kind: 'mark', x: mbox.x - mpad, right: mbox.x + mbox.width + mpad });
                    }
                }
                items.sort(function(a, b) { return a.x - b.x; });
                var lineBox = lineEl.getBBox();
                __wordLines.push({
                    lineEl: lineEl,
                    items: items,
                    y: lineBox.y + lineBox.height + lineBox.height * 0.06,
                    strokeWidth: Math.max(lineBox.height * 0.012, 0.4),
                    pool: []
                });
                if (items.length > 0) {
                    var first = items[0].x;
                    var last = items[items.length - 1].right;
                    __columnLeft = (__columnLeft === null) ? first : Math.min(__columnLeft, first);
                    __columnRight = (__columnRight === null) ? last : Math.max(__columnRight, last);
                }
            }
        }

        function __poolSegment(line, index) {
            if (line.pool[index]) return line.pool[index];
            var seg = document.createElementNS('http://www.w3.org/2000/svg', 'line');
            seg.setAttribute('y1', line.y);
            seg.setAttribute('y2', line.y);
            seg.setAttribute('stroke', '#C7C2B8');
            seg.setAttribute('stroke-opacity', '0.2');
            seg.setAttribute('stroke-width', line.strokeWidth);
            seg.setAttribute('stroke-linecap', 'round');
            seg.style.visibility = 'hidden';
            line.lineEl.appendChild(seg);
            line.pool[index] = seg;
            return seg;
        }

        function __applyWordMask(revealedIds, highlightedIds) {
            __initWordGeometry();
            var revealedSet = {};
            for (var i = 0; i < revealedIds.length; i++) { revealedSet[revealedIds[i]] = true; }
            var highlightedSet = {};
            for (var h = 0; h < highlightedIds.length; h++) { highlightedSet[highlightedIds[h]] = true; }
            function isHidden(id) { return !revealedSet[id] && !highlightedSet[id]; }
            // Only snap to the shared column edge when the line's own
            // outermost item is already within this tolerance of it -
            // otherwise this is a genuinely short line (e.g. the last
            // line of a surah, never fully justified) and should stay as
            // measured rather than being stretched to the full margin.
            var edgeSnapTolerance = __columnLeft !== null
                ? (__columnRight - __columnLeft) * 0.15
                : 0;

            for (var li = 0; li < __wordLines.length; li++) {
                var line = __wordLines[li];
                var n = line.items.length;
                var used = 0;
                var runStart = null, runEnd = null;
                for (var k = 0; k < n; k++) {
                    var item = line.items[k];
                    if (item.kind === 'word' && isHidden(item.id)) {
                        if (runStart === null) {
                            runStart = (k === 0 && item.x - __columnLeft < edgeSnapTolerance)
                                ? __columnLeft : item.x;
                        }
                        runEnd = (k === n - 1 && __columnRight - item.right < edgeSnapTolerance)
                            ? __columnRight : item.right;
                    } else if (runStart !== null) {
                        var seg = __poolSegment(line, used++);
                        seg.setAttribute('x1', runStart);
                        seg.setAttribute('x2', runEnd);
                        seg.style.visibility = 'visible';
                        runStart = null;
                    }
                }
                if (runStart !== null) {
                    var lastSeg = __poolSegment(line, used++);
                    lastSeg.setAttribute('x1', runStart);
                    lastSeg.setAttribute('x2', runEnd);
                    lastSeg.style.visibility = 'visible';
                }
                for (var p = used; p < line.pool.length; p++) {
                    line.pool[p].style.visibility = 'hidden';
                }
            }

            var all = document.querySelectorAll('.source [id^="md-word-"]');
            for (var j = 0; j < all.length; j++) {
                var el = all[j];
                if (highlightedSet[el.id]) {
                    el.style.visibility = 'visible';
                    el.style.fill = '#FFC94A';
                } else if (revealedSet[el.id]) {
                    el.style.visibility = 'visible';
                    el.style.fill = '';
                } else {
                    el.style.visibility = 'hidden';
                }
            }
        }
        function __clearWordMask() {
            var all = document.querySelectorAll('.source [id^="md-word-"]');
            for (var i = 0; i < all.length; i++) {
                all[i].style.visibility = '';
                all[i].style.fill = '';
            }
            if (__wordLines) {
                for (var li = 0; li < __wordLines.length; li++) {
                    var pool = __wordLines[li].pool;
                    for (var p = 0; p < pool.length; p++) pool[p].style.visibility = 'hidden';
                }
            }
        }
        (function() {
            var regions = [
                ['md-non-quranic-header-surah-name', 'crop-surahNameHeader'],
                ['md-non-quranic-header-juz-name', 'crop-juzNameHeader'],
                ['md-page-inner', 'crop-content'],
                ['md-non-quranic-page-number', 'crop-pageNumberFooter']
            ];
            var contentBox = null;
            regions.forEach(function(entry) {
                var target = document.getElementById(entry[0]);
                var host = document.getElementById(entry[1]);
                if (!target || !host) return;
                var box = target.getBBox();
                var padFraction = (\(isOpenerPage) && entry[1] === 'crop-content') ? \(OpenerLayout.contentPadFraction) : 0.03;
                var pad = Math.max(box.width, box.height) * padFraction;
                var viewBox = [box.x - pad, box.y - pad, box.width + pad * 2, box.height + pad * 2];
                host.setAttribute('viewBox', viewBox.join(' '));
                host.style.visibility = 'visible';
                if (entry[1] === 'crop-content') {
                    contentBox = { x: viewBox[0], y: viewBox[1], width: viewBox[2], height: viewBox[3] };
                }
            });

            // The hizb/quarter marker sits beside whichever line it
            // falls on, not in a fixed slot like the header/footer -
            // so it's positioned as a percentage of where its own
            // ink lands within the content crop's vertical range,
            // rather than getting a CSS row of its own.
            var hizbTarget = document.getElementById('md-non-quranic-margin-juz-hisb');
            var hizbHost = document.getElementById('crop-hizbMarker');
            if (hizbTarget && hizbHost && contentBox) {
                var hbox = hizbTarget.getBBox();
                var hpad = Math.max(hbox.width, hbox.height) * 0.1;
                hizbHost.setAttribute('viewBox', [
                    hbox.x - hpad, hbox.y - hpad,
                    hbox.width + hpad * 2, hbox.height + hpad * 2
                ].join(' '));
                var percentY = (hbox.y + hbox.height / 2 - contentBox.y) / contentBox.height;
                percentY = Math.max(0, Math.min(1, percentY));
                hizbHost.style.top = 'calc(' + (percentY * 100) + '% - 10px)';
                // The marker sits in the page's outer margin, which
                // alternates sides: right edge on odd/right-hand
                // pages, left edge on even/left-hand pages.
                var pageWidth = document.querySelector('.source svg').viewBox.baseVal.width;
                if (hbox.x + hbox.width / 2 < pageWidth / 2) {
                    hizbHost.style.left = '60px';
                } else {
                    hizbHost.style.right = '60px';
                }
                hizbHost.style.visibility = 'visible';
            }
        })();
        __initWordGeometry();
        \(wordMaskJSCall(for: wordDisplayState))
        </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: svgURL.deletingLastPathComponent())
        context.coordinator.appliedWordDisplayState = wordDisplayState
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// `WKWebView.navigationDelegate` is a weak reference the web view
    /// itself doesn't retain, so this needs to live somewhere with a
    /// stronger lifetime than the delegate assignment - `Coordinator`
    /// just tracks which URL is currently loaded, to skip reloading a
    /// page whose SVG hasn't changed. The crop-positioning script now
    /// runs inline as part of the page's own HTML (see `updateNSView`)
    /// instead of being dispatched separately after `didFinish`, so it
    /// executes as part of the same initial load instead of a follow-up
    /// native-to-JS round trip - that extra round trip was the visible
    /// gap during which the page sat fully hidden.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var appliedWordDisplayState: WordDisplayState?
    }
}
