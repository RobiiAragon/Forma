import Foundation
import RealityKit
import Darwin

/// A local, optional Mac companion for the original photographs exported by Forma.
@main
struct FormaReconstruct {
    static let usage = """
    Forma Reconstruct · fotogrametría local en Mac

    Uso:
      forma-reconstruct <carpeta-originales> <modelo.usdz> [opciones]

    Opciones:
      --detail reduced|medium|full|raw   Detalle solicitado; por defecto reduced.
      --overwrite                       Permite reemplazar el USDZ de destino.
      -h, --help                        Muestra esta ayuda.

    Ejemplo:
      forma-reconstruct ./Originales ./Objeto.usdz --detail full

    Descomprime primero el ZIP de fotografías exportado por Forma. Usa como entrada
    la carpeta que contiene las fotos originales y conserva sus archivos auxiliares.
    La salida debe quedar fuera de esa carpeta. No se modifican las fotografías.
    Requiere macOS 13 o posterior y un Mac compatible con PhotogrammetrySession.
    Se procesa en el Mac, sin red, cuenta, dependencias externas ni cuotas de la app.
    full/raw pueden usar más memoria y tiempo; el resultado depende de las fotos.
    Pulsa Control-C para cancelar el proceso.
    """

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            stdoutLine(usage)
            return
        }

        do {
            let options = try Options(arguments)
            guard #available(macOS 13.0, *) else {
                throw ToolError("Se requiere macOS 13 o posterior.", code: 69)
            }
            try await reconstruct(options)
        } catch let error as ToolError {
            stderrLine("Error: \(error.message)")
            if error.code == 64 { stderrLine("Consulta forma-reconstruct --help para ver el uso.") }
            exit(error.code)
        } catch {
            stderrLine("Error de reconstrucción: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    @available(macOS 13.0, *)
    static func reconstruct(_ options: Options) async throws {
        let manager = FileManager.default
        let input = options.input.resolvingSymlinksInPath().standardizedFileURL
        let output = options.output.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: input.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError("La entrada no es un directorio: \(input.path)", code: 66)
        }
        guard manager.isReadableFile(atPath: input.path) else {
            throw ToolError("No se puede leer la carpeta de originales: \(input.path)", code: 66)
        }
        guard output.pathExtension.lowercased() == "usdz" else {
            throw ToolError("La salida debe tener extensión .usdz.", code: 64)
        }
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        isDirectory = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError("La carpeta de destino no existe: \(parent.path)", code: 73)
        }
        guard manager.isWritableFile(atPath: parent.path) else {
            throw ToolError("No se puede escribir en la carpeta de destino: \(parent.path)", code: 73)
        }
        let destination = parent.appendingPathComponent(output.lastPathComponent)
        let inputPrefix = input.path.hasSuffix("/") ? input.path : input.path + "/"
        guard !destination.path.hasPrefix(inputPrefix), destination != input else {
            throw ToolError("Elige una salida fuera de los originales para conservar intacta esa carpeta.", code: 73)
        }
        try validateDestination(destination, overwrite: options.overwrite)
        guard PhotogrammetrySession.isSupported else {
            throw ToolError("Este Mac no admite PhotogrammetrySession. No se inició ningún proceso.", code: 69)
        }

        // Build next to the destination so publication stays on the same filesystem.
        // An existing model remains untouched if reconstruction fails or is cancelled.
        let working = parent.appendingPathComponent(".forma-reconstruct-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: working, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: working) }
        let staging = working.appendingPathComponent("Modelo.usdz")
        let session = try PhotogrammetrySession(input: input, configuration: .init())
        let request = PhotogrammetrySession.Request.modelFile(url: staging, detail: options.detail.apiValue)

        var interrupted = false
        let previousSignalHandler = signal(SIGINT, SIG_IGN)
        let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interruptSource.setEventHandler {
            Task { @MainActor in
                if !interrupted {
                    interrupted = true
                    stderrLine("Cancelando reconstrucción. Los originales se conservan.")
                    session.cancel()
                }
            }
        }
        interruptSource.resume()
        defer {
            interruptSource.cancel()
            signal(SIGINT, previousSignalHandler)
            session.cancel()
        }

        stdoutLine("Entrada: \(input.path)")
        stdoutLine("Salida: \(destination.path)")
        stdoutLine("Detalle solicitado: \(options.detail.rawValue) · proceso local")
        if #available(macOS 14.0, *) {
            let limits = PhotogrammetrySession.limits
            stdoutLine("Capacidad del motor en este Mac: hasta \(limits.maximumNumberOfInputImages) imágenes, dimensión máxima \(limits.maximumInputImageDimension) px.")
        }
        stdoutLine("Preparando fotografías…")

        var producedModel = false
        var lastPercent = -1
        var skipped = 0
        try session.process(requests: [request])
        for try await outputEvent in session.outputs {
            if #available(macOS 14.0, *), case .stitchingIncomplete = outputEvent {
                stderrLine("Aviso: algunas vistas no se unieron completamente. Revisa el resultado.")
            }
            switch outputEvent {
            case .inputComplete:
                stdoutLine("Imágenes cargadas. Reconstruyendo geometría y texturas…")
            case .requestProgress(_, let fraction):
                guard fraction.isFinite else { continue }
                let percent = Int(min(1, max(0, fraction)) * 100)
                if percent > lastPercent {
                    stdoutLine("Progreso: \(percent)%")
                    lastPercent = percent
                }
            case .requestComplete(_, let result):
                if case .modelFile(let url) = result {
                    let attributes = try manager.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else {
                        throw ToolError("El motor produjo un archivo vacío o inválido.")
                    }
                    producedModel = true
                }
            case .requestError(_, let error):
                if interrupted { throw ToolError("Proceso cancelado.", code: 130) }
                throw ToolError("No se pudo generar el modelo: \(error.localizedDescription)")
            case .invalidSample(let id, let reason):
                skipped += 1
                stderrLine("Aviso: imagen \(id) no válida: \(reason)")
            case .skippedSample(let id):
                skipped += 1
                stderrLine("Aviso: el motor omitió la imagen \(id).")
            case .automaticDownsampling:
                stderrLine("Aviso: el motor redujo imágenes para ajustarse a los recursos disponibles. Los originales no cambian.")
            case .processingCancelled:
                throw ToolError("Proceso cancelado; los originales y el modelo anterior se conservan.", code: 130)
            case .processingComplete:
                guard !interrupted else { throw ToolError("Proceso cancelado.", code: 130) }
                guard producedModel else { throw ToolError("El proceso terminó sin entregar un modelo USDZ.") }
                try publish(staging, to: destination, overwrite: options.overwrite)
                stdoutLine("Modelo guardado: \(destination.path)")
                if skipped > 0 { stdoutLine("Imágenes omitidas por el motor: \(skipped). Revisa el modelo antes de usarlo.") }
                stdoutLine("Los originales se conservan en: \(input.path)")
                return
            default:
                break
            }
        }
        if interrupted { throw ToolError("Proceso cancelado.", code: 130) }
        throw ToolError("El motor terminó sin confirmar una reconstrucción completa.")
    }

    static func validateDestination(_ destination: URL, overwrite: Bool) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else { return }
        let attributes = try manager.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ToolError("El destino existe y no es un archivo regular: \(destination.path)", code: 73)
        }
        guard overwrite else {
            throw ToolError("El destino ya existe. Elige otro nombre o usa --overwrite de forma explícita.", code: 73)
        }
    }

    static func publish(_ staging: URL, to destination: URL, overwrite: Bool) throws {
        let manager = FileManager.default
        // Check again: another process may have written this path during reconstruction.
        try validateDestination(destination, overwrite: overwrite)
        do {
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: destination)
            }
        } catch {
            throw ToolError("No se pudo guardar la salida: \(error.localizedDescription)", code: 73)
        }
    }

    static func stdoutLine(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func stderrLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    struct ToolError: Error {
        var message: String
        var code: Int32
        init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
    }

    struct Options {
        var input: URL
        var output: URL
        var detail: Detail = .reduced
        var overwrite = false

        init(_ arguments: [String]) throws {
            var positional: [String] = []
            var detailValue: Detail = .reduced
            var hasDetail = false
            var allowsOverwrite = false
            var endOptions = false
            var index = 0
            while index < arguments.count {
                let value = arguments[index]
                if endOptions {
                    positional.append(value)
                } else if value == "--" {
                    endOptions = true
                } else if value == "--detail" {
                    guard !hasDetail, index + 1 < arguments.count,
                          let parsed = Detail(rawValue: arguments[index + 1].lowercased()) else {
                        throw ToolError("Usa --detail reduced, medium, full o raw una sola vez.", code: 64)
                    }
                    detailValue = parsed
                    hasDetail = true
                    index += 1
                } else if value == "--overwrite" {
                    guard !allowsOverwrite else { throw ToolError("--overwrite se indicó más de una vez.", code: 64) }
                    allowsOverwrite = true
                } else if value.hasPrefix("-") {
                    throw ToolError("Opción desconocida: \(value)", code: 64)
                } else {
                    positional.append(value)
                }
                index += 1
            }
            guard positional.count == 2 else {
                throw ToolError("Indica una carpeta de originales y un archivo .usdz de salida.", code: 64)
            }
            input = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath, isDirectory: true)
            output = URL(fileURLWithPath: (positional[1] as NSString).expandingTildeInPath)
            detail = detailValue
            overwrite = allowsOverwrite
        }
    }

    enum Detail: String {
        case reduced, medium, full, raw

        @available(macOS 12.0, *)
        var apiValue: PhotogrammetrySession.Request.Detail {
            switch self {
            case .reduced: return .reduced
            case .medium: return .medium
            case .full: return .full
            case .raw: return .raw
            }
        }
    }
}
