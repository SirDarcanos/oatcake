import AVFoundation
import CryptoKit
import Foundation
import Network
@testable import OatcakeCore
import Testing

@Suite struct MenuBarLinkTests {
    /// What Oatcake tells the helper that draws its menu bar item, and what the helper says back,
    /// each survive the trip as one line.
    @Test func linesBothWays() throws {
        let events = try JSONDecoder().decode([CalendarEvent].self, from: Data(contentsOf: fixture("calendar-expected.json")))
        let event = try #require(events.first)
        let shown: [MenuBarContent] = [.recording(title: "Weekly sync", elapsed: nil), .recording(title: "A “quoted”\nname", elapsed: 12.5),
                                       .upcoming(Array(events.prefix(3))), .upcoming([])]
        for content in shown {
            let line = String(decoding: MenuBarLink.line(content), as: UTF8.self)
            #expect(line.hasSuffix("\n") && !line.dropLast().contains("\n"))
            #expect(MenuBarLink.read(MenuBarContent.self, String(line.dropLast())) == content)
        }
        let chosen: [MenuBarAction] = [.stop, .open, .record, .openEvent(event), .quit]
        for action in chosen {
            #expect(MenuBarLink.read(MenuBarAction.self, String(decoding: MenuBarLink.line(action).dropLast(), as: UTF8.self)) == action)
        }
        #expect(MenuBarLink.read(MenuBarAction.self, "not one of these") == nil)

        // A pipe hands lines over in pieces of any size.
        var buffer = LineBuffer()
        let both = MenuBarLink.line(MenuBarAction.stop) + MenuBarLink.line(MenuBarAction.openEvent(event))
        #expect(buffer.add(Data(both.prefix(5))) == [])
        let lines = buffer.add(Data(both.dropFirst(5).dropLast(1)))
        #expect(lines.compactMap { MenuBarLink.read(MenuBarAction.self, $0) } == [.stop])
        #expect(buffer.add(Data("\n".utf8)).compactMap { MenuBarLink.read(MenuBarAction.self, $0) } == [.openEvent(event)])
    }
}
