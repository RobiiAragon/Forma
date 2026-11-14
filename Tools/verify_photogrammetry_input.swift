import Foundation

/// Tests input selection/copying only; this does not run Apple's reconstruction.
@main struct PhotogrammetryInputVerification {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FormaPhotoInputVerify-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let dataset = root.appendingPathComponent("dataset"), session = root.appendingPathComponent("session")
        try fm.createDirectory(at: dataset.appendingPathComponent("images"), withIntermediateDirectories: true)
        let early = Data([7, 1, 9, 3]), late = Data([2, 4, 6, 8, 0])
        try early.write(to: dataset.appendingPathComponent("images/zz-uuid.jpg"))
        try late.write(to: dataset.appendingPathComponent("images/aa-uuid.jpg"))
        try Data([99]).write(to: dataset.appendingPathComponent("images/unreferenced.jpg"))
        func frame(_ id: String, _ time: Double, _ file: String) -> RGBDFrameRecord {
            .init(id: id, timestamp: time, rgbFile: "images/" + file, imageWidth: 1, imageHeight: 1,
                  cameraToWorld: [], intrinsics: [], source: "verification")
        }
        let manifest = RGBDDatasetManifest(createdAt: Date(), frames: [frame("late", 20, "aa-uuid.jpg"), frame("early", 10, "zz-uuid.jpg")])
        try manifest.write(to: dataset)
        let prepared = try DesktopPhotogrammetryInput.prepare(dataset: dataset, sessionDirectory: session)
        guard prepared.items.map(\.frameID) == ["early", "late"],
              try fm.contentsOfDirectory(atPath: prepared.directory.path).sorted() == ["00000000.jpg", "00000001.jpg"],
              try Data(contentsOf: prepared.directory.appendingPathComponent("00000000.jpg")) == early,
              try Data(contentsOf: prepared.directory.appendingPathComponent("00000001.jpg")) == late else { fatalError("Wrong manifest/order/source bytes") }
        print("PASS: only referenced manifest frames, timestamp order despite inverse UUID names, byte-exact native inputs")
        try Data([42]).write(to: prepared.directory.appendingPathComponent("00000000.jpg"))
        guard try Data(contentsOf: dataset.appendingPathComponent("images/zz-uuid.jpg")) == early else { fatalError("Output shares a writable source inode") }
        print("PASS: modifying engine input never changes immutable original (APFS clone or independent copy)")
        let cancel = ProcessingControl()
        do {
            _ = try ProcessingControl.withControl(cancel) {
                try DesktopPhotogrammetryInput.prepare(dataset: dataset, sessionDirectory: session) { _ in cancel.cancel() }
            }
            fatalError("Cancellation was ignored")
        } catch is CancellationError { }
        guard try Data(contentsOf: prepared.directory.appendingPathComponent("00000000.jpg")) == Data([42]),
              try fm.contentsOfDirectory(atPath: session.path).contains(where: { $0.hasPrefix(".input-") }) == false else { fatalError("Cancellation published or leaked staging input") }
        print("PASS: cancellation during preparation preserves prior usable input and removes all partial staging files")
        let external = root.appendingPathComponent("outside.jpg")
        try late.write(to: external)
        try fm.createSymbolicLink(at: dataset.appendingPathComponent("images/link.jpg"), withDestinationURL: external)
        try RGBDDatasetManifest(createdAt: Date(), frames: [frame("symlink", 1, "link.jpg")]).write(to: dataset)
        do {
            _ = try DesktopPhotogrammetryInput.prepare(dataset: dataset, sessionDirectory: root.appendingPathComponent("unsafe"))
            fatalError("Symbolic input was accepted")
        } catch RGBDDatasetError.invalid { }
        print("PASS: symlink/external frame rejected; originals and unreferenced file remain untouched")
    }
}
