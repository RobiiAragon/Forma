# Visor Mac: diagnóstico y verificación con Metal

15 de octubre de 2026. Estas pruebas usan snapshots Metal fuera de pantalla; la revisión de interacción y aspecto en la ventana de Forma se realiza por separado. Ninguna prueba reescribe modelos, capturas ni exportaciones originales.

## OBJ fotográfico: pantalla negra

El OBJ de la captura `28D5F554-465E-48FC-BEA0-BA9F3414C146` contiene 366,954 triángulos. SceneKit lo importaba como **104,714 elementos y referencias de material**, aunque solo existían **43 materiales distintos**. Cada cambio `usemtl` producía otro elemento.

La preparación de producción original generó **0 píxeles visibles** en un snapshot de 384×384. Continuó invisible al sustituir el color por blanco opaco, permitir doble cara, ampliar clipping a `1e-6…1e6`, sustituir todos los materiales por otros nuevos y recrear la geometría manteniendo sus elementos. Al combinar los mismos índices en un elemento, apareció la superficie. Esto identificó la fragmentación en elementos como causa del negro; las rutas relativas, la cámara, el alfa y el winding no explicaron esa reproducción.

`ImportedMeshBatching` agrupa elementos opacos por identidad del material, tipo de primitiva y ancho de índice. Conserva bytes de posiciones, normales y UV, propiedades de materiales y culling. Mantiene como barreras los polígonos, strips, rangos parciales y transparencia explícita; no concatena representaciones que cambien la topología. Los checkpoints se ejecutan entre elementos y bloques de índices, y los reemplazos se preparan antes de publicarlos en la escena. Las matrices de materiales/elementos de SceneKit se consultan una vez para evitar coste cuadrático al cruzar el puente Objective-C.

La producción corregida prepara **43 elementos/43 materiales, los mismos 366,954 triángulos**, y produce **6,824 píxeles visibles con fotografía y culling trasero**, frente a los 0 anteriores. Repetir el batching mantiene 43 elementos y los hashes UV idénticos. La preparación completa, que incluye miniaturas e importación del OBJ, tardó 15.50 s en esta prueba; no es un benchmark de FPS de la ventana.

Un fixture independiente mostró además que el MTL importado puede aportar emisión blanca: con iluminación `.constant` saturaba las fotografías. Neutralizar esa emisión recuperó los colores sin cambiar cámara, UV ni alfa. Resolver las rutas relativas a URL absolutas sigue siendo apropiado para proxies desechables, aunque el fixture pequeño conservaba su resolución interna de ruta y esa corrección por sí sola no reprodujo el negro del modelo real.

`Tools/verify_imported_mesh_batching.swift`: **7 comprobaciones correctas**. Verifica índices exactos por material, identidad de materiales con el mismo nombre, SHA-256 de vertex/normal/UV, caras y culling; barreras polygon/strip/rangos; primitivas y anchos de índice; transparencia explícita; cancelación sin publicación parcial; instancias compartidas; y 104,714 runs sintéticos reducidos a dos batches sin perder caras ni bytes. Este último caso tardó 0.056 s.

```sh
xcrun swiftc -O -parse-as-library Forma/Core/ImportedMeshBatching.swift \
  Tools/verify_imported_mesh_batching.swift -o /tmp/forma-imported-batching-verify
/tmp/forma-imported-batching-verify
```

Evidencia local: `/tmp/forma-production-preview-adaptive-recreated.log`, `/tmp/forma-production-preview-final-batching.log`, `/tmp/forma-production-preview-diagnosis/adaptive-batched-photographs.png` y `/tmp/forma-imported-batching-tests.log`.

## Raw USDZ: geometría, fotografía y zoom óptico

Se verificó `DesktopUSDZPreview` junto con `DesktopModelViewer.Coordinator.prepare` de producción usando el Raw `9D475662-CF01-40E1-AD0A-F556E9004F8A/modelo.usdz`:

| Comprobación | Geometría | Adaptativa |
| --- | ---: | ---: |
| Vértices | 1,614,034 | 1,614,034 |
| Triángulos | 3,227,473 | 3,227,473 |
| Elementos/materiales | 4/4 | 4/4 |
| Píxeles visibles iniciales, 384×384 | 6,709 | 6,751 |
| Píxeles visibles con zoom óptico anclado a superficie, FOV 1° | 147,456 | 140,498 |

Los hashes de geometría y UV coinciden entre ambos modos. Todos los materiales conservan culling trasero y `isDoubleSided = false`. El zoom usa la política real de cámara con desplazamiento del ancla, near/far positivos y finitos; no atraviesa la superficie seleccionada por dolly en esta prueba.

Las cuatro imágenes fuente son PNG RGB8 de 8192×8192 embebidas como referencias NSURL con `offset/size` dentro del USDZ. El proxy obtiene cuatro **CGImage de 3547×3547**, 50,324,836 píxeles en total: aproximadamente **268,399,125 bytes RGBA8 con mipmaps completos**, dentro del presupuesto estimado de 256 MiB para texturas de pantalla. Esto no mide asignaciones finales del driver ni incluye geometría y memoria temporal del importador.

AppKit anunciaba representaciones NSImage de 7094×7094 para ese CGImage de 3547×3547. Una microprueba confirmó que eran metadatos de representación Retina; `NSImage.cgImage` seguía devolviendo 3547×3547. Asignar directamente el CGImage a `material.diffuse.contents` produjo un snapshot **idéntico píxel por píxel** al NSImage: delta máximo 0 y 0 canales cambiados. El helper usa CGImage directo para conservar dimensiones explícitas y evitar selección ambigua de representación.

El Raw original mantuvo SHA-256 **`9a756eef0981c5273b7ad49d29aa66f7e0285e68a6da9a59f1fbfe94d9a5e920`** antes y después. Las miniaturas pertenecen exclusivamente al visor; los PNG embebidos y el USDZ de exportación conservan sus bytes.

Evidencia local: `/tmp/forma-verify-raw-production.log`, `/tmp/forma-verify-raw-cgimage-comparison.log`, `/tmp/forma-thumbnail-scale-probe.log` y `/tmp/forma-raw-production-verification/`. Estos resultados no establecen FPS interactivos, superioridad sobre Polycam ni validación de toda posición posible de cámara.
