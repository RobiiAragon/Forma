# Contrato de integración

App SwiftUI iOS 17+, Swift 5 language mode. Nombre Forma. Root gestiona proyecto, biblioteca, persistencia, exportadores, detalle y diseño visual.

Tipos compartidos en Forma/Core/ScanModels.swift: ScanMode (.lidar, .object, .room), MeshSnapshot(vertices: [SIMD3<Float>], triangles: [UInt32]), CaptureResult(mesh: MeshSnapshot?, modelURL: URL?, auxiliaryURLs: [URL] = [], mode: ScanMode, duration: TimeInterval, isDemo: Bool = false, note: String = ""). Los ficheros fuente URL deberán permanecer accesibles hasta que callback los copie.

Cada feature presenta pantalla autocontenida, oscura, español, con botón cerrar mediante @Environment dismiss, progreso, errores/capacidades honestas y callback onComplete: (CaptureResult) -> Void. Los callbacks se llaman MainActor. No acceder a Core/ScanStore desde features. No iniciar cámara sin que usuario abra la feature. Parar cámara al desaparecer/background. No escribir UI principal ni proyecto.

Pantallas: LiDARCaptureView(onComplete:), ObjectScanView(onComplete:), RoomScanView(onComplete:). Root añade features al proyecto mediante synchronized root group.

Color acento naranja RGB 1, 0.36, 0.18, fondo #101113, texto blanco/crema. No dependencias externas.
