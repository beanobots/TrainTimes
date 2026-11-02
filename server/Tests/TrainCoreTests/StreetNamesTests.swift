import Testing
@testable import TrainCore

/// The city's street labels as people read them (`StreetNames`).
struct StreetNamesTests {
    @Test(arguments: [
        ("4 AVE", "4th Ave"),
        ("W 43 ST", "W 43rd St"),
        ("E 111 ST", "E 111th St"),
        ("E 112 ST", "E 112th St"),
        ("BEACH 101 ST", "Beach 101st St"),
        ("1 PL", "1st Pl"),
        ("AVE N", "Avenue N"),
        ("AVE OF THE AMERICAS", "Avenue of the Americas"),
        ("MCDONALD AVE", "McDonald Ave"),
        ("DE KALB AVE", "DeKalb Ave"),
        ("BROADWAY", "Broadway"),
        ("FDR DR", "FDR Dr"),
        ("ST MARKS PL", "St Marks Pl"),
        ("HAMILTON AVE", "Hamilton Ave"),
        ("PROSPECT EXPWY", "Prospect Expy"),
        ("BROOKLYN BRG", "Brooklyn Bridge"),
        ("GRAND CONC", "Grand Concourse"),
        ("O'BRIEN PL", "O'Brien Pl"),
        ("East Drive", "East Drive"),
    ])
    func display(label: String, name: String) {
        #expect(StreetNames.display(label) == name)
    }

    @Test func noneForNoName() {
        #expect(StreetNames.display("") == nil)
        #expect(StreetNames.display("  ") == nil)
    }

    @Test func ordinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112, 113].map(StreetNames.ordinal)
            == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th", "112th", "113th"])
    }
}
