import Foundation

/// Constants shared by the engine, the built-in EQ panel and skin widgets.
enum EQ {
    static let bandCount = 10
    /// Centre frequency of each band in Hz (an octave apart).
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// Each band can be cut or boosted by this many dB.
    static let range: Float = 12

    static func label(_ band: Int) -> String {
        let f = frequencies[band]
        return f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }
}

struct EQPreset: Identifiable, Equatable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let flat = EQPreset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    static let bassBoost = EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0])
    static let trebleBoost = EQPreset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6])
    static let vocal = EQPreset(name: "Vocal", gains: [-2, -2, -1, 1, 3, 3, 2, 0, -1, -2])
    static let rock = EQPreset(name: "Rock", gains: [5, 4, 2, -1, -2, -1, 2, 4, 5, 5])
    static let dance = EQPreset(name: "Dance", gains: [6, 5, 3, 0, 0, -2, -1, 0, 3, 4])
    static let classical = EQPreset(name: "Classical", gains: [0, 0, 0, 0, 0, 0, -2, -2, -2, -4])

    static let all: [EQPreset] = [.flat, .bassBoost, .trebleBoost, .vocal, .rock, .dance, .classical]
}

/// What gets remembered between launches.
struct EQSettings: Codable {
    var enabled = true
    var gains = [Float](repeating: 0, count: EQ.bandCount)
    var balance: Float = 0

    private static let key = "eqSettings"

    static func load() -> EQSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var settings = try? JSONDecoder().decode(EQSettings.self, from: data) else {
            return EQSettings()
        }
        // Guard against a stale or corrupted save.
        if settings.gains.count != EQ.bandCount {
            settings.gains = [Float](repeating: 0, count: EQ.bandCount)
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
