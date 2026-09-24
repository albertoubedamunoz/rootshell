import XCTest

final class StorageProviderTests: XCTestCase {

    // MARK: - Endpoints

    func testPresetEndpointSubstitutesRegionAndAccount() {
        var provider = StorageProvider()
        provider.presetID = "wasabi"
        provider.region = "eu-central-1"
        XCTAssertEqual(provider.resolvedEndpoint, "https://s3.eu-central-1.wasabisys.com")

        provider.presetID = "r2"
        provider.accountID = " abc123 "
        XCTAssertEqual(provider.resolvedEndpoint, "https://abc123.r2.cloudflarestorage.com")
    }

    func testEmptyRegionFallsBackToPresetDefault() {
        var provider = StorageProvider()
        provider.presetID = "b2"
        XCTAssertEqual(provider.effectiveRegion, "us-west-004")
        XCTAssertEqual(provider.resolvedEndpoint, "https://s3.us-west-004.backblazeb2.com")
    }

    func testAWSUsesSDKEndpointsUnlessOverridden() {
        var provider = StorageProvider()
        XCTAssertNil(provider.resolvedEndpoint)
        provider.customEndpoint = "minio.local:9000/"
        XCTAssertEqual(provider.resolvedEndpoint, "https://minio.local:9000")
        provider.customEndpoint = "http://10.0.0.2:9000"
        XCTAssertEqual(provider.resolvedEndpoint, "http://10.0.0.2:9000")
    }

    func testSigningRegion() {
        var akamai = StorageProvider()
        akamai.presetID = "linode"
        akamai.region = "us-southeast-1"
        XCTAssertEqual(akamai.resolvedEndpoint, "https://us-southeast-1.linodeobjects.com")
        XCTAssertEqual(akamai.effectiveSigningRegion, "us-east-1", "Akamai signs with a fixed region")
        akamai.signingRegion = " us-southeast "
        XCTAssertEqual(akamai.effectiveSigningRegion, "us-southeast")

        var wasabi = StorageProvider()
        wasabi.presetID = "wasabi"
        wasabi.region = "eu-central-1"
        XCTAssertEqual(wasabi.effectiveSigningRegion, "eu-central-1", "most services sign with the endpoint's region")
    }

    func testValidation() {
        var provider = StorageProvider()
        provider.presetID = StorageProviderPreset.custom.id
        XCTAssertNotNil(provider.validationError, "custom servers need an endpoint")
        provider.customEndpoint = "https://s3.example.com"
        XCTAssertNil(provider.validationError, "no keys means anonymous access")
        provider.accessKeyID = "AKIA"
        XCTAssertNotNil(provider.validationError, "an access key needs its secret")
        provider.secretAccessKey = "secret"
        XCTAssertNil(provider.validationError)

        var r2 = StorageProvider()
        r2.presetID = "r2"
        XCTAssertNotNil(r2.validationError, "R2 needs an account ID")
    }

    func testNamespaces() {
        var a = StorageProvider()
        var b = StorageProvider()
        b.region = "eu-west-1"
        XCTAssertTrue(a.reachesSameNamespace(as: b), "AWS bucket names are global")
        b.bucket = "photos"
        XCTAssertFalse(a.reachesSameNamespace(as: b), "a fixed bucket changes what paths mean")
        a.bucket = "/photos/"
        XCTAssertTrue(a.reachesSameNamespace(as: b))
        a.presetID = "wasabi"
        XCTAssertFalse(a.reachesSameNamespace(as: b))
    }

    func testDecodingToleratesMissingFields() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Old"}"#
        let provider = try JSONDecoder().decode(StorageProvider.self, from: Data(json.utf8))
        XCTAssertEqual(provider.id, id)
        XCTAssertEqual(provider.name, "Old")
        XCTAssertEqual(provider.presetID, StorageProviderPreset.custom.id)
    }

    // MARK: - Keys

    func testChildNames() {
        XCTAssertEqual(S3KeyLogic.childName("docs/a.txt", under: "docs/"), "a.txt")
        XCTAssertEqual(S3KeyLogic.childName("docs/sub/", under: "docs/"), "sub")
        XCTAssertNil(S3KeyLogic.childName("docs/", under: "docs/"), "a folder's own marker is not a child")
        XCTAssertNil(S3KeyLogic.childName("docs/sub/a.txt", under: "docs/"))
        XCTAssertNil(S3KeyLogic.childName("other/a.txt", under: "docs/"))
        XCTAssertEqual(S3KeyLogic.childName("top.txt", under: ""), "top.txt")
    }

    func testCopySourceIsURLEncoded() {
        XCTAssertEqual(S3KeyLogic.copySource(bucket: "b", key: "dir/a file+1ü.txt"), "b/dir/a%20file%2B1%C3%BC.txt")
    }
}
