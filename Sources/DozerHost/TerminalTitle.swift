import Foundation

// 599 (594.B4, owner ruled "as recommended": no reserved rows — a title and a transient menu instead):
// the title `doz attach` gives the terminal, and `doz ui` gives a terminal's tab, from `ui.terminal_title`
// — a closed set of variables (`SettingType.titleVariables`), checked when the setting is written.

public enum TerminalTitle {
    /// `{sandbox} · {session} · {time}` → `hello · claude · 14:05`. An unknown variable is left as
    /// written (the setting refuses one; a file edited by hand is only warned about). Control characters
    /// never reach the result.
    public static func render(_ template: String, sandbox: String, session: String, image: String?, phase: String?,
                              now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let values: [String: String] = [
            "sandbox": sandbox, "session": session, "image": image ?? "",
            "time": time(now, timeZone: timeZone), "phase": phase.map(phaseLabel) ?? "",
        ]
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { out += rest[open...]; rest = ""; break }
            let name = String(rest[rest.index(after: open)..<close])
            out += values[name] ?? "{\(name)}"
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return String(String.UnicodeScalarView(out.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !(0x80...0x9F).contains($0.value) }).prefix(200))
    }

    /// This Mac's time, `HH:MM` (24-hour).
    public static func time(_ now: Date, timeZone: TimeZone = .current) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        let d = c.dateComponents([.hour, .minute], from: now)
        return String(format: "%02d:%02d", d.hour ?? 0, d.minute ?? 0)
    }

    static func phaseLabel(_ raw: String) -> String {
        switch raw {
        case "asleep": "asleep"
        case "hibernated": "hibernated"
        case "paused": "paused"
        case "booting": "starting"
        case "off": "shut down"
        default: raw
        }
    }

    /// Seconds from `now` to the start of the next minute (the title's refresh).
    public static func secondsToNextMinute(_ now: Date = Date()) -> Double {
        let s = now.timeIntervalSince1970
        return 60 - s.truncatingRemainder(dividingBy: 60) + 0.05
    }
}
