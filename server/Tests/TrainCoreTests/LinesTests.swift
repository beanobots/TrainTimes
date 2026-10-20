import Foundation
import Testing
@testable import TrainCore

/// `Lines.feedURLs(sharingTracksWith:)`: which of the MTA's feeds a train can be in.
@Suite struct LinesTests {
    /// "-nqrw" for the N Q R W feed, "" for the numbered lines'.
    func suffixes(_ urls: [URL]) -> [String] {
        urls.map { $0.absoluteString.components(separatedBy: "nyct%2Fgtfs").last ?? "" }
    }

    func feeds(_ routes: [String]) -> (own: [String], others: [String]) {
        let urls = Lines.feedURLs(sharingTracksWith: routes)
        return (suffixes(urls.own), suffixes(urls.others))
    }

    @Test func aLetteredLineAndTheLinesConnectedToIt() {
        #expect(Lines.feedURLs(sharingTracksWith: ["R"]).own
            == [URL(string: "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-nqrw")!])
        #expect(feeds(["R"]).own == ["-nqrw"])
        #expect(feeds(["R"]).others == ["-ace", "-bdfm", "-g", "-jz"])
        #expect(feeds(["G"]).others == ["-ace", "-bdfm", "-jz", "-nqrw"])
    }

    @Test func theShuttlesAreInTheirLinesFeeds() {
        #expect(feeds(["FS"]).own == ["-bdfm"])
        #expect(feeds(["H"]).own == ["-ace"])
        #expect(feeds(["GS"]).own == [""])
        #expect(feeds(["GS"]).others == [])
    }

    @Test func linesOnTracksOfTheirOwn() {
        for route in ["1", "2", "3", "4", "5", "6", "7"] {
            #expect(feeds([route]).own == [""])
            #expect(feeds([route]).others == [])
        }
        #expect(feeds(["L"]).own == ["-l"])
        #expect(feeds(["L"]).others == [])
        #expect(feeds(["SI"]).own == ["-si"])
        #expect(feeds(["SI"]).others == [])
    }

    @Test func severalLinesEachFeedOnce() {
        #expect(feeds(["N", "R"]).own == ["-nqrw"])
        #expect(feeds(["N", "R", "D"]).own == ["-nqrw", "-bdfm"])
        #expect(feeds(["N", "R", "D"]).others == ["-ace", "-g", "-jz"])
        // The 2 and the Q at Atlantic Av: the numbered lines' feed, and the lettered lines' with it
        #expect(feeds(["2", "Q"]).own == ["", "-nqrw"])
        #expect(feeds(["2", "Q"]).others == ["-ace", "-bdfm", "-g", "-jz"])
    }

    @Test func expressRoutesAreTheirLines() {
        #expect(["5X", "6X", "7X", "FX", "R", "GS"].map(Lines.normalized) == ["5", "6", "7", "F", "R", "GS"])
    }

    /// What VoiceOver calls a train of each line, everywhere it names one.
    @Test func eachShuttleIsSpokenOfByItsName() {
        #expect(Lines.spokenName(of: "R") == "R train")
        #expect(Lines.spokenName(of: "SI") == "SI train")
        // All three are "S" on their bullets
        #expect(Lines.spokenName(of: "GS") == "42 St Shuttle")
        #expect(Lines.spokenName(of: "FS") == "Franklin Av Shuttle")
        #expect(Lines.spokenName(of: "H") == "Rockaway Park Shuttle")
    }

    /// Siri names a shuttle among other lines too, where the screen has its bullet's S.
    @Test func aShuttleIsSaidByItsNameAmongOtherLines() {
        #expect(Lines.spokenList(["7", "GS"], joinedBy: "or") == "7 or 42 St Shuttle")
        #expect(Lines.spokenList(["N", "R"], joinedBy: "or") == "N or R")
        #expect(Lines.spokenList(["D", "N", "R"]) == "D, N and R")
        #expect(Lines.spokenList(["FS"]) == "Franklin Av Shuttle")
        #expect(Lines.spokenList([]) == "")
        #expect(Lines.list(["7", "GS"], joinedBy: "or") == "7 or S")
        #expect(Lines.list(["GS"]) == "42 St Shuttle")
    }

    /// The bullets' letters, drawn the same size by every bullet: the widgets',
    /// the app's, the picker's and the Edit menu's pictures.
    @Test func twoLetterBulletsHaveSmallerLetters() {
        #expect(LineStyle.of("R").labelSize(bullet: 100) == 62)
        #expect(LineStyle.of("GS").labelSize(bullet: 100) == 62)
        #expect(LineStyle.of("SI").labelSize(bullet: 100) == 45)
    }

    @Test func lineColoursAsRedGreenAndBlue() {
        let yellow = LineStyle.rgb(LineStyle.of("R").color)
        #expect(yellow.red == 252.0 / 255 && yellow.green == 204.0 / 255 && yellow.blue == 10.0 / 255)
        let white = LineStyle.rgb(0xFFFFFF)
        #expect(white.red == 1 && white.green == 1 && white.blue == 1)
    }
}
