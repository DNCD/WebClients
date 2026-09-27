import Contacts
import Foundation
import Observation

/// `ContactEmail` from `contacts/v4/contacts/emails`.
struct ProtonContactEmail: Codable, Hashable {
    let id: String
    let email: String
    let name: String
    let lastUsedTime: Int?
}

private struct ContactEmailsResponse: Decodable {
    let contactEmails: [ProtonContactEmail]
    let total: Int
}

/// A suggestion for the composer's recipient fields.
struct ContactSuggestion: Identifiable, Hashable {
    enum Source { case proton, device, recent }

    let name: String
    let email: String
    let source: Source

    var id: String { email.lowercased() }
}

/// Recipient autocomplete from Proton contacts (cached for offline use), the iOS address book (with
/// permission) and people you've exchanged mail with.
@MainActor
@Observable
final class ContactsService {
    private(set) var protonContacts: [ProtonContactEmail] = []
    private(set) var deviceContacts: [ContactSuggestion] = []
    private(set) var deviceAccess: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)

    private let api: APIClient
    private let store: MailStore
    private var loaded = false

    init(api: APIClient, store: MailStore) {
        self.api = api
        self.store = store
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        if let cached = try? await store.value("contacts"),
           let decoded = try? JSONDecoder().decode([ProtonContactEmail].self, from: Data(cached.utf8)) {
            protonContacts = decoded
        }
        await refreshProtonContacts()
        loadDeviceContacts()
    }

    /// Pages through `contacts/v4/contacts/emails` like the web (`CONTACT_EMAILS_LIMIT` = 1000).
    func refreshProtonContacts() async {
        var all: [ProtonContactEmail] = []
        var page = 0
        do {
            while true {
                let response: ContactEmailsResponse = try await api.send(.get("contacts/v4/contacts/emails", query: [
                    URLQueryItem(name: "Page", value: String(page)),
                    URLQueryItem(name: "PageSize", value: "1000"),
                ]))
                all += response.contactEmails
                page += 1
                if all.count >= response.total || response.contactEmails.isEmpty { break }
            }
            protonContacts = all
            if let data = try? JSONEncoder().encode(all) {
                try? await store.setValue(String(data: data, encoding: .utf8), for: "contacts")
            }
        } catch {
            // Keep the cached list when offline.
        }
    }

    func requestDeviceAccess() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        deviceAccess = CNContactStore.authorizationStatus(for: .contacts)
        loadDeviceContacts()
    }

    private func loadDeviceContacts() {
        guard deviceAccess == .authorized else { return }
        Task.detached(priority: .utility) {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            var results: [ContactSuggestion] = []
            let request = CNContactFetchRequest(keysToFetch: keys)
            try? CNContactStore().enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                for email in contact.emailAddresses {
                    results.append(ContactSuggestion(name: name, email: email.value as String, source: .device))
                }
            }
            let found = results
            await MainActor.run { self.deviceContacts = found }
        }
    }

    /// Best matches for what's being typed, Proton contacts first, then device contacts, then recent
    /// correspondents from the offline store.
    func suggestions(for text: String, recent: [Recipient] = [], limit: Int = 8) -> [ContactSuggestion] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 1 else { return [] }
        func matches(_ name: String, _ email: String) -> Bool {
            name.lowercased().split(separator: " ").contains { $0.hasPrefix(query) }
                || email.lowercased().hasPrefix(query)
                || name.lowercased().hasPrefix(query)
        }
        var seen = Set<String>()
        var results: [ContactSuggestion] = []
        let proton = protonContacts
            .filter { matches($0.name, $0.email) }
            .sorted { ($0.lastUsedTime ?? 0) > ($1.lastUsedTime ?? 0) }
            .map { ContactSuggestion(name: $0.name, email: $0.email, source: .proton) }
        let device = deviceContacts.filter { matches($0.name, $0.email) }
        let recents = recent.filter { matches($0.name, $0.address) }.map { ContactSuggestion(name: $0.name, email: $0.address, source: .recent) }
        for suggestion in proton + device + recents where seen.insert(suggestion.id).inserted {
            results.append(suggestion)
            if results.count == limit { break }
        }
        return results
    }
}
