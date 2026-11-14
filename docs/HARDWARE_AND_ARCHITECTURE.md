# Hardware, APIs y arquitectura de captura

Investigación realizada el 14 de octubre de 2026. Las especificaciones se contrastaron con Apple y las APIs con los headers e interfaces del SDK iOS 27 instalado. Las recomendaciones de ingeniería que siguen son propuestas; no son resultados de una prueba comparativa ni una promesa de precisión.

## iPhone 18 Pro: evidencia y uso práctico

La [ficha oficial de Apple](https://www.apple.com/iphone-18-pro/specs/) confirma A20 Pro, CPU de 6 núcleos, GPU de 7 núcleos y dos Neural Engine de 16 núcleos; LiDAR; cámaras traseras principal, ultra gran angular y teleobjetivo de 48 MP; principal de 24 mm con apertura variable ƒ/1.48, ƒ/1.8, ƒ/2.8 y ƒ/4; ultra gran angular de 13 mm; teleobjetivo de 100 mm; cámara frontal de 18 MP y TrueDepth. También confirma giroscopio, acelerómetro, barómetro, GPS de doble frecuencia, USB 3 hasta 10 Gb/s, Wi-Fi 7, capacidades de 256 GB a 2 TB, pantalla de 6.3 pulgadas con ProMotion e iOS 27.

El entorno local tiene Xcode 27.0, compilación 27A266a, y SDK iOS 27.0. El agente principal comprobó un dispositivo emparejado denominado «iPhone de Jesús», identificado por las herramientas como iPhone 18 Pro. Esto acredita un destino de ejecución disponible; no acredita haber probado todavía calidad, permisos, temperatura o autonomía de la app.

| Recurso | Aprovechamiento propuesto | Límite que hay que respetar |
| --- | --- | --- |
| LiDAR + cámaras + IMU | Escala métrica, seguimiento y malla de espacios mediante ARKit | La malla estimada no equivale a un instrumento calibrado de metrología |
| Cámara principal | Fotografías nítidas y consistentes para texturas/fotogrametría | Los megapíxeles de la ficha no describen la resolución de cada `ARFrame` |
| Apertura variable | Evaluar más profundidad de campo con iluminación suficiente | Consultar controles y valores admitidos por el formato activo; una abertura menor puede exigir más exposición |
| Ultra gran angular / teleobjetivo | Evaluar tomas especiales en una fase posterior | Cambiar de lente cambia calibración y puede interrumpir continuidad; no fusionar sin extrínsecos fiables |
| GPU / Neural Engine | Metal para profundidad, visualización y fusión; Core ML para modelos propios compatibles | No existe una opción pública que asigne automáticamente cualquier algoritmo al Neural Engine |
| USB y almacenamiento | Conservar fuentes y exportar a ordenador/disco autorizado | Velocidad real, espacio libre y acceso al destino se miden durante uso |
| IMU, GPS, barómetro | Orientación y contexto; registro geográfico optativo | GPS/barómetro no sustituyen mediciones locales ni corrigen por sí solos la deriva de ARKit |
| TrueDepth | Posible modalidad frontal de proximidad | Usa otra geometría y otra sesión; no asumir captura simultánea con LiDAR trasero |
| Pantalla, audio, hápticos | Instrucciones legibles, avisos de cobertura y captura accesible | Evitar renderizar a máxima frecuencia cuando no mejora la adquisición |

Apple no publica en esa ficha la RAM, densidad nativa del LiDAR, precisión métrica garantizada, presupuesto de memoria por app ni duración de batería escaneando. No se fijan estas cifras a partir de rumores. La capacidad se consulta en ejecución y la precisión se valida con referencias físicas.

## ARKit: qué entrega realmente

`ARWorldTrackingConfiguration` puede producir `ARMeshAnchor` al activar `.mesh` o `.meshWithClassification`, siempre tras `supportsSceneReconstruction`. Los vértices de cada ancla están en su sistema local: al exportar se aplica su `transform`, se respetan `offset`, `stride` y formato de índices, y se desplazan los índices al concatenar anclas. Reemplazar la geometría por identificador evita duplicar repetidamente la misma región. La detección de planos puede aplanar geometría; es útil en arquitectura y puede borrar irregularidades de objetos. [Ejemplo oficial de reconstrucción de escenas](https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene).

La profundidad y la malla son productos distintos. `ARFrame.sceneDepth` entrega profundidad de escena; `smoothedSceneDepth` añade suavizado temporal. `ARDepthData.depthMap` usa metros y `confidenceMap` expresa confianza por píxel. El mapa puede ser nulo y la reflexión/absorción de materiales afecta la confianza. No equivale a una desviación estándar en milímetros. [ARDepthData](https://developer.apple.com/documentation/arkit/ardepthdata), [confidenceMap](https://developer.apple.com/documentation/arkit/ardepthdata/confidencemap).

Cada frame también aporta imagen, timestamp y cámara: intrínsecos, resolución, pose y estado de seguimiento. Para una futura fusión RGB-D propia, hay que reescalar los intrínsecos a las dimensiones reales del mapa de profundidad, respetar el convenio de ejes de ARKit y la orientación de la imagen, rechazar profundidad no finita y verificar la reproyección con un objeto de dimensiones conocidas. Nunca convertir coordenadas de la vista recortada directamente a píxeles del sensor. [ARFrame](https://developer.apple.com/documentation/arkit/arframe), [ARCamera](https://developer.apple.com/documentation/arkit/arcamera).

La nube de puntos puede colorearse con RGB y filtrarse por confianza en GPU mediante Metal. Ampliar un mapa de profundidad mejora la presentación, pero los píxeles interpolados no son nuevas mediciones. La acumulación debe limitarse por presupuesto de memoria y descargarse a disco cuando crezca. [Ejemplo oficial de nube de puntos](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth).

No hay garantía pública de que el motor de reconstrucción de ARKit conserve todo el detalle del sensor. Para competir en fidelidad se necesita comparar la malla de ARKit con una fusión propia de profundidad y fotografías. La segunda requiere un trabajo sustancial adicional: filtrado de movimiento, fusión volumétrica/surfels, alineación, tratamiento de deriva y texturizado.

## Captura fotográfica y controles profesionales

En el SDK local, `ARConfiguration.configurableCaptureDeviceForPrimaryCamera` permite obtener la cámara usada por ARKit y ajustar controles compatibles desde iOS 16. Apple advierte que modificarla puede afectar al seguimiento. Usar `lockForConfiguration`, consultar soporte y no crear otra `AVCaptureSession` que compita por la misma cámara.

El SDK contiene `recommendedVideoFormatFor4KResolution`, `recommendedVideoFormatForHighResolutionFrameCapturing` y `ARSession.captureHighResolutionFrame`. Desde iOS 26 también contiene `ARVideoFormat.defaultPhotoSettings` y captura de frame con `AVCapturePhotoSettings`. Seleccionar y registrar resolución/FPS reales; la máxima resolución puede aumentar energía, memoria y tiempo por foto. [ARConfiguration](https://developer.apple.com/documentation/arkit/arconfiguration), [ARSession](https://developer.apple.com/documentation/arkit/arsession), [ARVideoFormat](https://developer.apple.com/documentation/arkit/arconfiguration/videoformat).

AVFoundation ofrece otra ruta: `builtInLiDARDepthCamera`, formato RGB compatible, `activeDepthDataFormat` y entrega sincronizada de vídeo/profundidad. Esta ruta no da por sí sola las poses de seguimiento de ARKit. Conservar calibración, timestamps y señales de frames descartados. [Captura de profundidad con LiDAR](https://developer.apple.com/documentation/avfoundation/capturing-depth-using-the-lidar-camera).

El header local de AVFoundation para iOS 27 añade `setExposureModeCustom(lensAperture:duration:iso:completionHandler:)`, `supportsExposureModeCustom(lensAperture:duration:iso:)` y, en el formato, `recommendedLensApertureStops`, `minLensAperture`, `maxLensAperture` y `defaultLensAperture`. Usar disponibilidad y soporte por formato. No suponer que una cámara virtual admita los controles de una cámara física. El header también advierte que ciertas capturas computacionales pueden alterar ISO/exposición bloqueados; para respetarlos exige priorizar velocidad de foto, con el correspondiente compromiso de calidad. [AVCaptureDevice](https://developer.apple.com/documentation/avfoundation/avcapturedevice).

Propuesta de experimentación: cámara principal estable, iluminación difusa, balance de blancos consistente y selección por nitidez/variación de pose, en vez de conservar cientos de imágenes prácticamente idénticas. Comparar exposición automática con parámetros controlados usando el resultado reconstruido; el ajuste más «manual» no garantiza el mejor modelo.

## Objetos: captura y reconstrucción local son dos fases

`ObjectCaptureSession` + `ObjectCaptureView` guían detección del objeto, captura, vueltas y posible volteo. El estado de sesión y su feedback permiten mostrar poca luz, distancia incorrecta, movimiento excesivo o pérdida del objeto. Esperar `.completed` antes de consumir las imágenes. Esta API captura datos; la reconstrucción se inicia por separado. Comprobar `ObjectCaptureSession.isSupported` y el permiso de cámara. [ObjectCaptureSession](https://developer.apple.com/documentation/realitykit/objectcapturesession).

`PhotogrammetrySession` está disponible desde iOS 17 y macOS 12, sujeta a `isSupported`. Procesa imágenes localmente, entrega progreso/errores como secuencia asíncrona y puede producir USDZ. La interfaz del SDK **iPhone** solo expone `.reduced` en `Request.Detail`; los ejemplos de Mac con `.full` no se deben copiar a iOS. Consultar `limits.maximumNumberOfInputImages` y `maximumInputImageDimension`; no inventar un máximo fijo. [PhotogrammetrySession](https://developer.apple.com/documentation/realitykit/photogrammetrysession), [límites del dispositivo](https://developer.apple.com/documentation/realitykit/photogrammetrysession/limits-swift.type.property).

La app no necesita cuenta, cuota comercial, servidor o compra para llamar a estas APIs. Eso no elimina los límites físicos de iOS. La opción `isOverCaptureEnabled` permite seguir tomando imágenes; Apple especifica que la reconstrucción local omite las que exceden su máximo y reserva esa opción principalmente para procesar luego en Mac. La app debe conservar fuentes y explicar ese comportamiento. [isOverCaptureEnabled](https://developer.apple.com/documentation/realitykit/objectcapturesession/configuration-swift.struct/isovercaptureenabled).

## Planos: RoomPlan

RoomPlan identifica estructura y componentes de interiores usando cámara, LiDAR y modelos de Apple. Produce una representación paramétrica, con paredes, aberturas y otros componentes; puede exportar USD. Es adecuado para una modalidad de planos y dimensiones y se verifica con `RoomCaptureSession.isSupported`. El resultado no es una malla fotorealista ni un levantamiento topográfico certificado. [RoomPlan](https://developer.apple.com/documentation/roomplan).

Las sesiones de habitación pueden conservarse y combinarse con `StructureBuilder` siguiendo el flujo de varias habitaciones de Apple. Mantener los datos paramétricos permite editar y exportar después. No obtener precisión superior añadiendo decimales a las etiquetas. [Combinar varias capturas](https://developer.apple.com/documentation/roomplan/merging-multiple-scans-into-a-single-structure).

TrueDepth tiene una API AVFoundation propia para profundidad frontal y visualización 2D/3D. Se evaluará como modalidad independiente, con privacidad y calibración propias; el simulador no acredita su funcionamiento físico. [Captura frontal de profundidad](https://developer.apple.com/documentation/avfoundation/streaming-depth-data-from-the-truedepth-camera).

## Rendimiento y almacenamiento

- Separar adquisición, procesamiento y UI. No retener una cola ilimitada de `ARFrame`; copiar solo los datos necesarios y usar buffers reutilizables.
- Usar Metal para procesamiento denso cuando exista una mejora medida. Consultar soporte GPU, formatos y memoria. `recommendedMaxWorkingSetSize` es una estimación de presupuesto, no permiso para agotar memoria. [Presupuesto de Metal](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize).
- Observar `ProcessInfo.thermalState` y sus notificaciones. Reducir trabajo con temperatura elevada, pausar ante estado crítico y mantener acceso a datos ya capturados. [Estado térmico](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property).
- Manejar avisos de memoria, espacio insuficiente, pérdida de cámara, paso a segundo plano y cancelación. El sistema no garantiza reconstrucción pesada indefinida en segundo plano. Guardar fuentes/checkpoints y permitir reanudar una fase de proceso.
- Escribir exportaciones de manera atómica y conservar los archivos fuente hasta que la biblioteca confirme su copia. Guardar manifiesto de modo, unidades, fecha, resolución y configuración. No presentar exportación exitosa si falta el modelo o tiene tamaño cero.

## Primera versión y evolución verificable

La primera versión compilable debe incluir tres rutas verdaderas y separadas: espacios con malla LiDAR; objetos con captura guiada y USDZ reconstruido en el dispositivo; planos con RoomPlan. Una biblioteca local y exportación utilizable completan el recorrido. La UI muestra soporte real y errores, sin porcentajes inventados de precisión/cobertura. Una demostración, si existe, se identifica inequívocamente y no se mezcla con capturas reales.

Las siguientes iteraciones deben priorizar preservar fuentes, inspección del modelo, recorte, mediciones con selección fiable, color/texturas, clasificación de cobertura por regiones y diagnóstico de calidad. Una visualización de «regiones observadas» no equivale al porcentaje completo de un objeto cuyo reverso se desconoce. Tras medir los cuellos de botella, evaluar fusión RGB-D propia y proceso Mac opcional para más detalle. Gaussian splatting/NeRF necesitan otro motor y otra representación; no están implementados por activar ARKit o fotogrametría.

Para demostrar una ventaja frente a Polycam se propone un ensayo reproducible, no una afirmación comercial: mismo iPhone, objeto/espacio, luz, recorrido y presupuesto de captura, tres repeticiones por app. Registrar versión/ajustes y comparar error de escala frente a distancias medidas, error de superficie frente a referencia cuando exista, agujeros, detalles finos, textura, deriva, tiempo total, tamaño del archivo, consumo de batería, temperatura y éxito de apertura/exportación. Usar objetos mates, texturados, negros, brillantes y transparentes; habitaciones con poca textura y varias estancias. Establecer criterios antes de ver resultados. El simulador valida interfaz y flujos de archivos; solo el teléfono real valida sensores, tracking, reconstrucción y rendimiento.

## Evidencia local del SDK

Rutas inspeccionadas (Xcode 27.0):

- `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk/System/Library/Frameworks/ARKit.framework/Headers/ARConfiguration.h`
- `…/ARKit.framework/Headers/ARFrame.h`, `ARSession.h`, `ARVideoFormat.h`
- `…/AVFoundation.framework/Headers/AVCaptureDevice.h`
- `…/RealityFoundation.framework/Modules/RealityFoundation.swiftmodule/arm64e-apple-ios.swiftinterface`
- `…/_RealityKit_SwiftUI.framework/Modules/_RealityKit_SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface`

La disponibilidad en un header no demuestra que todos los formatos de un dispositivo permitan una combinación concreta; la app debe verificarlo durante ejecución.
