import Foundation
@testable import OatcakeCore
import Testing

@Suite struct ShareHTMLTests {
    @Test func markdownBecomesHTML() {
        let html = markdownHTML("""
            ## Offsite
            - **Alex** books the café <b>now</b>
              - by *Friday*
            - See [the plan](https://example.com/plan?a=1&b=2), not [this](javascript:alert(1)) or [that](Team/2026-11-09%20Weekly%20sync)

            1. One
            2. Two

            > Quoted & kept

            ```
            <script>alert("x")</script>
            ```

            | Topic | Owner |
            |---|---|
            | Pricing | Sam |

            ---
            Last ~~word~~ `code`
            """)
        #expect(html.contains("<h3>Offsite</h3>"))
        #expect(html.contains("<ul><li><strong>Alex</strong> books the café &lt;b&gt;now&lt;/b&gt;<ul><li>by <em>Friday</em></li></ul></li><li>See <a href=\"https://example.com/plan?a=1&amp;b=2\" rel=\"noopener noreferrer\">the plan</a>, not this or that</li></ul>"))
        #expect(html.contains("<ol><li>One</li><li>Two</li></ol>"))
        #expect(html.contains("<blockquote><p>Quoted &amp; kept</p></blockquote>"))
        #expect(html.contains("<pre><code>&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;</code></pre>"))
        #expect(html.contains("<table><tr><th>Topic</th><th>Owner</th></tr><tr><td>Pricing</td><td>Sam</td></tr></table>"))
        #expect(html.contains("<hr><p>Last <del>word</del> <code>code</code></p>"))
        // Nothing from a call can become markup or a link to anything but the web.
        #expect(!html.contains("<script") && !html.contains("<b>") && !html.contains("javascript:") && !html.contains("Weekly%20sync"))
    }

    /// What Copy puts beside the Markdown: the meeting as a document, with its to-dos' boxes.
    @Test func whatCopyPuts() {
        let html = clipboardHTML("# Weekly sync\n\nTuesday · 10:00\n\n## To-dos\n\n- [ ] Send the deck — Alex Kim — due Fri — [00:42]\n- [x] Book a room\n\n## Launch\n- **Sam** moved it to Friday.\n")
        #expect(html.hasPrefix("<meta charset=\"utf-8\"><h2>Weekly sync</h2><p>Tuesday · 10:00</p><h3>To-dos</h3>"))
        #expect(html.contains("<ul><li>☐ Send the deck — Alex Kim — due Fri — [00:42]</li><li>☑ Book a room</li></ul>"))
        #expect(html.contains("<h3>Launch</h3><ul><li><strong>Sam</strong> moved it to Friday.</li></ul>"))
        // An item of two paragraphs keeps them apart.
        #expect(markdownHTML("- First point.\n\n  More detail.\n- Next.\n") == "<ul><li>First point.<p>More detail.</p></li><li>Next.</li></ul>")
        // Only a list item's own box: brackets anywhere else stay as they are.
        #expect(clipboardHTML("[ ] not a list\n").contains("<p>[ ] not a list</p>"))
    }
}
