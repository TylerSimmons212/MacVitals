import Foundation
import Security

/// Who signed a piece of code, in the terms that matter for trust. Checked the way Gatekeeper
/// starts: is the signature intact, and does it chain to Apple (App Store, Developer ID or Apple
/// itself)? Uses the fast checks only (no re-hashing of every file), so a 10 GB app takes
/// milliseconds.
struct CodeSignature: Equatable, Sendable {
    enum Trust: Equatable, Sendable {
        /// Signed by Apple: part of macOS or an Apple app.
        case apple
        /// Signed by a developer Apple has verified (Developer ID or Mac App Store).
        case verifiedDeveloper
        /// Signed locally, not by a verified developer (self-built, many open-source tools).
        case adHoc
        case unsigned
        /// Has a signature that doesn't check out: the code changed after it was signed.
        case invalid
        /// Couldn't be read (missing, permission).
        case unknown
    }

    let trust: Trust
    let teamID: String?
    /// "Developer ID Application: Acme Inc (ABCDE12345)" → "Acme Inc".
    let signer: String?

    var isVerified: Bool { trust == .apple || trust == .verifiedDeveloper }

    static func check(path: String) -> CodeSignature {
        guard FileManager.default.fileExists(atPath: path) else { return CodeSignature(trust: .unknown, teamID: nil, signer: nil) }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return CodeSignature(trust: .unknown, teamID: nil, signer: nil)
        }
        let fastFlags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        let validity = SecStaticCodeCheckValidity(code, fastFlags, nil)
        if validity == errSecCSUnsigned { return CodeSignature(trust: .unsigned, teamID: nil, signer: nil) }

        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any] ?? [:]
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signer = (info[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
            .flatMap { SecCertificateCopySubjectSummary($0) as String? }
            .map(Self.cleanSigner)
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0

        guard validity == errSecSuccess else { return CodeSignature(trust: .invalid, teamID: teamID, signer: signer) }
        if flags & 0x2 != 0 { return CodeSignature(trust: .adHoc, teamID: nil, signer: nil) } // kSecCodeSignatureAdhoc

        if satisfies(code, "anchor apple") { return CodeSignature(trust: .apple, teamID: teamID, signer: "Apple") }
        if satisfies(code, "anchor apple generic") {
            return CodeSignature(trust: .verifiedDeveloper, teamID: teamID, signer: signer)
        }
        // Signed with a certificate Apple didn't issue (self-made): no better than ad hoc.
        return CodeSignature(trust: .adHoc, teamID: teamID, signer: signer)
    }

    private static func satisfies(_ code: SecStaticCode, _ requirementText: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Certificate names read like "Developer ID Application: Acme Inc (ABCDE12345)".
    static func cleanSigner(_ summary: String) -> String {
        var name = summary
        for prefix in ["Developer ID Application: ", "Apple Mac OS Application Signing", "Apple Development: ", "Apple Distribution: ", "3rd Party Mac Developer Application: "] {
            if name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        }
        if name.isEmpty { return "Mac App Store" }
        if let paren = name.range(of: " (", options: .backwards), name.hasSuffix(")") {
            name = String(name[..<paren.lowerBound])
        }
        return name
    }
}
