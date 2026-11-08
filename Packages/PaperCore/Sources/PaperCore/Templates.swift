import Foundation

/// Starting trees. Template ids are fixed strings, so two devices that create the same paper merge cleanly and
/// Claude can name entries by id.
public enum Templates {
    public static let greenChristoffelID = "green-christoffel-writing"
    public static let greenChristoffelURL = "https://manuscript-studio-181489801873.web.app/write/?paper=green-christoffel-writing"

    // From the manuscript's object registry (equations, figures and tables in paper order).
    static let equations: [(String, String)] = [
        ("eq:complex-vector", "Complex polarization vector"), ("eq:harmonic", "Harmonic convention"),
        ("eq:complex-stiffness", "Complex stiffness"), ("eq:wave-equation", "Forced plane-wave equation"),
        ("eq:christoffel-operator", "Density-normalized Green–Christoffel operator"),
        ("eq:dynamic-operator", "Physical dynamic operator and Green function"),
        ("eq:christoffel", "Green–Christoffel eigenproblem"), ("eq:wavenumber", "Modal wavenumber"),
        ("eq:resolvent", "Spectral resolvent"), ("eq:green-resolvent", "Green function ↔ resolvent relation"),
        ("eq:response", "Resolvent response"), ("eq:biorthogonal", "Biorthogonal modal expansion"),
        ("eq:ellipse", "Real field over one cycle"), ("eq:bivector-spin", "Polarization bivector and spin"),
        ("eq:tensor-spin", "Tensor–spin descriptor pair"), ("eq:coherency", "Normalized coherency matrix"),
        ("eq:coherency-split", "Coherency = tensor + spin"), ("eq:identities", "Q–s identities"),
        ("eq:invariance", "Phase/amplitude invariance"), ("eq:q-eigenvalues", "Eigenvalues of Q"),
        ("eq:spin-semiaxes", "Spin magnitude from semi-axes"), ("eq:spin-direction", "Normalized spin direction"),
        ("eq:spin-conditioning", "Conditioning of the plane normal"), ("eq:modal-descriptors", "Modal descriptors"),
        ("eq:line-projector", "Modal line projector"), ("eq:riesz", "Shear Riesz projector (contour form)"),
        ("eq:riesz-biorthogonal", "Shear Riesz projector (biorthogonal form)"),
        ("eq:response-descriptors", "Response descriptors"), ("eq:single-residue", "Isolated simple-mode dominance"),
        ("eq:residue-limit", "Response → modal limit"), ("eq:direction", "Sweep direction"),
        ("eq:ti-christoffel", "TI Green–Christoffel matrix"), ("eq:perturbation", "Complex-symmetric perturbation"),
        ("eq:perturbed-response", "Perturbed response"), ("eq:metric-vector", "Eigenvector step metric"),
        ("eq:metric-tensor", "Projector / tensor step metric"), ("eq:metric-normal", "Plane-normal step angle"),
        ("eq:spin-gate", "Uncertainty-based spin gate"), ("eq:hierarchy", "Benchmark stability hierarchy"),
    ]

    static let figures: [(String, String)] = [
        ("fig:limit", "Linear-to-circular limit"), ("fig:gauge", "Gauge-invariance test"), ("fig:spectrum", "TI spectrum"),
        ("fig:tracking", "Tracking comparison, one realization"), ("fig:ensemble", "Ensemble stability"),
        ("fig:sphere", "Spin-gated response-plane normals"), ("fig:source", "Source and spectral dependence"),
    ]

    static let tables: [(String, String)] = [
        ("tab:objects", "Modal, subspace and source-conditioned objects"),
        ("tab:variation", "Pooled one-step variation (160 realizations)"),
    ]

    struct Section {
        let id: String
        let title: String
        var eqRange: ClosedRange<Int>? = nil
        var figures: [String] = []
        var tables: [String] = []
        var text: [String] = ["Draft complete", "Science checked", "Language polished"]
    }

    static let sections: [Section] = [
        Section(id: "sec-abstract", title: "Abstract",
                text: ["Draft complete", "Claims match the results", "Within the word limit", "Keywords final"]),
        Section(id: "sec-intro", title: "1. Introduction"),
        Section(id: "sec-formulation", title: "2. Complex Green–Christoffel and resolvent formulation", eqRange: 1...12),
        Section(id: "sec-descriptors", title: "3. Phase-invariant polarization descriptors", eqRange: 13...23,
                figures: ["fig:limit", "fig:gauge"]),
        Section(id: "sec-observables", title: "4. Modal, subspace, and forced-response observables", eqRange: 24...30,
                tables: ["tab:objects"]),
        Section(id: "sec-benchmark", title: "5. TI viscoelastic shear-degeneracy benchmark", eqRange: 31...37,
                figures: ["fig:spectrum"]),
        Section(id: "sec-results", title: "6. Results", eqRange: 38...39,
                figures: ["fig:tracking", "fig:ensemble", "fig:sphere"], tables: ["tab:variation"]),
        Section(id: "sec-discussion", title: "7. Discussion", figures: ["fig:source"]),
        Section(id: "sec-conclusions", title: "8. Conclusions"),
        Section(id: "sec-data", title: "Data and code availability", text: ["Statement written", "Package complete (code, arrays, seed)"]),
        Section(id: "sec-declarations", title: "Declarations", text: ["Statement written"]),
        Section(id: "sec-references", title: "References",
                text: ["Every entry complete", "DOIs resolve", "Journal reference style applied"]),
    ]

    /// Open review flags from the manuscript viewer's Status tab, filed under the section they concern.
    static let flags: [(section: String, id: String, title: String, detail: String, done: Bool)] = [
        ("sec-formulation", "st-sign", "Settle the sign convention (Eq. 2 vs Eqs. 3 and 8)",
         "Eq. (2) uses e^{i(ωt−k·x)}, but Eq. (3), the benchmark stiffnesses (Im C < 0) and Eq. (8) (Im k_m > 0 attenuating) correspond to e^{i(k·x−ωt)}. Confirm one convention before submission.", false),
        ("sec-observables", "st-midrule", "PDF export: literal “midrule” in Tables 1 and 2",
         "booktabs \\midrule is not rendered in the PDF export.", false),
        ("sec-descriptors", "st-norm", "PDF export: ‖s‖ prints as “—s—”",
         "Seen in running text in Sections 3, 4, 6 and 7.", false),
        ("sec-results", "st-trunc", "Table 2, row 2 text truncated in the PDF",
         "“…non-unique at degenerac”", false),
        ("sec-intro", "st-cites", "Make the \\cite markers appear in the text",
         "The bibliography lists [1]–[23] but no in-text citation markers appear in the PDF body.", false),
        ("sec-references", "st-doi", "Vavryčuk (2007) DOI corrected",
         "Corrected to 10.1190/1.2768402 (Crossref-verified).", true),
        ("sec-data", "st-data", "Permanent public repository and DOI for the code package", "", false),
        ("sec-declarations", "st-authors", "Confirm author list, acknowledgements, funding, competing interests", "", false),
        ("sec-discussion", "st-tiltspin", "Decide where the tilt–spin generator split goes (Paper 1 or Paper 2)",
         "X = X⊥ + X∥; only plane tilt is visible on S². Paper 1 currently defers transport generators to a separate paper.", false),
    ]

    public static func greenChristoffel(now: Date = Date()) -> Paper {
        var p = Paper(id: greenChristoffelID,
                      title: "Green–Christoffel polarization",
                      subtitle: "Phase-invariant Green–Christoffel polarization near shear-wave degeneracy · Wave Motion",
                      manuscriptURL: greenChristoffelURL, now: now)
        var order = 0.0
        func add(_ id: String, _ parent: String?, _ title: String, detail: String = "", anchor: String? = nil,
                 status: Status = .todo) {
            order += 1
            p.nodes.append(Node(id: id, parentID: parent, title: title, detail: detail, status: status, order: order,
                                anchor: anchor, updatedAt: now, completedAt: status == .done ? now : nil))
        }
        for s in sections {
            let sid = "gc/\(s.id)"
            add(sid, nil, s.title, anchor: s.id)
            let textID = "\(sid)/text"
            add(textID, sid, "Text")
            for (k, t) in s.text.enumerated() { add("\(textID)/\(k + 1)", textID, t) }
            if let r = s.eqRange {
                let gid = "\(sid)/equations"
                add(gid, sid, "Equations (\(r.lowerBound)–\(r.upperBound))")
                for n in r {
                    let (eid, preview) = equations[n - 1]
                    add("gc/\(eid)", gid, "Eq. (\(n)) · \(preview)", detail: eid, anchor: eid)
                }
            }
            if !s.figures.isEmpty {
                let gid = "\(sid)/figures"
                add(gid, sid, "Figures")
                for fid in s.figures {
                    let n = (figures.firstIndex { $0.0 == fid } ?? 0) + 1
                    let preview = figures.first { $0.0 == fid }?.1 ?? fid
                    add("gc/\(fid)", gid, "Fig. \(n) · \(preview)", detail: "Final artwork, caption and resolution", anchor: fid)
                }
            }
            if !s.tables.isEmpty {
                let gid = "\(sid)/tables"
                add(gid, sid, "Tables")
                for tid in s.tables {
                    let n = (tables.firstIndex { $0.0 == tid } ?? 0) + 1
                    let preview = tables.first { $0.0 == tid }?.1 ?? tid
                    add("gc/\(tid)", gid, "Table \(n) · \(preview)", detail: tid, anchor: tid)
                }
            }
            let mine = flags.filter { $0.section == s.id }
            if !mine.isEmpty {
                let gid = "\(sid)/review"
                add(gid, sid, "Review flags")
                for f in mine { add("gc/\(f.id)", gid, f.title, detail: f.detail, status: f.done ? .done : .todo) }
            }
        }
        let sub = "gc/submission"
        add(sub, nil, "Submission")
        for (k, t) in ["Formatted to Wave Motion guidelines", "Final PDF read end to end", "Cover letter",
                       "Suggested reviewers", "Highlights and graphical abstract", "Submitted"].enumerated() {
            add("\(sub)/\(k + 1)", sub, t)
        }
        return p
    }

    /// A new research article: the usual sections, each with outline → draft → revise → polish.
    public static func article(title: String, id: String = "p-" + UUID().uuidString.prefix(8).lowercased(),
                               manuscriptURL: String? = nil, now: Date = Date()) -> Paper {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = Paper(id: id, title: clean.isEmpty ? "New paper" : clean, manuscriptURL: manuscriptURL, now: now)
        var order = 0.0
        let steps = ["Outline", "First draft", "Revised", "Polished"]
        for (k, s) in ["Abstract", "Introduction", "Methods", "Results", "Discussion", "Conclusions",
                       "Figures and tables", "References", "Submission"].enumerated() {
            let sid = "\(id)/s\(k + 1)"
            order += 1
            p.nodes.append(Node(id: sid, parentID: nil, title: s, order: order, updatedAt: now))
            let items: [String]
            switch s {
            case "Figures and tables": items = ["List every figure and table", "Final artwork", "Captions"]
            case "References": items = ["Every entry complete", "DOIs resolve", "Journal style applied"]
            case "Submission": items = ["Journal chosen", "Formatted to guidelines", "Cover letter", "Submitted"]
            default: items = steps
            }
            for (j, t) in items.enumerated() {
                order += 1
                p.nodes.append(Node(id: "\(sid)/\(j + 1)", parentID: sid, title: t, order: order, updatedAt: now))
            }
        }
        return p
    }
}
