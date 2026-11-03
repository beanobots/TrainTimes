import Contacts
import Foundation
import Observation

/// One of a contact's postal addresses, to pick as an end of a New Trip.
struct ContactAddress: Identifiable, Hashable, Sendable {
    /// The contact's identifier and the address's.
    let id: String
    let name: String
    let initials: String
    /// Which address it is: "home", "work", or the contact's own label; nil without one.
    let label: String?
    /// The street, for under the name.
    let street: String
    /// The whole address on one line, to look up.
    let address: String
}

/// Your contacts' addresses for New Trip's search, by name. Reads only what Leeway may see: all
/// your contacts, or those you've shared with it (`ContactAccessButton`). Asks only when told to.
@MainActor
@Observable
final class ContactSearch {
    private(set) var status = CNContactStore.authorizationStatus(for: .contacts)
    private var results: [ContactAddress] = []
    /// What `results` were found for.
    private var resultsQuery = ""
    @ObservationIgnored private var lookup: Task<Void, Never>?

    /// Whether Leeway hasn't asked for your contacts yet.
    var mayAsk: Bool { status == .notDetermined }
    /// Whether Apple's button may offer more contacts: Leeway sees only some.
    var mayShare: Bool { status == .limited }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            find()
        }
    }

    /// The results for `query`, none while they're still for what was typed before it.
    func results(for query: String) -> [ContactAddress] {
        query == resultsQuery ? results : []
    }

    /// Asks for your contacts (all, or some you choose), then looks.
    func ask() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        refresh()
    }

    /// Looks again, after contacts are shared.
    func refresh() {
        status = CNContactStore.authorizationStatus(for: .contacts)
        find()
    }

    private func find() {
        lookup?.cancel()
        let query = query
        guard query.count >= 2, status == .authorized || status == .limited else {
            results = []
            resultsQuery = query
            return
        }
        lookup = Task {
            // Off the main thread: the store reads from disk
            let found = await Task.detached(priority: .userInitiated) { Self.addresses(matching: query) }.value
            guard !Task.isCancelled else { return }
            results = found
            resultsQuery = query
        }
    }

    /// Addresses of the contacts whose names match `query`, the contacts by name, and at most 12.
    private nonisolated static func addresses(matching query: String) -> [ContactAddress] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
        ]
        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(matchingName: query)
        guard var contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys) else {
            return []
        }
        if contacts.isEmpty {
            contacts = nearlyNamed(query, in: store, keys: keys)
        }
        let streets = CNPostalAddressFormatter()
        var found: [ContactAddress] = []
        for contact in contacts {
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            guard !name.isEmpty else { continue }
            for labeled in contact.postalAddresses {
                let postal = labeled.value
                let street = postal.street.split(separator: "\n").first.map(String.init) ?? ""
                let whole = streets.string(from: postal).replacingOccurrences(of: "\n", with: ", ")
                guard !whole.isEmpty else { continue }
                found.append(ContactAddress(
                    id: "\(contact.identifier)/\(labeled.identifier)",
                    name: name,
                    initials: initials(contact, name: name),
                    label: labeled.label.map { CNLabeledValue<CNPostalAddress>.localizedString(forLabel: $0) },
                    street: street.isEmpty ? whole : [street, postal.city].filter { !$0.isEmpty }.joined(separator: ", "),
                    address: whole))
            }
        }
        return Array(found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(12))
    }

    /// Contacts with addresses whose names are a typo or two from `query`, for when none match
    /// exactly: "sarha" is Sarah Chen. Each word typed has to be near the start of a word of the
    /// name, as in station search (`Typos`).
    private nonisolated static func nearlyNamed(_ query: String, in store: CNContactStore,
                                                keys: [CNKeyDescriptor]) -> [CNContact] {
        let typed = words(in: query)
        guard typed.contains(where: { Typos.allowed(in: $0) > 0 }) else { return [] }
        var found: [CNContact] = []
        try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
            guard !contact.postalAddresses.isEmpty else { return }
            let name = words(in: [contact.givenName, contact.familyName, contact.organizationName].joined(separator: " "))
            let near = typed.allSatisfy { word in
                let allowed = Typos.allowed(in: word)
                return name.contains { Typos.count(from: word, toStartOf: $0, upTo: allowed) <= allowed }
            }
            if near { found.append(contact) }
        }
        return found
    }

    /// Lowercased without accents, split on what isn't a letter or number.
    private nonisolated static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// "SC" for Sarah Chen; a company's first letter.
    private nonisolated static func initials(_ contact: CNContact, name: String) -> String {
        let letters = [contact.givenName.first, contact.familyName.first].compactMap { $0 }
        return letters.isEmpty ? String(name.prefix(1)).uppercased() : String(letters).uppercased()
    }
}
