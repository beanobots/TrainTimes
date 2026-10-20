import Foundation
import Testing
@testable import TrainCore

/// Searching for a station as the train picker and a shortcut's train do,
/// and what step-free mode says of a station's platforms.
@Suite struct StationSearchTests {
    /// The names of the stations `text` finds, each once.
    func found(_ text: String) -> Set<String> {
        let search = StationSearch(text)
        return Set(StationDirectory.all.filter(search.matches).map(\.name))
    }

    // MARK: Searching

    @Test func wordsWrittenOutFindTheMTAsAbbreviations() {
        #expect(found("34th street") == ["34 St-Herald Sq", "34 St-Hudson Yards", "34 St-Penn Station"])
        #expect(found("times square") == ["Times Sq-42 St"])
        #expect(found("lexington avenue") == ["Lexington Av/53 St", "Lexington Av/59 St", "Lexington Av/63 St"])
        #expect(found("42nd") == ["42 St-Bryant Pk", "42 St-Port Authority Bus Terminal", "Grand Central-42 St",
                                  "Times Sq-42 St"])
        #expect(found("west 4th street") == ["W 4 St-Wash Sq"])
        #expect(found("barclays center") == ["Atlantic Av-Barclays Ctr"])
        #expect(found("parkway").contains("Eastern Pkwy-Brooklyn Museum"))
        #expect(found("boulevard").contains("Junction Blvd"))
    }

    @Test func abbreviationsFindWordsWrittenOut() {
        #expect(found("ft hamilton") == ["Fort Hamilton Pkwy"])
        #expect(found("av h").contains("Avenue H"))
        #expect(found("queens plz").contains("Queens Plaza"))
    }

    @Test func theAbbreviationsAndTheWayTheyreWrittenStillWork() {
        #expect(found("34 st").isSuperset(of: ["34 St-Herald Sq", "34 St-Penn Station"]))
        #expect(found("times sq") == ["Times Sq-42 St"])
        #expect(found("pkwy") == found("parkway"))
        #expect(found("prospect").isSuperset(of: ["Prospect Av", "Prospect Park", "15 St-Prospect Park"]))
        // By borough too
        #expect(found("86 st brooklyn") == ["86 St"])
        #expect(StationDirectory.all.filter(StationSearch("86 st brooklyn").matches).allSatisfy { $0.borough == "Brooklyn" })
    }

    @Test func caseApostrophesAndPunctuationDontMatter() {
        #expect(found("St Mary's") == ["E 143 St-St Mary's St"])
        // As the iPhone's keyboard types it
        #expect(found("st mary’s") == ["E 143 St-St Mary's St"])
        #expect(found("BEDFORD-NOSTRAND aves") == ["Bedford-Nostrand Avs"])
        #expect(found("lexington av/59") == ["Lexington Av/59 St"])
    }

    @Test func aWordPartlyTypedFindsWhatItStarts() {
        #expect(found("34t") == found("34th"))
        #expect(found("lexington aven") == found("lexington avenue"))
        // Only the start of a word: "1st" is the 1 Av's, not the 14 St's
        #expect(found("1st av") == ["1 Av"])
        #expect(!found("34th street").contains("Prospect Av"))
    }

    @Test func nothingSearchedForFindsEveryStation() {
        #expect(StationDirectory.all.allSatisfy(StationSearch("").matches))
        #expect(StationDirectory.all.allSatisfy(StationSearch(" - ").matches))
    }

    // MARK: Step-free access

    /// The platform with this id.
    func platform(_ id: String) throws -> Platform {
        let station = try #require(StationDirectory.station(id: id))
        return try #require(station.platforms.first { $0.id == id })
    }

    @Test func aPartlyAccessiblePlatformIsStepFreeTheWayItsNotesName() throws {
        // 28 St's 6: "Downtown only"
        let twentyEighth = try platform("633")
        #expect(twentyEighth.stepFreeWay == .south)
        #expect(twentyEighth.isStepFree(going: .south) == true)
        #expect(twentyEighth.isStepFree(going: .north) == false)
        #expect(twentyEighth.isStepFree() == nil)
        // "Manhattan-bound only" is south at Court Sq-23 St, north at Wilson Av
        #expect(try platform("F09").stepFreeWay == .south)
        #expect(try platform("L20").stepFreeWay == .north)
        // "Southbound Only" at Hoyt St; "Uptown & Queens" at 49 St
        #expect(try platform("233").stepFreeWay == .south)
        #expect(try platform("R15").stepFreeWay == .north)
        // Only the local is: the 4 and 5 uptown aren't, so neither way is told
        let eightySixth = try platform("626")
        #expect(eightySixth.stepFreeWay == nil)
        #expect(eightySixth.isStepFree(going: .north) == nil)
    }

    @Test func everyPartlyAccessiblePlatformButTheLocalOnlyOneHasItsWay() {
        let partly = StationDirectory.platforms.filter { $0.ada == 2 }
        #expect(!partly.isEmpty)
        #expect(partly.filter { $0.stepFreeWay == nil }.map(\.id) == ["626"])
        // A platform that's step-free, or isn't at all, has no one way
        #expect(StationDirectory.platforms.filter { $0.ada != 2 }.allSatisfy { $0.stepFreeWay == nil })
    }

    @Test func whatStepFreeModeSays() throws {
        let twentyEighth = try [platform("633")]
        #expect(twentyEighth.stepFreeNote() == "Accessible: Downtown only")
        #expect(twentyEighth.stepFreeNote(going: .north) == "No step-free access")
        #expect(twentyEighth.stepFreeNote(going: .south) == nil)
        #expect(try [platform("626")].stepFreeNote(going: .north) == "Accessible: Uptown & The Bronx local only")
        // The N Q R W and L are step-free at 14 St-Union Sq, the 4 5 6 aren't
        let unionSquare = try #require(StationDirectory.station(id: "R20"))
        #expect(unionSquare.platforms.stepFreeNote() == "Step-free on some platforms")
        #expect(unionSquare.platforms(serving: ["N", "L"]).stepFreeNote(going: .north) == nil)
        #expect(unionSquare.platforms(serving: ["4"]).stepFreeNote(going: .south) == "No step-free access")
        let prospectAv = try #require(StationDirectory.station(id: "R34"))
        #expect(prospectAv.platforms.stepFreeNote() == "No step-free access")
    }

    @Test func aPlatformsLinesInTheStationsOrder() throws {
        let atlantic = try #require(StationDirectory.station(id: "R31"))
        #expect(try atlantic.lines(on: platform("R31")) == ["D", "N", "R"])
        #expect(try atlantic.lines(on: platform("235")) == ["2", "3", "4", "5"])
    }
}
