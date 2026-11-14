import AppKit
import CryptoKit
import Foundation

@MainActor
final class LocalAIModelStore: ObservableObject {
    @Published private(set) var isInstalling = false
    @Published private(set) var status = ""
    @Published private(set) var modelURL: URL?
    private let directory: URL
    private let standardName = "RealESRGAN_general_522_fp16.mlpackage"
    private let archiveURL = URL(string: "https://github.com/hanxiao/real-esrgan-coreml/releases/download/v1.0.0/RealESRGAN_general_522_fp16.zip")!
    private let archiveHash = "41368af9dcbcc300c0fe0442202acbf98d30dc07c28d49bf656883f7fef3656a"
    private var installation: Task<Void, Never>?

    init(root: URL) {
        directory = root.appendingPathComponent("Models", isDirectory: true)
        let url = directory.appendingPathComponent(standardName, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { modelURL = url; status = "Real-ESRGAN local listo" }
        else { status = "Falta instalar el modelo local (descarga única de 2,3 MB)." }
    }

    func install() {
        guard !isInstalling else { return }
        isInstalling = true; status = "Descargando modelo de restauración…"
        installation = Task {
            defer { isInstalling = false; installation = nil }
            do {
                let (download, response) = try await URLSession.shared.download(from: archiveURL)
                defer { try? FileManager.default.removeItem(at: download) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw RGBDDatasetError.invalid("No se pudo descargar el modelo. Puedes reintentar.")
                }
                let expected = archiveHash, destination = directory, name = standardName
                status = "Verificando y guardando modelo local…"
                let installed = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let data = try Data(contentsOf: download)
                    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
                        throw RGBDDatasetError.invalid("La descarga no coincide con el modelo verificado.")
                    }
                    let fm = FileManager.default
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    let stage = destination.appendingPathComponent(".install-\(UUID().uuidString)")
                    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
                    defer { try? fm.removeItem(at: stage) }
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-x", "-k", download.path, stage.path]
                    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit()
                    try Task.checkCancellation()
                    guard process.terminationStatus == 0 else { throw RGBDDatasetError.invalid("No se pudo extraer el modelo.") }
                    let source = stage.appendingPathComponent(name)
                    guard fm.fileExists(atPath: source.appendingPathComponent("Manifest.json").path) else {
                        throw RGBDDatasetError.invalid("El paquete descargado no contiene el modelo esperado.")
                    }
                    let final = destination.appendingPathComponent(name)
                    if !fm.fileExists(atPath: final.path) { try fm.moveItem(at: source, to: final) }
                    return final
                }.value
                modelURL = installed; status = "Real-ESRGAN local listo · sin conexión para procesar"
            } catch { status = error.localizedDescription }
        }
    }
}
