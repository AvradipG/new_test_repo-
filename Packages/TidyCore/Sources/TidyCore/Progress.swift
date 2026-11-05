import Foundation

/// Gentle progress counting for the home screen.
public enum Streak {
    /// Consecutive days (ending today, or yesterday if nothing is done yet today) with at least one finished step.
    public static func days(completions: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(completions.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = y
        }
        var n = 0
        while days.contains(cursor) {
            n += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return n
    }

    public static func doneToday(completions: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        completions.filter { calendar.isDate($0, inSameDayAs: now) }.count
    }
}

public enum Cheers {
    public static let all = [
        "Nice. Next one?",
        "That's one less thing.",
        "Look at you go.",
        "Done is better than perfect.",
        "Tiny wins add up.",
        "Your future self says thanks.",
        "Momentum! Keep riding it.",
    ]
}

/// Pixel rectangle used to cut an item's thumbnail out of its photo.
public enum CropMath {
    /// Pads the box by `pad` of its size on each side, keeps it inside the image, and makes it square-ish
    /// so small objects stay recognisable. Returns (x, y, width, height) in pixels.
    public static func rect(for box: PhotoBox, imageWidth: Double, imageHeight: Double, pad: Double = 0.15)
        -> (x: Double, y: Double, width: Double, height: Double)
    {
        var w = box.w * imageWidth * (1 + 2 * pad)
        var h = box.h * imageHeight * (1 + 2 * pad)
        let side = max(w, h, 24)
        w = min(side, imageWidth)
        h = min(side, imageHeight)
        let cx = (box.x + box.w / 2) * imageWidth
        let cy = (box.y + box.h / 2) * imageHeight
        let x = min(max(0, cx - w / 2), imageWidth - w)
        let y = min(max(0, cy - h / 2), imageHeight - h)
        return (x, y, w, h)
    }
}

/// Builds the compact one-line-per-item inventory text used for "Where is my...?" questions.
public enum InventoryText {
    public struct Line: Sendable {
        public var ref: String
        public var name: String
        public var category: String
        public var tags: [String]
        public var place: String
        public var room: String
        public var spot: String?
        public var notPutAway: Bool

        public init(ref: String, name: String, category: String, tags: [String], place: String, room: String,
                    spot: String?, notPutAway: Bool) {
            self.ref = ref
            self.name = name
            self.category = category
            self.tags = tags
            self.place = place
            self.room = room
            self.spot = spot
            self.notPutAway = notPutAway
        }
    }

    public static func render(_ lines: [Line]) -> String {
        lines.map { l in
            "\(l.ref) | \(l.name) | \(l.category) | \(l.tags.joined(separator: ",")) | \(l.place) > \(l.room) > \(l.spot ?? "loose")"
                + (l.notPutAway ? " (not put away yet)" : "")
        }.joined(separator: "\n")
    }
}
