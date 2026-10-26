import Testing
@testable import TrainCore

/// `AlertBrief(header:)` cutting the MTA's delay headlines down to lines and a direction.
@Suite struct AlertBriefTests {
    @Test func bothDirections() throws {
        let brief = try #require(AlertBrief(header: "[2][5] trains are running with delays in both directions after we addressed a signal problem near 3 Av/149 St."))
        #expect(brief.routes == ["2", "5"])
        #expect(brief.direction == "Both directions")
    }

    @Test func boundForSomewhere() throws {
        let brief = try #require(AlertBrief(header: "Coney Island-bound [D][N] trains are delayed while we address a signal problem at 36 St."))
        #expect(brief.routes == ["D", "N"])
        #expect(brief.direction == "Coney Island-bound")
    }

    @Test func compassDirection() throws {
        let brief = try #require(AlertBrief(header: "Some northbound [R] trains are delayed while crews respond to a sick customer."))
        #expect(brief.routes == ["R"])
        #expect(brief.direction == "Northbound")
    }

    @Test func noDirection() throws {
        let brief = try #require(AlertBrief(header: "[A][C] trains are running with delays."))
        #expect(brief.routes == ["A", "C"])
        #expect(brief.direction == nil)
    }

    @Test func onlyTheLinesBeforeTrains() throws {
        let brief = try #require(AlertBrief(header: "[F] trains are delayed. Take the [M] instead."))
        #expect(brief.routes == ["F"])
    }

    @Test func noLinesNoBrief() {
        #expect(AlertBrief(header: "Trains are delayed systemwide.") == nil)
    }

    @Test func theLineToTakeInstead() throws {
        let c = try #require(AlertBrief(header: "[C] service ends early - take the [A] instead"))
        #expect(c.routes == ["C"])
        #expect(c.alternatives == ["A"])
        // No "trains" to stop at: the line taken instead isn't the alert's
        let w = try #require(AlertBrief(header: "No [W] between 57 St-7 Av, Manhattan and Astoria-Ditmars Blvd, Queens - take the [N] instead"))
        #expect(w.routes == ["W"])
        #expect(w.alternatives == ["N"])
        let two = try #require(AlertBrief(header: "In Manhattan, uptown [2] local skips 79 St and 86 St - Take the [1] instead"))
        #expect(two.alternatives == ["1"])
        #expect(two.direction == "Uptown")
        #expect(try #require(AlertBrief(header: "[F] trains are delayed. Take the [M] instead.")).alternatives == ["M"])
        // Kept for a widget on the C; not one of its own lines, for a widget on both
        #expect(c.only(["C"]).alternatives == ["A"])
        #expect(c.only(["A", "C"]).alternatives == [])
        #expect(AlertBrief(header: "[R] trains are delayed")?.alternatives == nil)
        #expect(AlertBrief.alternatives(in: "No service between X and Y - take the [N]") == ["N"])
    }
}

/// `AlertsFeed.readable(_:)` writing the MTA's "[R]" lines as words.
@Suite struct ReadableAlertTests {
    @Test func oneLine() {
        #expect(AlertsFeed.readable("[R] trains are delayed.") == "R trains are delayed.")
    }

    @Test func twoLinesSideBySide() {
        #expect(AlertsFeed.readable("[2][5] trains are running with delays.") == "2 and 5 trains are running with delays.")
    }

    @Test func threeLinesWithSpaces() {
        #expect(AlertsFeed.readable("[A] [C] [E] trains skip 50 St.") == "A, C and E trains skip 50 St.")
    }

    @Test func separateMentionsStaySeparate() {
        #expect(AlertsFeed.readable("[F] trains run via the [M].") == "F trains run via the M.")
    }

    @Test func iconsGo() {
        #expect(AlertsFeed.readable("Take the [Q] to JFK [airplane icon].") == "Take the Q to JFK.")
    }
}
