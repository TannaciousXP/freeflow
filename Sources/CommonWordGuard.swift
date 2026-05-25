import Foundation

/// Decides whether an observed (original -> corrected) word substitution
/// is allowed to be persisted by `CorrectionLearningService`.
///
/// The guard exists to prevent the classic self-learning failure mode where
/// a user's one-off contextual edit (e.g. "Hi" -> "Hello") gets baked into
/// the model as a permanent substitution rule and starts rewriting future
/// dictations. We reject anything that smells like contextual editing, casual
/// typos in short common words, or non-vocabulary noise.
///
/// Heuristics applied (any reject -> overall reject):
///   1. Either side trims to fewer than 3 characters.
///   2. Either side, lowercased, is in the common-word set.
///   3. Either side contains only digits or punctuation.
///   4. Levenshtein distance is exactly 1 AND the longer side is <= 6 chars
///      (catches casual typos like "form"/"from").
enum CommonWordGuard {
    static func isAllowedAsLearnedCorrection(original: String, corrected: String) -> Bool {
        let a = sanitize(original)
        let b = sanitize(corrected)
        guard !a.isEmpty, !b.isEmpty else { return false }
        guard a.count >= 3, b.count >= 3 else { return false }
        if isCommonWord(a) || isCommonWord(b) { return false }
        if isDigitsOrPunctuationOnly(a) || isDigitsOrPunctuationOnly(b) { return false }

        let distance = levenshtein(a.lowercased(), b.lowercased())
        let longest = max(a.count, b.count)
        if distance == 1 && longest <= 6 { return false }

        return true
    }

    static func isCommonWord(_ word: String) -> Bool {
        commonWords.contains(word.lowercased())
    }

    // MARK: - Helpers

    private static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.trimmingCharacters(in: CharacterSet.punctuationCharacters)
        return stripped
    }

    private static func isDigitsOrPunctuationOnly(_ value: String) -> Bool {
        let allowed = CharacterSet.decimalDigits.union(.punctuationCharacters).union(.symbols)
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,        // insert
                    prev[j] + 1,            // delete
                    prev[j - 1] + cost      // substitute
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    // Top ~600 most-frequent English words plus a handful of common
    // contractions and high-frequency casual writing terms. The list is
    // deliberately conservative — too aggressive and we reject useful
    // vocabulary like brand names; too lax and we learn casual edits.
    static let commonWords: Set<String> = [
        // Articles, conjunctions, prepositions
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "yet", "for",
        "nor", "as", "at", "by", "in", "of", "on", "to", "up", "via", "with",
        "from", "into", "onto", "upon", "over", "under", "out", "off", "down",
        "near", "past", "per", "after", "before", "during", "since", "until",
        "while", "about", "above", "across", "against", "along", "among",
        "around", "behind", "below", "beneath", "beside", "between", "beyond",
        "inside", "outside", "through", "throughout", "toward", "towards",
        "without", "within",
        // Pronouns and determiners
        "i", "me", "my", "mine", "myself", "you", "your", "yours", "yourself",
        "yourselves", "he", "him", "his", "himself", "she", "her", "hers",
        "herself", "it", "its", "itself", "we", "us", "our", "ours", "ourselves",
        "they", "them", "their", "theirs", "themselves", "this", "that", "these",
        "those", "who", "whom", "whose", "which", "what", "whatever", "whoever",
        "whichever", "all", "any", "both", "each", "every", "few", "many",
        "most", "other", "some", "such", "no", "nor", "not", "only", "own",
        "same", "than", "too", "very", "one", "ones", "anyone", "everyone",
        "someone", "anybody", "everybody", "somebody", "nobody", "anything",
        "everything", "something", "nothing",
        // Common verbs and auxiliaries (all forms)
        "am", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "having",
        "do", "does", "did", "doing", "done",
        "go", "goes", "going", "went", "gone",
        "say", "says", "said", "saying",
        "get", "gets", "got", "gotten", "getting",
        "make", "makes", "made", "making",
        "know", "knows", "knew", "known", "knowing",
        "think", "thinks", "thought", "thinking",
        "take", "takes", "took", "taken", "taking",
        "see", "sees", "saw", "seen", "seeing",
        "come", "comes", "came", "coming",
        "want", "wants", "wanted", "wanting",
        "look", "looks", "looked", "looking",
        "use", "uses", "used", "using",
        "find", "finds", "found", "finding",
        "give", "gives", "gave", "given", "giving",
        "tell", "tells", "told", "telling",
        "work", "works", "worked", "working",
        "call", "calls", "called", "calling",
        "try", "tries", "tried", "trying",
        "ask", "asks", "asked", "asking",
        "need", "needs", "needed", "needing",
        "feel", "feels", "felt", "feeling",
        "become", "becomes", "became", "becoming",
        "leave", "leaves", "left", "leaving",
        "put", "puts", "putting",
        "mean", "means", "meant", "meaning",
        "keep", "keeps", "kept", "keeping",
        "let", "lets", "letting",
        "begin", "begins", "began", "begun", "beginning",
        "seem", "seems", "seemed", "seeming",
        "help", "helps", "helped", "helping",
        "talk", "talks", "talked", "talking",
        "turn", "turns", "turned", "turning",
        "start", "starts", "started", "starting",
        "show", "shows", "showed", "shown", "showing",
        "hear", "hears", "heard", "hearing",
        "play", "plays", "played", "playing",
        "run", "runs", "ran", "running",
        "move", "moves", "moved", "moving",
        "live", "lives", "lived", "living",
        "believe", "believes", "believed", "believing",
        "bring", "brings", "brought", "bringing",
        "happen", "happens", "happened", "happening",
        "write", "writes", "wrote", "written", "writing",
        "sit", "sits", "sat", "sitting",
        "stand", "stands", "stood", "standing",
        "lose", "loses", "lost", "losing",
        "pay", "pays", "paid", "paying",
        "meet", "meets", "met", "meeting",
        "include", "includes", "included", "including",
        "continue", "continues", "continued", "continuing",
        "set", "sets", "setting",
        "learn", "learns", "learned", "learnt", "learning",
        "change", "changes", "changed", "changing",
        "lead", "leads", "led", "leading",
        "understand", "understands", "understood", "understanding",
        "watch", "watches", "watched", "watching",
        "follow", "follows", "followed", "following",
        "stop", "stops", "stopped", "stopping",
        "create", "creates", "created", "creating",
        "speak", "speaks", "spoke", "spoken", "speaking",
        "read", "reads", "reading",
        "spend", "spends", "spent", "spending",
        "grow", "grows", "grew", "grown", "growing",
        "open", "opens", "opened", "opening",
        "walk", "walks", "walked", "walking",
        "win", "wins", "won", "winning",
        "offer", "offers", "offered", "offering",
        "remember", "remembers", "remembered", "remembering",
        "love", "loves", "loved", "loving",
        "consider", "considers", "considered", "considering",
        "appear", "appears", "appeared", "appearing",
        "buy", "buys", "bought", "buying",
        "wait", "waits", "waited", "waiting",
        "serve", "serves", "served", "serving",
        "die", "dies", "died", "dying",
        "send", "sends", "sent", "sending",
        "expect", "expects", "expected", "expecting",
        "build", "builds", "built", "building",
        "stay", "stays", "stayed", "staying",
        "fall", "falls", "fell", "fallen", "falling",
        "cut", "cuts", "cutting",
        "reach", "reaches", "reached", "reaching",
        "kill", "kills", "killed", "killing",
        "remain", "remains", "remained", "remaining",
        // Modal verbs
        "can", "cannot", "could", "couldn", "couldnt",
        "may", "might",
        "shall", "should", "shouldn", "shouldnt",
        "will", "would", "wouldn", "wouldnt",
        "must", "ought",
        // Contractions (apostrophes stripped during sanitize)
        "im", "ive", "ill", "id",
        "youre", "youve", "youll", "youd",
        "hes", "shes", "its",
        "were", "weve", "well", "wed",
        "theyre", "theyve", "theyll", "theyd",
        "dont", "doesnt", "didnt",
        "isnt", "arent", "wasnt", "werent",
        "havent", "hasnt", "hadnt",
        "wont", "wouldnt", "shouldnt", "couldnt", "mustnt", "mightnt",
        "lets", "thats", "whats", "wheres", "whens", "whys", "hows",
        // Common adjectives / adverbs
        "good", "great", "best", "better", "bad", "worse", "worst",
        "new", "old", "young", "first", "last", "next", "previous",
        "long", "short", "high", "low", "big", "small", "large", "little",
        "right", "wrong", "true", "false", "real", "sure", "free",
        "easy", "hard", "soft", "fast", "slow", "quick",
        "early", "late", "now", "later", "soon", "again", "still", "yet",
        "always", "never", "often", "sometimes", "usually", "rarely",
        "here", "there", "where", "everywhere", "anywhere", "nowhere",
        "today", "yesterday", "tomorrow", "tonight",
        "yes", "no", "maybe", "perhaps", "okay", "ok",
        "just", "even", "also", "rather", "quite", "almost", "enough",
        "much", "more", "less", "least", "lot", "lots",
        "really", "actually", "basically", "literally", "honestly",
        "thanks", "thank", "please", "sorry", "hello", "hey", "hi",
        // Common short nouns
        "time", "year", "day", "week", "month", "hour", "minute", "second",
        "way", "thing", "things", "person", "people", "man", "woman", "men",
        "women", "kid", "kids", "child", "children", "guy", "guys",
        "world", "life", "home", "house", "place", "room", "office", "team",
        "name", "names", "word", "words", "story", "case", "point", "fact",
        "part", "side", "end", "kind", "type", "form", "level", "number",
        "group", "company", "business", "school", "state", "country", "city",
        "area", "side", "line", "side", "back", "front", "side", "top", "bottom",
        "head", "hand", "foot", "eye", "face", "ear", "arm", "leg",
        "car", "phone", "money", "love", "hope", "help", "idea", "ideas",
        "issue", "issues", "problem", "problems", "question", "questions",
        "answer", "answers", "reason", "reasons", "result", "results",
        "email", "emails", "message", "messages", "text", "texts",
        "file", "files", "code", "data", "info", "information", "note", "notes",
        // Common short / casual fillers
        "uh", "um", "uhh", "ehh", "huh", "wow",
        "yeah", "yep", "yup", "nope", "nah",
        "oh", "ohh", "aha", "ahh"
    ]
}
