import Foundation

/// Phonetic skeleton encoder — a tight subset of Double Metaphone (Philips 1990).
/// Used to detect phonetically near-matching vocabulary terms in transcriptions.
///
/// Skipped / simplified vs the full algorithm:
/// - Only one code emitted (primary). Secondary alternate code omitted.
/// - W is dropped in all positions (semi-vowel handling not implemented).
/// - H voicing simplified: emit H only when immediately before a vowel.
/// - Slavic and Germanic initial-pattern alternatives omitted.
/// - Positional SC sensitivity (SC before e/i → S only) not implemented.
enum PhoneticSkeleton {

    /// Returns a phonetic key for `word`. Case-insensitive; non-alpha stripped.
    /// Empty or all-non-alpha input → empty key.
    static func key(_ word: String) -> String {
        let s = word.lowercased().filter { $0.isLetter }
        guard !s.isEmpty else { return "" }
        return deduplicate(encode(Array(s)))
    }

    /// True when `a` and `b` share the same non-empty phonetic key.
    static func matches(_ a: String, _ b: String) -> Bool {
        let ka = key(a)
        return !ka.isEmpty && ka == key(b)
    }

    // MARK: - Private

    private static func isVowel(_ c: Character) -> Bool {
        "aeiou".contains(c)
    }

    private static func deduplicate(_ s: String) -> String {
        var out = ""
        for ch in s { if out.last != ch { out.append(ch) } }
        return out
    }

    private static func encode(_ ch: [Character]) -> String {
        let n = ch.count
        var out = ""
        var i = 0

        // Skip leading silent-letter pairs: KN, GN, AE, WR.
        if n >= 2 {
            switch (ch[0], ch[1]) {
            case ("k", "n"), ("g", "n"), ("a", "e"), ("w", "r"): i = 1
            default: break
            }
        }

        // Initial vowel → anchor "A".
        if i == 0 && isVowel(ch[0]) { out = "A"; i = 1 }

        while i < n {
            let c  = ch[i]
            let n1: Character? = i + 1 < n ? ch[i + 1] : nil
            let n2: Character? = i + 2 < n ? ch[i + 2] : nil

            switch c {
            case "a", "e", "i", "o", "u", "y":
                i += 1

            case "b":
                // Final -MB: silent (lamb, climb, thumb).
                if i == n - 1, i > 0, ch[i - 1] == "m" { i += 1 }
                else { out += "P"; i += 1 }

            case "c":
                if n1 == "h"                           { out += "X"; i += 2 }   // CH → X
                else if n1 == "k"                      { out += "K"; i += 2 }   // CK → K
                else if let v = n1, "iey".contains(v)  { out += "S"; i += 1 }   // soft C
                else                                   { out += "K"; i += 1 }

            case "d":
                // DGE / DGI → J (edge, digit).
                if n1 == "g", let v = n2, "iey".contains(v) { out += "J"; i += 3 }
                else                                         { out += "T"; i += 1 }

            case "f":
                out += "F"; i += 1

            case "g":
                if n1 == "h"                           { i += 2 }              // GH → silent
                else if n1 == "n"                      { i += 1 }              // GN: silent G
                else if let v = n1, "iey".contains(v)  { out += "J"; i += 1 }  // soft G
                else                                   { out += "K"; i += 1 }

            case "h":
                if let v = n1, isVowel(v) { out += "H" }
                i += 1

            case "j":
                out += "J"; i += 1

            case "k":
                out += "K"; i += 1

            case "l":
                out += "L"; i += 1

            case "m":
                out += "M"; i += 1

            case "n":
                out += "N"; i += 1

            case "p":
                if n1 == "h" { out += "F"; i += 2 }                            // PH → F
                else         { out += "P"; i += 1 }

            case "q":
                out += "K"; i += 1

            case "r":
                out += "R"; i += 1

            case "s":
                if n1 == "h"                              { out += "X";  i += 2 } // SH → X
                else if n1 == "c" && n2 == "h"            { out += "SK"; i += 3 } // SCH
                else if n1 == "i", let v = n2,
                        "ao".contains(v)                  { out += "X";  i += 1 } // SIA/SIO
                else                                      { out += "S";  i += 1 }

            case "t":
                if n1 == "h"                              { out += "0";  i += 2 } // TH → 0
                else if n1 == "c" && n2 == "h"            { out += "X";  i += 3 } // TCH
                else if n1 == "i", let v = n2,
                        "ao".contains(v)                  { out += "X";  i += 1 } // TION/TIAN
                else                                      { out += "T";  i += 1 }

            case "v":
                out += "F"; i += 1                                              // V → F (devoiced)

            case "w":
                i += 1                                                          // W: semi-vowel, dropped

            case "x":
                out += "KS"; i += 1

            case "z":
                out += "S"; i += 1

            default:
                i += 1
            }
        }

        return out
    }
}
