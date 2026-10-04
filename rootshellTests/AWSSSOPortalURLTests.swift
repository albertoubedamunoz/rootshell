import Foundation
import XCTest

nonisolated final class AWSSSOPortalURLTests: XCTestCase {
    func testBuildsRegionalPortalURL() {
        let url = AWSSSOPortalURL.make(region: "us-west-2", path: "/assignment/accounts")
        XCTAssertEqual(url?.absoluteString, "https://portal.sso.us-west-2.amazonaws.com/assignment/accounts")
    }

    func testEscapesReservedCharactersInRoleName() {
        let url = AWSSSOPortalURL.make(
            region: "us-east-1",
            path: "/federation/credentials",
            query: [("account_id", "123456789012"), ("role_name", "Admin+Ops=1")]
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://portal.sso.us-east-1.amazonaws.com/federation/credentials?account_id=123456789012&role_name=Admin%2BOps%3D1"
        )
    }

    func testPageTokenRoundTrips() throws {
        let token = "AAB+c/d&e?f==g h"
        let url = try XCTUnwrap(AWSSSOPortalURL.make(
            region: "eu-central-1",
            path: "/assignment/roles",
            query: [("account_id", "123456789012"), ("next_token", token)]
        ))
        let query = try XCTUnwrap(url.query(percentEncoded: true))
        XCTAssertFalse(query.contains("+"))
        XCTAssertEqual(query.components(separatedBy: "&").count, 2)

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first(where: { $0.name == "next_token" })?.value, token)
    }
}
