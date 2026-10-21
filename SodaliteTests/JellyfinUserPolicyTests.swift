import Testing
import Foundation
@testable import Sodalite

/// The account-policy gates read off `/Users/Me`'s Policy block.
struct JellyfinUserPolicyTests {

    func user(policy: String?) throws -> JellyfinUser {
        let policyJSON = policy.map { #", "Policy": {"IsAdministrator": false, "EnableContentDeletion": false\#($0)}"# } ?? ""
        let json = #"{"Id": "u", "Name": "N", "ServerId": "s"\#(policyJSON)}"#
        return try JSONDecoder().decode(JellyfinUser.self, from: Data(json.utf8))
    }

    // MARK: - seesWholeLibrary (audit 2026-09-25 CL-3)

    /// A 404 on a known item id is proof of deletion only for a user who could have seen the item.
    @Test func anUnrestrictedPolicySeesTheWholeLibrary() throws {
        let u = try user(policy: #", "EnableAllFolders": true, "MaxParentalRating": null, "BlockedTags": [], "AllowedTags": [], "BlockUnratedItems": []"#)
        #expect(u.seesWholeLibrary)
    }

    @Test(arguments: [
        #", "EnableAllFolders": false"#,
        #", "EnableAllFolders": true, "MaxParentalRating": 12"#,
        #", "EnableAllFolders": true, "BlockedTags": ["adult"]"#,
        #", "EnableAllFolders": true, "AllowedTags": ["kids"]"#,
        #", "EnableAllFolders": true, "BlockUnratedItems": ["Movie"]"#,
    ])
    func anyRestrictionMeansA404ProvesNothing(fields: String) throws {
        #expect(try user(policy: fields).seesWholeLibrary == false)
    }

    /// The keychain stub carries no policy until the first /Users/Me, and an older server may omit a field.
    @Test func anUnknownPolicyIsTreatedAsRestricted() throws {
        #expect(try user(policy: nil).seesWholeLibrary == false)
        #expect(try user(policy: "").seesWholeLibrary == false)
    }
}

extension JellyfinUserPolicyTests {

    // MARK: - canManageLiveTv (audit 2026-09-25 LTV-5)

    /// Jellyfin's timer endpoints check EnableLiveTvManagement with no administrator shortcut.
    @Test func liveTvManagementFollowsItsOwnFlag() throws {
        #expect(try user(policy: #", "EnableLiveTvManagement": true"#).canManageLiveTv)
        #expect(try user(policy: #", "EnableLiveTvManagement": false"#).canManageLiveTv == false)
        #expect(try user(policy: "").canManageLiveTv == false)
        #expect(try user(policy: nil).canManageLiveTv == false)
    }
}

extension JellyfinUserPolicyTests {

    // MARK: - Sparse Policy blocks (TestFlight feedback 2026-10-21)

    /// A server that leaves a grant out of Policy must still let the user log in; the grant reads as withheld.
    @Test func aPolicyMissingItsGrantsStillDecodes() throws {
        let json = #"{"Id": "u", "Name": "N", "ServerId": "s", "Policy": {"EnableAllFolders": true}}"#
        let u = try JSONDecoder().decode(JellyfinUser.self, from: Data(json.utf8))
        #expect(u.policy?.isAdministrator == false)
        #expect(u.canDeleteContent == false)
        #expect(u.policy?.enableAllFolders == true)
    }
}
