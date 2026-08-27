import XCTest
@testable import VMIngestCore

final class TsrpExtractorTests: XCTestCase {
    /// Wrap a JSON payload in fake MP4 atom framing: some leading bytes, the
    /// `tsrp` marker, then the JSON, then trailing bytes.
    private func fixture(_ json: String) -> Data {
        var data = Data([0x00, 0x01, 0x02, 0x03])      // arbitrary leading bytes
        data.append("tsrp".data(using: .utf8)!)
        data.append(json.data(using: .utf8)!)
        data.append(Data([0xFF, 0xFE]))                // trailing bytes
        return data
    }

    func testDictShape() {
        let json = """
        {"attributedString":{"attributeTable":[{"x":1}],"runs":["Hello ",0,"world.",0]},"locale":["en-US"]}
        """
        XCTAssertEqual(TsrpExtractor.extract(from: fixture(json)), "Hello world.")
    }

    func testListShape() {
        let json = """
        {"attributedString":["Hello ",{"x":1},"world.",{"x":1}],"locale":["en-US"]}
        """
        XCTAssertEqual(TsrpExtractor.extract(from: fixture(json)), "Hello world.")
    }

    func testBraceInsideStringDoesNotTruncate() {
        // A `}` inside a transcript word must not end the JSON slice early.
        let json = """
        {"attributedString":{"runs":["weird } brace ",0,"after",0]},"locale":[]}
        """
        XCTAssertEqual(TsrpExtractor.extract(from: fixture(json)), "weird } brace after")
    }

    func testNoTsrpAtom() {
        let data = Data("no atom here".utf8)
        XCTAssertNil(TsrpExtractor.extract(from: data))
    }

    func testKeyOrderIndependence() {
        // locale before attributedString — order must not matter.
        let json = """
        {"locale":["en-US"],"attributedString":{"runs":["A ",0,"B",0],"attributeTable":[]}}
        """
        XCTAssertEqual(TsrpExtractor.extract(from: fixture(json)), "A B")
    }
}
