import Foundation

public enum VIPMatchKind: Equatable, Sendable {
    case phone
    case email
    case senderName
}

public struct VIPIdentityResolution: Equatable, Sendable {
    public let identity: VIPIdentity
    public let matchKind: VIPMatchKind

    public init(
        identity: VIPIdentity,
        matchKind: VIPMatchKind
    ) {
        self.identity = identity
        self.matchKind = matchKind
    }
}

public enum ImportantPersonMatcher {
    public static func resolveSender(
        _ sender: String?,
        identities: [VIPIdentity]
    ) -> VIPIdentityResolution? {
        guard let sender, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let senderPhones = canonicalPhones(in: sender)
        let phoneMatches = identities.filter { identity in
            !senderPhones.isDisjoint(with: Set(identity.phoneNumbers.compactMap(canonicalPhone)))
        }
        if phoneMatches.count == 1 {
            return VIPIdentityResolution(identity: phoneMatches[0], matchKind: .phone)
        }

        let senderEmails = canonicalEmails(in: sender)
        let emailMatches = identities.filter { identity in
            !senderEmails.isDisjoint(with: Set(identity.emails.compactMap(canonicalEmail)))
        }
        if emailMatches.count == 1 {
            return VIPIdentityResolution(identity: emailMatches[0], matchKind: .email)
        }
        guard senderPhones.isEmpty, senderEmails.isEmpty else { return nil }

        let senderName = displayNameComponent(from: sender)
        if let identity = uniqueIdentity(in: identities, matching: {
            nameMatches($0, senderName)
        }) {
            return VIPIdentityResolution(identity: identity, matchKind: .senderName)
        }

        return nil
    }

    public static func firstMatch(
        importantPeople: [String],
        sender: String?
    ) -> String? {
        let identities = importantPeople.map { VIPIdentity.manual(displayName: $0) }
        return resolveSender(sender, identities: identities)?.identity.displayName
    }

    public static func promotedIdentity(from sender: String) -> VIPIdentity? {
        let trimmedSender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSender.isEmpty else { return nil }
        if let email = canonicalEmail(trimmedSender) {
            return .manual(displayName: trimmedSender, emails: [email])
        }
        if let phone = canonicalPhone(trimmedSender), canonicalPhones(in: trimmedSender) == [phone] {
            return .manual(displayName: trimmedSender, phoneNumbers: [phone])
        }
        return .manual(displayName: trimmedSender)
    }

    /// Whether a VIP saved without a contact card, typed in or added from a
    /// notification, is the person on a contact card: the same full name, or a shared
    /// phone number or email. Stricter than `namesMatch`, so a typed “Aya” is not
    /// replaced by some other Aya’s card.
    public static func isSamePerson(_ savedIdentity: VIPIdentity, as contact: VIPIdentity) -> Bool {
        let savedName = normalizedTokens(savedIdentity.displayName)
        let contactNames = [contact.displayName, contact.nickname].compactMap { $0 }.map(normalizedTokens)
        if !savedName.isEmpty, contactNames.contains(savedName) {
            return true
        }
        let contactPhones = Set(contact.phoneNumbers.compactMap(canonicalPhone))
        if !contactPhones.isDisjoint(with: savedIdentity.phoneNumbers.compactMap(canonicalPhone)) {
            return true
        }
        let contactEmails = Set(contact.emails.compactMap(canonicalEmail))
        return !contactEmails.isDisjoint(with: savedIdentity.emails.compactMap(canonicalEmail))
    }

    /// The full name matches loosely (“Ken” finds “Ken Sato”); a nickname only as a
    /// whole, so a short one like “Ken” doesn't also claim “Ken Tanaka”.
    public static func nameMatches(_ identity: VIPIdentity, _ name: String) -> Bool {
        if namesMatch(identity.displayName, name) { return true }
        guard let nickname = identity.nickname else { return false }
        let nicknameTokens = normalizedTokens(nickname)
        return !nicknameTokens.isEmpty && nicknameTokens == normalizedTokens(name)
    }

    public static func namesMatch(_ firstName: String, _ secondName: String) -> Bool {
        let firstTokens = normalizedTokens(firstName)
        let secondTokens = normalizedTokens(secondName)
        guard !firstTokens.isEmpty, !secondTokens.isEmpty else { return false }

        if firstTokens == secondTokens {
            return true
        }

        let firstTokenSet = Set(firstTokens)
        let secondTokenSet = Set(secondTokens)
        return firstTokenSet.isSubset(of: secondTokenSet) || secondTokenSet.isSubset(of: firstTokenSet)
    }

    private static func uniqueIdentity(
        in identities: [VIPIdentity],
        matching predicate: (VIPIdentity) -> Bool
    ) -> VIPIdentity? {
        let matches = identities.filter(predicate)
        guard !matches.isEmpty else { return nil }
        let contactMatches = matches.filter { $0.provenance == .contact }
        if contactMatches.count == 1,
           matches.allSatisfy({ normalizedTokens($0.displayName) == normalizedTokens(contactMatches[0].displayName) }) {
            return contactMatches[0]
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func displayNameComponent(from sender: String) -> String {
        guard let angleBracketIndex = sender.firstIndex(of: "<") else { return sender }
        return String(sender[..<angleBracketIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalEmails(in sender: String) -> Set<String> {
        var candidates: [String] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(sender.startIndex..., in: sender)
            for match in detector.matches(in: sender, range: range) {
                guard let url = match.url, url.scheme?.lowercased() == "mailto" else { continue }
                candidates.append(url.absoluteString)
            }
        }
        candidates.append(contentsOf: sender.components(separatedBy: CharacterSet(charactersIn: "<> ,;()[]{}\"")))
        return Set(candidates.compactMap(canonicalEmail))
    }

    private static func canonicalEmail(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasPrefix("mailto:") {
            candidate.removeFirst("mailto:".count)
        }
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "<>.,;:\""))
        guard candidate.filter({ $0 == "@" }).count == 1,
              !candidate.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        let parts = candidate.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return candidate.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func canonicalPhones(in sender: String) -> Set<String> {
        var candidates: [String] = []
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
            let range = NSRange(sender.startIndex..., in: sender)
            for match in detector.matches(in: sender, range: range) {
                if let phoneNumber = match.phoneNumber { candidates.append(phoneNumber) }
            }
        }
        if sender.lowercased().hasPrefix("tel:") {
            candidates.append(String(sender.dropFirst("tel:".count)))
        } else if sender.rangeOfCharacter(from: .letters) == nil {
            candidates.append(sender)
        }
        return Set(candidates.compactMap(canonicalPhone))
    }

    private static func canonicalPhone(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmedValue.compactMap { character -> String? in
            guard let wholeNumberValue = character.wholeNumberValue else { return nil }
            return String(wholeNumberValue)
        }.joined()
        guard digits.count >= 7 else { return nil }
        return digits
    }

    private static func normalizedTokens(_ value: String) -> [String] {
        value
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
