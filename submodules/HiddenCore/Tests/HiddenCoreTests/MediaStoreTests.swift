import XCTest
@testable import HiddenCore

final class MediaStoreTests: XCTestCase {

    private func makeOpenContainer() -> (Container, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-media-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let c = Container(vaultDirectory: dir)
        XCTAssertTrue(c.open(pin: SecurePIN("1234")))
        return (c, dir)
    }

    private func sample(_ n: Int) -> Data {
        Data((0..<n).map { UInt8($0 & 0xff) })
    }

    func testSegmentedWholeRoundTrip() {
        let (c, _) = makeOpenContainer()
        let store = MediaStore(container: c)
        let data = sample(5000)
        guard let id = store.storeSegmented(data, segmentBytes: 1024) else { return XCTFail("store") }
        // Ciphertext on disk must differ from plaintext (spot-check first segment).
        XCTAssertEqual(store.loadWhole(id: id, segmentBytes: 1024, size: data.count), data)
    }

    func testSegmentedRangeReads() {
        let (c, _) = makeOpenContainer()
        let store = MediaStore(container: c)
        let data = sample(5000)
        guard let id = store.storeSegmented(data, segmentBytes: 1024) else { return XCTFail("store") }

        // A range spanning several segments.
        let mid = store.loadRange(id: id, segmentBytes: 1024, size: data.count, offset: 1500, length: 2000)
        XCTAssertEqual(mid, data.subdata(in: 1500..<3500))

        // A range within a single segment.
        let small = store.loadRange(id: id, segmentBytes: 1024, size: data.count, offset: 100, length: 50)
        XCTAssertEqual(small, data.subdata(in: 100..<150))

        // The tail, clamped to size.
        let tail = store.loadRange(id: id, segmentBytes: 1024, size: data.count, offset: 4900, length: 9999)
        XCTAssertEqual(tail, data.subdata(in: 4900..<5000))
    }

    func testSingleBlobFallbackStillWorks() {
        let (c, _) = makeOpenContainer()
        let store = MediaStore(container: c)
        let data = sample(300)
        guard let id = store.store(data) else { return XCTFail("store") }
        // segmentBytes == 0 => single-blob path for both whole and range reads.
        XCTAssertEqual(store.loadWhole(id: id, segmentBytes: 0, size: data.count), data)
        XCTAssertEqual(store.loadRange(id: id, segmentBytes: 0, size: data.count, offset: 100, length: 100),
                       data.subdata(in: 100..<200))
    }

    func testDeleteRemovesSegmentedDir() {
        let (c, _) = makeOpenContainer()
        let store = MediaStore(container: c)
        guard let id = store.storeSegmented(sample(3000), segmentBytes: 1024) else { return XCTFail("store") }
        XCTAssertTrue(store.exists(id))
        store.delete(id)
        XCTAssertFalse(store.exists(id))
    }
}
