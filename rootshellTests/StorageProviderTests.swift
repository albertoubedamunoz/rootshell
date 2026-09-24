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
        XCTAssertTrue(a.reachesSameNamespace(as: b), "AWS bucket names are global within a partition")
        b.bucket = "photos"
        XCTAssertTrue(a.reachesSameNamespace(as: b), "a bucket limit doesn't change what a path names")
        b.region = "cn-north-1"
        XCTAssertFalse(a.reachesSameNamespace(as: b), "AWS China is a separate partition")
        a.presetID = "wasabi"
        XCTAssertFalse(a.reachesSameNamespace(as: StorageProvider()))
    }

    func testEndpointIdentityKeepsSchemePortAndPath() {
        var a = StorageProvider()
        a.presetID = StorageProviderPreset.custom.id
        var b = a
        a.customEndpoint = "https://minio.local:9000"
        b.customEndpoint = "https://MINIO.local:9001"
        XCTAssertFalse(a.reachesSameNamespace(as: b), "different ports are different servers")
        b.customEndpoint = "http://minio.local:9000"
        XCTAssertFalse(a.reachesSameNamespace(as: b))
        b.customEndpoint = "https://minio.local:9000/tenant"
        XCTAssertFalse(a.reachesSameNamespace(as: b))
        a.customEndpoint = "https://minio.local"
        b.customEndpoint = "minio.local:443/"
        XCTAssertTrue(a.reachesSameNamespace(as: b), "default port and trailing slash are equivalent")
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

    func testKeyClassification() {
        XCTAssertEqual(S3KeyLogic.classify("docs/", under: "docs/"), .ignored, "the folder's own marker")
        XCTAssertEqual(S3KeyLogic.classify("other/a", under: "docs/"), .ignored)
        XCTAssertEqual(S3KeyLogic.classify("docs/a/", under: "docs/"), .child("a"))
        // Strict listings fail on these so a move never deletes what it couldn't copy.
        XCTAssertEqual(S3KeyLogic.classify("docs/./", under: "docs/"), .unrepresentable)
        XCTAssertEqual(S3KeyLogic.classify("docs/..", under: "docs/"), .unrepresentable)
        XCTAssertEqual(S3KeyLogic.classify("docs//", under: "docs/"), .unrepresentable)
    }

    func testDotSegmentsAreNotListed() {
        // Path normalization would turn these into their parent folder.
        XCTAssertNil(S3KeyLogic.childName("docs/./", under: "docs/"))
        XCTAssertNil(S3KeyLogic.childName("docs/../", under: "docs/"))
        XCTAssertNil(S3KeyLogic.childName("docs//", under: "docs/"))
        XCTAssertEqual(S3KeyLogic.childName("docs/.hidden", under: "docs/"), ".hidden")
        XCTAssertEqual(S3KeyLogic.childName("docs/...", under: "docs/"), "...")
    }

    func testCopySourceIsURLEncoded() {
        XCTAssertEqual(S3KeyLogic.copySource(bucket: "b", key: "dir/a file+1ü.txt"), "b/dir/a%20file%2B1%C3%BC.txt")
    }
}
