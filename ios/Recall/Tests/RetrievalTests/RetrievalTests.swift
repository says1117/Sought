import XCTest
import Foundation
#if canImport(Memory)
import Memory
#endif
#if canImport(Retrieval)
@testable import Retrieval
#endif

struct FakeTextEncoder: TextEncoder {
    var table: [String: [Float]]
    func encode(_ text: String) throws -> [Float] {
        guard let v = table[text] else { throw NSError(domain: "fake", code: 1) }
        return v
    }
}

final class RetrievalTests: XCTestCase {
    func testPromptsAreRawAndPhotoOf() {
        XCTAssertEqual(QueryEncoder.prompts(for: "red mug"), ["red mug", "a photo of red mug"])
    }

    func testQueryIsNormalizedMeanOfTwoPrompts() throws {
        let enc = FakeTextEncoder(table: ["mug": [2, 0, 0], "a photo of mug": [0, 2, 0]])
        let q = try QueryEncoder.queryVector(phrase: "mug", encoder: enc)
        XCTAssertEqual(q[0], 0.70710678, accuracy: 1e-5)
        XCTAssertEqual(q[1], 0.70710678, accuracy: 1e-5)
        XCTAssertEqual(q[2], 0, accuracy: 1e-6)
    }

    func testEmptyPhraseAndZeroVectorThrow() {
        let enc = FakeTextEncoder(table: ["x": [0, 0], "a photo of x": [0, 0]])
        XCTAssertThrowsError(try QueryEncoder.queryVector(phrase: "  ", encoder: enc)) {
            XCTAssertEqual($0 as? QueryEncodingError, .emptyPhrase)
        }
        XCTAssertThrowsError(try QueryEncoder.queryVector(phrase: "x", encoder: enc)) {
            XCTAssertEqual($0 as? QueryEncodingError, .zeroVector)
        }
    }

    func testScoreBlendsPersistence() {
        let q: [Float] = [1, 0]
        let hi = Track(id: "hi", position: .zero, embedding: [1, 0], sightings: 3, persistence: 1.0)
        let lo = Track(id: "lo", position: .zero, embedding: [1, 0], sightings: 3, persistence: 0.0)
        let r = Retriever.rank(query: q, phrase: "p", tracks: [lo, hi])
        XCTAssertEqual(r.ranked.map { $0.trackID }, ["hi", "lo"])
        XCTAssertEqual(r.ranked[0].score, 1.0, accuracy: 1e-6)
        XCTAssertEqual(r.ranked[1].score, 0.8, accuracy: 1e-6)
    }

    func testUnconfirmedOnlyUsedWhenNothingConfirmed() {
        let q: [Float] = [1, 0]
        let weakConfirmed = Track(id: "c", position: .zero, embedding: [0.1, 1], sightings: 5, persistence: 0.5)
        let strongNew = Track(id: "u", position: .zero, embedding: [1, 0], sightings: 1, persistence: 0.3)
        var r = Retriever.rank(query: q, phrase: "p", tracks: [strongNew, weakConfirmed])
        XCTAssertEqual(r.ranked.map { $0.trackID }, ["c"])
        XCTAssertFalse(r.log.usedUnconfirmed)
        XCTAssertEqual(r.log.scored.map { $0.trackID }, ["u", "c"])   // log keeps everything scored

        r = Retriever.rank(query: q, phrase: "p", tracks: [strongNew])
        XCTAssertEqual(r.ranked.map { $0.trackID }, ["u"])
        XCTAssertTrue(r.log.usedUnconfirmed)
    }

    func testTopKAndDeterministicTies() {
        let tracks = (0..<8).map { Track(id: "t\($0)", position: .zero, embedding: [1, 0], sightings: 3, persistence: 0.5) }
        let r = Retriever.rank(query: [1, 0], phrase: "p", tracks: tracks.reversed())
        XCTAssertEqual(r.ranked.count, 5)
        XCTAssertEqual(r.ranked.map { $0.trackID }, ["t0", "t1", "t2", "t3", "t4"])
        XCTAssertEqual(r.log.scored.count, 8)
    }

    func testDimensionMismatchIsSkippedNotCrashed() {
        let bad = Track(id: "bad", position: .zero, embedding: [1, 0, 0], sightings: 3)
        let ok = Track(id: "ok", position: .zero, embedding: [1, 0], sightings: 3)
        let r = Retriever.rank(query: [1, 0], phrase: "p", tracks: [bad, ok])
        XCTAssertEqual(r.ranked.map { $0.trackID }, ["ok"])
        XCTAssertEqual(r.log.skippedIncomparable, ["bad"])
    }

    func testNoTracksGivesEmptyResult() throws {
        let enc = FakeTextEncoder(table: ["a": [1, 0], "a photo of a": [1, 0]])
        let r = try Retriever(encoder: enc).retrieve(phrase: "a", tracks: [])
        XCTAssertTrue(r.ranked.isEmpty)
        XCTAssertFalse(r.log.usedUnconfirmed)
    }
}
