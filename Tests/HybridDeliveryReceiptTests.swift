import XCTest
@testable import Forma

final class HybridDeliveryReceiptTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HybridReceiptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private func receiptURL(_ receipt: HybridDeliveryReceipt, in directory: URL) throws -> URL {
        directory.appendingPathComponent(try HybridDeliveryReceipt.key(scanID: receipt.scanID, request: receipt.processingRequest) + ".json")
    }
    private func fixture() -> HybridDeliveryReceipt {
        let job = UUID()
        return HybridDeliveryReceipt(scanID: UUID(), processingRequest: .init(kind: .gaussian, iterations: 5000, downscale: 1),
            jobID: job, acknowledgedAt: Date(timeIntervalSince1970: 100),
            lastStatus: .init(id: job, state: "running", progress: 0.25, iteration: 1250, targetIterations: 5000, splats: 425928, resultAvailable: false))
    }

    func testConfigurationKeysAreStableDistinctAndAcceptNativeMaximum() throws {
        let scan = UUID()
        let requests: [HybridTransfer.ProcessingRequest?] = [nil, .init(kind: .lidar), .init(kind: .gaussian),
            .init(kind: .gaussian, iterations: 3000, downscale: 1), .init(kind: .gaussian, iterations: 3001, downscale: 1),
            .init(kind: .gaussian, iterations: 3000, downscale: 2), .init(kind: .gaussian, iterations: Int(Int32.max), downscale: 1)]
        let keys = try requests.map { try HybridDeliveryReceipt.key(scanID: scan, request: $0) }
        XCTAssertEqual(Set(keys).count, requests.count)
        for (request, key) in zip(requests, keys) {
            XCTAssertEqual(try HybridDeliveryReceipt.key(scanID: scan, request: request), key)
            XCTAssertTrue(key.hasPrefix(scan.uuidString + "-"))
            XCTAssertFalse(key.contains("/"))
            XCTAssertNotEqual(try HybridDeliveryReceipt.key(scanID: UUID(), request: request), key)
        }
    }

    func testRoundTripAndReplacementPreserveAcknowledgementAndValidatedStatus() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var value = fixture()
        try value.save(in: directory)
        let first = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: value.scanID, request: value.processingRequest, in: directory))
        XCTAssertEqual(first.scanID, value.scanID); XCTAssertEqual(first.processingRequest, value.processingRequest)
        XCTAssertEqual(first.jobID, value.jobID); XCTAssertEqual(first.acknowledgedAt, value.acknowledgedAt)
        XCTAssertEqual(first.lastStatus, value.lastStatus)
        value.lastStatus = .init(id: value.jobID, state: "completed", progress: 1, iteration: 5000, targetIterations: 5000, splats: 430000, resultAvailable: true)
        try value.save(in: directory)
        let completed = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: value.scanID, request: value.processingRequest, in: directory))
        XCTAssertEqual(completed.lastStatus, value.lastStatus)
        XCTAssertEqual(completed.acknowledgedAt, first.acknowledgedAt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        let serialized = try String(contentsOf: receiptURL(value, in: directory), encoding: .utf8)
        XCTAssertFalse(serialized.contains("pairingCode"), "Pairing secrets must remain outside the receipt ledger")
    }

    func testMissingReceiptDoesNotCreateStorageOrInventAcknowledgement() throws {
        let parent = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: parent) }
        let absent = parent.appendingPathComponent("not-created")
        XCTAssertNil(try HybridDeliveryReceipt.load(scanID: UUID(), request: nil, in: absent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testHistoricalReceiptWithoutObservationDateDecodesAndCanBeUpdated() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        var value = fixture(); try value.save(in: directory)
        let url = try receiptURL(value, in: directory)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        legacy.removeValue(forKey: "statusObservedAt")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url, options: .atomic)
        let loaded = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: value.scanID, request: value.processingRequest, in: directory))
        XCTAssertNil(loaded.statusObservedAt)
        XCTAssertEqual(loaded.lastStatus, value.lastStatus)
        XCTAssertEqual(loaded.acknowledgedAt, value.acknowledgedAt)
        value.statusObservedAt = Date(timeIntervalSince1970: 200)
        try value.save(in: directory)
        let updated = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: value.scanID, request: value.processingRequest, in: directory))
        XCTAssertEqual(updated.statusObservedAt, value.statusObservedAt)
        XCTAssertEqual(updated.acknowledgedAt, loaded.acknowledgedAt)
    }

    func testLoadRejectsMismatchedCaptureOrConfigurationWithoutDeletingEvidence() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = fixture(); try value.save(in: directory)
        let url = try receiptURL(value, in: directory), original = try Data(contentsOf: url)
        for wrongCapture in [true, false] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            if wrongCapture { object["scanID"] = UUID().uuidString }
            else { object["processingRequest"] = ["kind": "gaussian", "iterations": 5001, "downscale": 1] }
            let corrupt = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            try corrupt.write(to: url, options: .atomic)
            XCTAssertThrowsError(try HybridDeliveryReceipt.load(scanID: value.scanID, request: value.processingRequest, in: directory))
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    func testMalformedUUIDAndTruncatedJSONAreReportedAndPreserved() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = fixture(); try value.save(in: directory)
        let url = try receiptURL(value, in: directory), original = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["jobID"] = "not-a-uuid"
        for corrupt in [try JSONSerialization.data(withJSONObject: object), Data(original.prefix(original.count / 2))] {
            try corrupt.write(to: url, options: .atomic)
            XCTAssertThrowsError(try HybridDeliveryReceipt.load(scanID: value.scanID, request: value.processingRequest, in: directory))
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    func testInvalidStatusOrDateCannotOverwritePreviousValidReceipt() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = fixture(); try value.save(in: directory)
        let url = try receiptURL(value, in: directory), original = try Data(contentsOf: url)
        let invalid: [HybridTransfer.RemoteJobStatus] = [
            .init(id: UUID(), state: "running", progress: 0.2, resultAvailable: false),
            .init(id: value.jobID, state: "", progress: 0.2, resultAvailable: false),
            .init(id: value.jobID, state: "running", progress: -0.1, resultAvailable: false),
            .init(id: value.jobID, state: "running", progress: 1.1, resultAvailable: false),
            .init(id: value.jobID, state: "running", progress: .nan, resultAvailable: false),
            .init(id: value.jobID, state: "running", progress: 0.2, iteration: -1, resultAvailable: false),
            .init(id: value.jobID, state: "running", progress: 0.2, targetIterations: 0, resultAvailable: false),
            .init(id: value.jobID, state: "running", progress: 0.2, splats: -1, resultAvailable: false)
        ]
        for status in invalid {
            var modified = value; modified.lastStatus = status
            XCTAssertThrowsError(try modified.save(in: directory))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        var invalidDate = value
        invalidDate.acknowledgedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try invalidDate.save(in: directory))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLoadValidatesStatusIdentityAndProgressAfterDecoding() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = fixture(); try value.save(in: directory)
        let url = try receiptURL(value, in: directory), original = try Data(contentsOf: url)
        for wrongIdentity in [true, false] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var status = try XCTUnwrap(object["lastStatus"] as? [String: Any])
            if wrongIdentity { status["id"] = UUID().uuidString } else { status["progress"] = 1.5 }
            object["lastStatus"] = status
            let corrupt = try JSONSerialization.data(withJSONObject: object)
            try corrupt.write(to: url, options: .atomic)
            XCTAssertThrowsError(try HybridDeliveryReceipt.load(scanID: value.scanID, request: value.processingRequest, in: directory))
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    func testInvalidConfigurationIsRejectedConsistentlyByKeyLoadAndSave() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let value = fixture(); try value.save(in: directory)
        let url = try receiptURL(value, in: directory), original = try Data(contentsOf: url)
        for request in [HybridTransfer.ProcessingRequest(kind: .gaussian, iterations: 0),
                        .init(kind: .gaussian, iterations: Int(Int32.max) + 1),
                        .init(kind: .gaussian, downscale: 0.5), .init(kind: .gaussian, downscale: .infinity)] {
            XCTAssertThrowsError(try HybridDeliveryReceipt.key(scanID: value.scanID, request: request))
            XCTAssertThrowsError(try HybridDeliveryReceipt.load(scanID: value.scanID, request: request, in: directory))
            var invalid = value; invalid.processingRequest = request
            XCTAssertThrowsError(try invalid.save(in: directory))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testIndependentReceiptsHaveNoJobOrConfigurationCountQuota() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let scan = UUID()
        for iteration in 1...257 {
            let value = HybridDeliveryReceipt(scanID: scan, processingRequest: .init(kind: .gaussian, iterations: iteration, downscale: 1),
                jobID: UUID(), acknowledgedAt: Date(timeIntervalSince1970: Double(iteration)))
            try value.save(in: directory)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 257)
        for iteration in [1, 129, 257] {
            let value = try XCTUnwrap(HybridDeliveryReceipt.load(scanID: scan,
                request: .init(kind: .gaussian, iterations: iteration, downscale: 1), in: directory))
            XCTAssertEqual(value.processingRequest?.iterations, iteration)
            XCTAssertEqual(value.acknowledgedAt.timeIntervalSince1970, Double(iteration))
        }
    }

    private final class ReadFailures: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [String] = []
        func append(_ error: String) { lock.lock(); errors.append(error); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    }
    func testConcurrentReadersNeverObservePartiallyReplacedReceipt() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let initial = fixture(); try initial.save(in: directory)
        let scanID = initial.scanID, request = initial.processingRequest, jobID = initial.jobID
        let failures = ReadFailures(), readers = DispatchGroup()
        readers.enter()
        DispatchQueue(label: "com.forma.tests.receipt-reader").async {
            defer { readers.leave() }
            for _ in 0..<200 {
                do {
                    guard let loaded = try HybridDeliveryReceipt.load(scanID: scanID, request: request, in: directory), loaded.jobID == jobID else {
                        failures.append("A committed receipt disappeared or changed identity"); continue
                    }
                } catch { failures.append(error.localizedDescription) }
            }
        }
        for step in 0..<100 {
            var updated = initial
            updated.lastStatus?.progress = Double(step) / 100
            try updated.save(in: directory)
        }
        XCTAssertEqual(readers.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(failures.snapshot.isEmpty, failures.snapshot.joined(separator: "; "))
    }
}
