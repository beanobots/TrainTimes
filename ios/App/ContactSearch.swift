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
/// your contacts, or those you've shared with it (`ContactAccessButton`). Never asks itself.
@MainActor
@Observable
final class ContactSearch {
    private(set) var status = CNContactStore.authorizationStatus(for: .contacts)
    private var results: [ContactAddress] = []
    /// What `results` were found for.
    private var resultsQuery = ""
    @ObservationIgnored private var lookup: Task<Void, Never>?

    /// Whether Apple's button may offer more contacts: Leeway sees only some, or hasn't asked.
    var mayShare: Bool { status == .limited || status == .notDetermined }

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
        let predicate = CNContact.predicateForContacts(matchingName: query)
        guard let contacts = try? CNContactStore().unifiedContacts(matching: predicate, keysToFetch: keys) else {
            return []
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

    /// "SC" for Sarah Chen; a company's first letter.
    private nonisolated static func initials(_ contact: CNContact, name: String) -> String {
        let letters = [contact.givenName.first, contact.familyName.first].compactMap { $0 }
        return letters.isEmpty ? String(name.prefix(1)).uppercased() : String(letters).uppercased()
    }
}
