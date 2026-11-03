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
        ("Forsyth Street", "Forsyth St"),
        ("3rd Avenue", "3rd Ave"),
        ("Avenue of the Americas", "Avenue of the Americas"),
    ])
    func display(label: String, name: String) {
        #expect(StreetNames.display(label) == name)
    }

    @Test func noneForNoName() {
        #expect(StreetNames.display("") == nil)
        #expect(StreetNames.display("  ") == nil)
    }

    /// One path or street however it's spelled, OSM's and the city's, and the spelling written
    /// out more shown.
    @Test func spellingsOfOneName() {
        #expect(StreetNames.same("Brooklyn Bridge Pedestrian Path", "Brooklyn Brdg Pedestrian Path"))
        #expect(StreetNames.same("Hudson Boulevard West", "Hudson Bl W"))
        #expect(StreetNames.same("W 43rd St", "West 43 Street"))
        #expect(!StreetNames.same("W 43rd St", "W 44th St"))
        #expect(!StreetNames.same("E 72nd St", "W 72nd St"))
        #expect(StreetNames.nicer("Brooklyn Brdg Pedestrian Path", "Brooklyn Bridge Pedestrian Path") == "Brooklyn Bridge Pedestrian Path")
        #expect(StreetNames.nicer("Hudson Bl W", "Hudson Boulevard West") == "Hudson Boulevard West")
        // The app's own short forms kept
        #expect(StreetNames.nicer("W 43rd St", "West 43rd Street") == "W 43rd St")
    }

    /// Streets, crossed, not a park's or a place's names.
    @Test func streetsAreToldFromPlaces() {
        for street in ["W 72nd St", "West Dr", "72nd Street Transverse", "Central Park W", "Broadway", "Avenue N",
                       "Avenue of the Americas", "Grand Concourse", "Columbus Cir", "Queens Plaza S"] {
            #expect(StreetNames.isStreet(street), "\(street)")
        }
        for place in ["Strawberry Fields", "Sheep Meadow", "Bethesda Fountain", "Brooklyn Bridge Pedestrian Path"] {
            #expect(!StreetNames.isStreet(place), "\(place)")
        }
    }

    @Test func ordinals() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112, 113].map(StreetNames.ordinal)
            == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th", "112th", "113th"])
    }
}
