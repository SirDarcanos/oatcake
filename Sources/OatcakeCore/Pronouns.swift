// He and she in what the model writes. A small model guesses someone's gender from their name and
// can get it wrong (#65: a man with a name it read as a woman's, summarised as "she"). Telling it
// someone's pronouns didn't stop it, in about 1 summary in 4, so what it writes about people is made
// gender-neutral afterwards instead: everyone is they/them.

import Foundation
import NaturalLanguage

/**
 * What the model wrote (a summary, to-dos, a draft for sharing, an answer) with he/him/his and
 * she/her/hers made they/them/their, and the verb after a subject agreeing ("she needs" → "they
 * need", "she's seen" → "they've seen"). English only: in another language "he" or "her" can be
 * another word altogether, so anything else is left as it is. `names` (the meeting's participants)
 * are left whole: He is a surname too.
 */
public func theyThem(_ text: String, names: [String] = []) -> String {
    guard !text.isEmpty, NLLanguageRecognizer.dominantLanguage(for: text) == .english else { return text }
    return text.components(separatedBy: "\n").map { theyThemLine($0, names: names) }.joined(separator: "\n")
}

/// Words that can come between a subject and its verb: "she still needs".
private let betweenSubjectAndVerb: Set = ["also", "still", "already", "then", "just", "never", "only", "really", "later", "now", "again", "first", "always", "personally", "previously"]
/// The verb after "they" in place of "he" or "she". "n't" is a word of its own here, so "doesn't" is "does" + "n't".
private let agreeing = ["is": "are", "was": "were", "has": "have", "does": "do"]
/// After "she's": "they've" before these, "they're" otherwise.
private let afterHave: Set = ["been", "got", "had", "done", "seen", "gone", "made", "sent", "finished", "completed", "said", "taken", "given", "written", "asked", "agreed", "decided"]
/// Participles that after "she's" mean "she is": "she's supposed to", "he's based in Rome".
private let stative: Set = ["supposed", "expected", "scheduled", "based", "interested", "involved", "located", "tasked", "required", "allowed",
                            "invited", "excited", "concerned", "pleased", "worried", "married", "engaged", "prepared", "committed", "set"]
/// Tagged as nouns, but not what a possessive goes with: "making her unavailable on Tuesday".
private let notNouns: Set = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight", "yesterday"]
private let gendered: Set = ["he", "him", "his", "himself", "she", "her", "hers", "herself"]

private func theyThemLine(_ line: String, names: [String]) -> String {
    guard line.range(of: #"(?i)\b(he|him|his|himself|she|her|hers|herself)\b"#, options: .regularExpression) != nil else { return line }
    let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
    tagger.string = line
    var words: [(range: Range<String.Index>, text: String, tag: NLTag?)] = []
    tagger.enumerateTags(in: line.startIndex..<line.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace]) { tag, range in
        words.append((range, String(line[range]), tag))
        return true
    }
    func word(_ i: Int) -> (range: Range<String.Index>, text: String, tag: NLTag?)? { words.indices.contains(i) ? words[i] : nil }
    func isNoun(_ i: Int) -> Bool { word(i).map { $0.tag == .noun && !notNouns.contains($0.text.lowercased()) } ?? false }
    func isNumber(_ i: Int) -> Bool { word(i).map { $0.tag == .number || $0.text.first?.isNumber == true } ?? false }
    func isCapitalised(_ i: Int) -> Bool { word(i).map { $0.text.first?.isUppercase == true && $0.text.first?.isLetter == true } ?? false }
    /// The end of a sentence or clause: nothing, or punctuation, comes next ("the call was his.").
    func endsHere(_ i: Int) -> Bool { word(i).map { $0.text.first?.isLetter != true && $0.text.first?.isNumber != true } ?? true }
    // Where a participant's name is in the line: a pronoun's spelling in there is part of the name.
    let named = names.filter { !$0.trimmed.isEmpty }.flatMap { name in
        line.ranges(of: name.trimmed)
    }
    func skippingBetween(_ i: Int) -> Int {
        var j = i
        while let between = word(j), betweenSubjectAndVerb.contains(between.text.lowercased()) { j += 1 }
        return j
    }
    var edits: [(Range<String.Index>, String)] = []
    for (i, w) in words.enumerated() {
        let lower = w.text.lowercased()
        guard gendered.contains(lower), !named.contains(where: { $0.overlaps(w.range) }) else { continue }
        // A capitalised He after another capitalised word is a name ("Lily He"), and so is a He
        // before one ("He Wei"): a subject there is followed by a word in lower case. His and Her
        // before one are possessives ("His PR", "Her Q3 numbers").
        if w.text.first?.isUppercase == true,
           isCapitalised(i - 1) || (lower == "he" || lower == "she") && isCapitalised(i + 1) { continue }
        // A possessive is followed by a noun, a number, or an adjective and then a noun: "her trip",
        // "her 2 PRs", "her new plan", but "making her unavailable on Tuesday" and "send her the plan".
        let beforeNoun = isNoun(i + 1) || isNumber(i + 1) || word(i + 1)?.tag == .adjective && isNoun(i + 2)
        var they = switch lower {
        case "he", "she": "they"
        case "him": "them"
        case "himself", "herself": "themselves"
        case "hers": "theirs"
        // "theirs" only where nothing follows it ("the call was his."), since the tagger can read a noun as a verb.
        case "his": endsHere(i + 1) ? "theirs" : "their"
        default: beforeNoun ? "their" : "them"
        }
        if w.text.first?.isUppercase == true { they = they.prefix(1).uppercased() + they.dropFirst() }
        edits.append((w.range, they))
        guard lower == "he" || lower == "she" else { continue }
        let j = skippingBetween(i + 1)
        guard let verb = word(j) else { continue }
        let v = verb.text.lowercased()
        if let plural = agreeing[v] {
            edits.append((verb.range, plural))
        } else if v == "'s" || v == "’s" {
            // "she's" is "she has" before a past participle ("she's booked the room", "she's worked
            // on it"), and "she is" otherwise, or before a participle that's mostly said with "is"
            // ("she's expected to present"). A rarer passive ("she's booked for Friday") gets "they've".
            let k = skippingBetween(j + 1)
            let after = word(k)?.text.lowercased() ?? ""
            let participle = word(k)?.tag == .verb && (after.hasSuffix("ed") || after.hasSuffix("en"))
            edits.append((verb.range, "\(v.first!)" + (afterHave.contains(after) || participle && !stative.contains(after) ? "ve" : "re")))
        } else if verb.tag == .verb, v.hasSuffix("s"), !v.hasSuffix("ss"),
                  let lemma = tagger.tag(at: verb.range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue, lemma != v {
            edits.append((verb.range, lemma))
        }
    }
    var fixed = line
    for (range, text) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { fixed.replaceSubrange(range, with: text) }
    return fixed
}
