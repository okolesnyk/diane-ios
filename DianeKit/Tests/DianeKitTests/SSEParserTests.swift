import Testing

@testable import DianeKit

@Suite("SSE parsing")
struct SSEParserTests {
    @Test("named event dispatches on blank line")
    func namedEvent() {
        var parser = SSEParser()
        #expect(parser.feed(line: "event: chores-changed") == nil)
        #expect(parser.feed(line: "data: {}") == nil)
        let event = parser.feed(line: "")
        #expect(event == SSEvent(name: "chores-changed", data: "{}"))
    }

    @Test("event name defaults to message")
    func defaultName() {
        var parser = SSEParser()
        _ = parser.feed(line: "data: hello")
        #expect(parser.feed(line: "") == SSEvent(name: "message", data: "hello"))
    }

    @Test("heartbeat comments never dispatch")
    func comments() {
        var parser = SSEParser()
        #expect(parser.feed(line: ": ping") == nil)
        #expect(parser.feed(line: "") == nil)
    }

    @Test("blank line without data emits nothing")
    func emptyDispatch() {
        var parser = SSEParser()
        _ = parser.feed(line: "event: stars-changed")
        #expect(parser.feed(line: "") == nil)
    }

    @Test("multi-line data joins with newline")
    func multiLineData() {
        var parser = SSEParser()
        _ = parser.feed(line: "data: a")
        _ = parser.feed(line: "data: b")
        #expect(parser.feed(line: "") == SSEvent(name: "message", data: "a\nb"))
    }

    @Test("state resets after dispatch")
    func resets() {
        var parser = SSEParser()
        _ = parser.feed(line: "event: members-changed")
        _ = parser.feed(line: "data: 1")
        _ = parser.feed(line: "")
        _ = parser.feed(line: "data: 2")
        #expect(parser.feed(line: "") == SSEvent(name: "message", data: "2"))
    }

    @Test("only one leading space is stripped from values")
    func valueSpaceStripping() {
        var parser = SSEParser()
        _ = parser.feed(line: "data:  spaced")
        #expect(parser.feed(line: "") == SSEvent(name: "message", data: " spaced"))
    }

    @Test("field without colon is ignored")
    func bareField() {
        var parser = SSEParser()
        #expect(parser.feed(line: "data") == nil)
        // Bare "data" counts as an empty data line per the SSE spec.
        #expect(parser.feed(line: "") == SSEvent(name: "message", data: ""))
    }
}

@Suite("line buffering")
struct LineBufferTests {
    @Test("splits on \\n and strips \\r")
    func crlf() {
        var buffer = LineBuffer()
        var lines: [String] = []
        for byte in Array("a\r\nb\n\n".utf8) {
            if let line = buffer.feed(byte) { lines.append(line) }
        }
        #expect(lines == ["a", "b", ""])
    }

    @Test("utf8 survives chunked feeding")
    func utf8() {
        var buffer = LineBuffer()
        var lines: [String] = []
        for byte in Array("🔔 Feed the cat\n".utf8) {
            if let line = buffer.feed(byte) { lines.append(line) }
        }
        #expect(lines == ["🔔 Feed the cat"])
    }
}

@Suite("Diane topics")
struct DianeTopicTests {
    @Test("all server topics round-trip")
    func roundTrip() {
        for topic in DianeTopic.allCases {
            #expect(DianeTopic(rawValue: topic.rawValue) == topic)
        }
        #expect(DianeTopic(rawValue: "chores-changed") == .chores)
        #expect(DianeTopic(rawValue: "weather-changed") == nil)
    }
}
