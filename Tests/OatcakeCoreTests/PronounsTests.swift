import Foundation
@testable import OatcakeCore
import Testing

/// He and she in what the model writes become they/them, with the verb after a subject agreeing.
@Suite struct PronounsTests {
    @Test func heAndSheBecomeThey() {
        #expect(theyThem("- Andrea Doe said she needs the plan before her trip.\n- John Smith said he would cover for him.")
            == "- Andrea Doe said they need the plan before their trip.\n- John Smith said they would cover for them.")
        #expect(theyThem("She's keen, she's already seen it, and he was there. She isn't sure he does.")
            == "They're keen, they've already seen it, and they were there. They aren't sure they do.")
        // Object or possessive: "them" unless a noun follows (a day isn't one).
        #expect(theyThem("Jane Doe asked Andrea to send her the plan, making her unavailable on Tuesday, then thanked her.")
            == "Jane Doe asked Andrea to send them the plan, making them unavailable on Tuesday, then thanked them.")
        #expect(theyThem("Andrea will brief his own team himself; the call was his, not hers.")
            == "Andrea will brief their own team themselves; the call was theirs, not theirs.")
        #expect(theyThem("He still needs the screenshots, which she plans to send.") == "They still need the screenshots, which they plan to send.")
        // "she's" is "she has" before a past participle, regular or not.
        #expect(theyThem("She's confirmed the booking and he's reviewed it, but she's tired.")
            == "They've confirmed the booking and they've reviewed it, but they're tired.")
        // Before a number it's a possessive; "theirs" only where nothing follows.
        #expect(theyThem("He closed his 3 tasks and her 2 PRs; the rest were his.") == "They closed their 3 tasks and their 2 PRs; the rest were theirs.")
        // Words that only contain a pronoun are left alone, and so is a summary with none.
        #expect(theyThem("The theme is here, then there; she shed it.") == "The theme is here, then there; they shed it.")
        #expect(theyThem("## Launch\n- Friday.\n") == "## Launch\n- Friday.\n")
    }

    /// He is a surname too: in a participant's name, or a capitalised He next to another capitalised
    /// word, it's left alone.
    @Test func surnames() {
        #expect(theyThem("- Lily He said she would send the deck.\n- [ ] Send her the deck — Lily He — [00:00]")
            == "- Lily He said they would send the deck.\n- [ ] Send them the deck — Lily He — [00:00]")
        #expect(theyThem("He Wei agreed. He will book it.") == "He Wei agreed. They will book it.")
        #expect(theyThem("Ada He's plan was approved; she presented it.", names: ["Ada He"]) == "Ada He's plan was approved; they presented it.")
    }

    /// In another language "he" or "her" can be another word ("he comido", "komm her"): left as it is.
    @Test func englishOnly() {
        for text in ["Andrea ha detto che lei arriva venerdì con il suo piano.", "Ya he comido y he terminado el plan para el viernes.",
                     "大家早上好。请在周五之前把迁移方案发给我。"] {
            #expect(theyThem(text) == text)
        }
    }
}
