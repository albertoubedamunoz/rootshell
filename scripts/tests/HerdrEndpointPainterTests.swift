import Foundation

@main
struct HerdrEndpointPainterTests {
    typealias Surface = HerdrEndpointSurface

    static func fixture(_ symbols: [String]) -> (Surface.Frame, Surface.Pane) {
        let cells = symbols.map {
            Surface.Cell(symbol: $0, foreground: 0, background: 0, modifiers: 0, skip: false, hyperlink: nil)
        }
        let rect = Surface.Rect(x: 0, y: 0, width: cells.count, height: 1)
        let pane = Surface.Pane(id: "p", contentRevision: 1, rect: rect, inner: rect,
            scrollbar: nil, scroll: nil, focused: true, mouseReporting: false, pixelMouse: false,
            alternateScreen: false, pixelWidth: 0, pixelHeight: 0)
        let frame = Surface.Frame(boot: "test", projection: 1, revision: 1,
            grid: .init(cells: cells, width: cells.count, height: 1, cursor: nil, hyperlinks: [], graphics: Data()),
            panes: [pane], splits: [], popup: nil, scene: .init(assets: [:], placements: [], retained: []))
        return (frame, pane)
    }

    static func paint(_ symbols: [String], using painter: inout HerdrEndpointPainter) -> String {
        let (frame, pane) = fixture(symbols)
        return painter.render(frame: frame, pane: pane, selection: nil, selectionColors: nil)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else {
            print("FAIL: \(message)")
            exit(1)
        }
        print("PASS: \(message)")
    }

    static func main() {
        var painter = HerdrEndpointPainter()
        let chinese = ["中", " ", "文", " ", "A", "1"]
        let full = paint(chinese, using: &painter)
        check(full.contains("中") && full.contains("文") && full.contains("A1")
            && !full.contains("\u{1b}[1;2H") && !full.contains("\u{1b}[1;4H"),
            "full redraw preserves Chinese alongside ASCII")
        check(paint(chinese, using: &painter).isEmpty, "unchanged frames produce no output")

        let narrow = paint(["x", " ", "文", " ", "A", "1"], using: &painter)
        check(narrow.contains("x "), "narrowing a glyph restores its unchanged trailing space")
        let wide = paint(chinese, using: &painter)
        check(wide.contains("中") && !wide.contains("\u{1b}[1;2H"),
            "incremental redraw skips a newly covered cell")

        painter.reset()
        let emoji = paint(["👩‍💻", " ", "Z"], using: &painter)
        check(emoji.contains("👩‍💻") && emoji.contains("\u{1b}[1;3HZ")
            && !emoji.contains("\u{1b}[1;2H"), "wide emoji keeps its joiner and trailing cell")

        painter.reset()
        let combining = paint(["e\u{301}", "Z"], using: &painter)
        check(combining.contains("e\u{301}") && combining.contains("\u{1b}[1;2HZ"),
            "combining characters do not hide the following cell")

        painter.reset()
        let edge = paint(["A", "中", " "], using: &painter)
        check(edge.contains("中") && !edge.contains("\u{1b}[1;3H"),
            "wide glyph at the right edge keeps its trailing cell")

        painter.reset()
        let (frame, pane) = fixture(["中", " ", "Z"])
        _ = painter.render(frame: frame, pane: pane, selection: nil, selectionColors: nil)
        let selection = HerdrEndpointSelection(anchor: .init(row: 0, column: 0),
            cursor: .init(row: 0, column: 1), dragging: false, visible: true)
        let selected = String(decoding: painter.render(frame: frame, pane: pane,
            selection: selection, selectionColors: nil)!, as: UTF8.self)
        check(selected.contains("中") && !selected.contains("\u{1b}[1;2H"),
            "selection redraw preserves wide glyphs")
    }
}
