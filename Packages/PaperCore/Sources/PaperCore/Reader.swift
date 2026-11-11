import Foundation

/// Reading a long paper a piece at a time: the HTML is cut at its section headings, and only the section on screen is
/// rendered. Figures become pqasset:// links the app serves (and caches) only when the reader scrolls to them.
public enum ReaderPaper {
    public struct Section: Identifiable, Equatable, Sendable {
        public var id: Int
        public var title: String
        public var level: Int
        public var html: String
        public var figures: Int
        public var equations: Int
    }

    /// Splits at <h2> (sections) and keeps <h3> inside them. Text before the first <h2> (title, authors, abstract
    /// heading level 1) becomes the first section.
    public static func sections(_ html: String) -> [Section] {
        guard let re = try? NSRegularExpression(pattern: "<h2[^>]*>(.*?)</h2>", options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        let matches = re.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var out: [Section] = []
        func add(_ title: String, _ range: NSRange) {
            let body = ns.substring(with: range)
            guard !ManuscriptHTML.plainText(body).isEmpty || body.contains("<img") else { return }
            out.append(Section(id: out.count, title: title, level: 1, html: body,
                               figures: ManuscriptHTML.occurrences(of: "<img", in: body).count,
                               equations: ManuscriptHTML.occurrences(of: "data-equation=", in: body).count))
        }
        let firstStart = matches.first?.range.location ?? ns.length
        if firstStart > 0 {
            let lead = ns.substring(with: NSRange(location: 0, length: firstStart))
            let title = PaperImport.title(html: lead) ?? "Opening"
            add(title, NSRange(location: 0, length: firstStart))
        }
        for (i, m) in matches.enumerated() {
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let title = ManuscriptHTML.plainText(ns.substring(with: m.range(at: 1)))
            add(title.isEmpty ? "Section \(i + 1)" : title, NSRange(location: m.range.location, length: end - m.range.location))
        }
        return out
    }

    /// One section as a page: equations typeset by KaTeX in the page, figures loaded lazily through pqasset://.
    public static func page(_ section: Section, dark: Bool) -> String {
        var body = section.html.replacingOccurrences(of: #"src="asset://([^"]+)""#, with: #"src="pqasset://$1" loading="lazy""#,
                                                     options: .regularExpression)
        body = body.replacingOccurrences(of: "<img ", with: "<img onerror=\"this.classList.add('missing')\" ")
        let fg = dark ? "#e9eef5" : "#17202a", bg = dark ? "#0e141b" : "#fffdf8", muted = dark ? "#9dacbd" : "#667587"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.css">
        <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.js"></script>
        <style>
        body{margin:0;padding:18px 16px 60px;background:\(bg);color:\(fg);font:17px/1.6 -apple-system,"New York",Georgia,serif;}
        h1{font-size:24px;line-height:1.2} h2{font-size:21px;line-height:1.25} h3{font-size:18px}
        img{max-width:100%;height:auto;display:block;margin:14px auto;min-height:120px;background:\(dark ? "#18222d" : "#eef1f4");border-radius:6px}
        img.missing{min-height:40px}
        .eq{display:flex;align-items:center;gap:8px;margin:14px 0;overflow-x:auto}
        .eq .m{flex:1;text-align:center} .eq .n{color:\(muted);font-size:15px}
        table{border-collapse:collapse;display:block;overflow-x:auto} td,th{border-bottom:1px solid \(muted);padding:4px 8px}
        mark{border-radius:3px;padding:0 2px} .comment-anchor{border-bottom:2px solid #c9771a}
        </style></head><body>\(body)
        <script>
        function typeset(){
          if(!window.katex){return setTimeout(typeset,60);}
          document.querySelectorAll('[data-equation]').forEach(function(el){
            var tex=el.getAttribute('data-latex')||el.textContent,n=el.getAttribute('data-number');
            var w=document.createElement('div');w.className='eq';var m=document.createElement('div');m.className='m';w.appendChild(m);
            try{katex.render(tex,m,{displayMode:true,throwOnError:false});}catch(e){m.textContent=tex;}
            if(n){var s=document.createElement('span');s.className='n';s.textContent='('+n+')';w.appendChild(s);}
            el.replaceWith(w);});
          document.querySelectorAll('[data-inline-equation]').forEach(function(el){
            var tex=el.getAttribute('data-latex')||el.textContent;try{katex.render(tex,el,{throwOnError:false});}catch(e){}});
        }
        typeset();
        </script></body></html>
        """
    }
}
