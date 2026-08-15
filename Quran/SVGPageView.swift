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

    /// The only tunable knob for pages 1-2 - not used by any other page.
    private enum OpenerLayout {
        static let contentPadFraction: Double = 0.35
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != svgURL else { return }
        context.coordinator.loadedURL = svgURL

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
        #crop-hizbMarker { position: absolute; width: 90px; height: 90px; }
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
        </script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: svgURL.deletingLastPathComponent())
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
    }
}
