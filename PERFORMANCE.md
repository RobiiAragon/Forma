# Rendimiento de Forma — 20 de octubre de 2026

Versión **0.9.5 (22)**, mismos bundle IDs, instalada en iPhone sobre 0.9.4 (21). La revisión de rendimiento se midió sin operar el teléfono; la instalación y apertura física fueron una comprobación posterior. No se abrió cámara ni se inició captura, reconstrucción o entrenamiento.

## Cambios cerrados

1. **Reapertura de previsualización OBJ ligera (iOS):** `TexturePreviewProxy` evita releer/dividir todo el OBJ y reabrir las imágenes cuando ya existe un resultado válido en el proceso. Retiene exclusivamente URLs, dimensiones y firmas de archivos, no texto de malla ni imágenes decodificadas. `NSCache` puede desalojar entradas; las 64 entradas de metadatos no limitan capturas, fotografías ni exportaciones.
2. **Inventario OBJ del visor Mac:** `loadIfPresent` detecta e inventaría materiales en una sola lectura/pasada. El visor antes leía el OBJ para buscar `mtllib` y lo volvía a leer dentro del inventario. Se conserva la validación de rutas, MTL y texturas; el resto de la importación/renderizado sigue igual.
3. **Biblioteca:** el lector periódico de entrenamientos solo trabaja cuando la biblioteca está activa y sin navegación/modal superpuesta. Al cancelarse la tarea de vista se cancela su lector y se descartan sus resultados; el lector comprueba cancelación entre registros. Esto no pausa ni detiene entrenadores. La comparación de sesiones usa todos sus campos persistidos, no solo ID ni una selección de etiquetas interpoladas.

No se cambiaron motores, fotos, densidad, triángulos, presupuestos de calidad, texturizado final, formatos, apariencia aprobada o controles térmicos. El modo de textura original sigue importando directamente. La textura ligera conserva exactamente la escala/presupuesto que tenía antes.

## Baseline y método

- Equipo de medición: **Mac Apple M5 Max, 48 GiB**, macOS 27.0.1, Xcode 27.1 (27A9275). Swift compilado con `-O`, ejecución nativa en Mac.
- Fixture propia generada por `Tools/benchmark_preview_reuse.swift`: cuadrícula OBJ de **14,935,265 bytes**, 129.600 vértices/UV, 257.762 triángulos, una MTL y PNG de 1024×1024. No proviene de capturas/documentos del usuario.
- Antes de editar la optimización se congeló el código y se midieron siete reaperturas del preparador original. Esa primera mediana fue 153,263 ms. La variante Mac también tuvo baseline previo al cambio.
- Comparación final: **7 muestras por variante**, orden A/B y B/A alternado, mismas entradas/configuración y caché de disco caliente. En el preparador, el presupuesto es 16.384 bytes y ambas variantes producen la misma copia de 32×32; la fuente permanece de 1024×1024.
- Baselines congelados en `Tools/PerformanceBaselines`; solo se instrumentan las llamadas reales a lectura/imagen y se redirige su caché a la carpeta de fixture. El baseline Mac incluye la comprobación previa de `mtllib` del antiguo visor.
- No se capturaron procesos ajenos. Hubo actividad de compilación propia y potencial carga de otros proyectos en el Mac. Se repitió el registro final después de terminar nuestros builds; no se controló el resto del sistema. Las lecturas/outputs son la evidencia determinista; los tiempos no son una promesa.

## Resultados finales de las etapas medidas

| Etapa (Mac nativo) | Baseline: mediana ms [mín, máx] | Después: mediana ms [mín, máx] | Operaciones observadas |
|---|---:|---:|---|
| Preparador de proxy ya reutilizable | 155.456 [149.946, 163.731] | 0.059 [0.048, 0.170] | Antes: 1 lectura OBJ + 1 MTL + 1 apertura de metadatos de imagen. Después: 0 de esas lecturas, 3 consultas de identidad de fuentes + 1 comprobación de salida y acierto de caché. |
| Inventario usado por el visor Mac | 298.834 [257.979, 514.609] | 153.000 [141.020, 1292.466] | Lecturas completas OBJ: 2 → 1. MTL: 1 → 1. Aperturas de metadatos de imagen: 1 → 1. |

**No son mediciones de velocidad total del visor, escaneo, fotogrametría o entrenamiento.** La carga de SceneKit, GPU y renderizado no se incluye. El primer recorrido frío todavía lee y prepara el modelo completo; esta caché optimiza reaperturas. El componente iOS se midió como código nativo en Mac, no en iPhone. Se registra RSS máximo del proceso A/B completo en JSON; mezcla ambas variantes y no sirve para afirmar ahorro de memoria de la candidata.

## Corrección e invalidación

- Todas las muestras A/B del preparador tienen SHA-256 idénticos para `preview.obj`, `preview.mtl` y `preview-0.png`. SHA de fuente sin cambios: `75bf8055807602269a5e7e6c2ca44dba31715f2b7c5be460d0df86ad8509c7bc`. Los inventarios A/B conservan rutas, dimensiones y asociaciones de material.
- La reutilización verifica OBJ, MTL y mapas difusos referenciados mediante dispositivo/inodo/tamaño/mtime/ctime con nanosegundos. La clave mantiene identidad de URL y directorio de caché y exige la misma escala efectiva del presupuesto actual. No se cachean fallos ni dependencias incompletas.
- La clave persistente de texturas también incluye identidad y ctime: sobrescribir una imagen con igual tamaño y mtime ya no permite recuperar la copia anterior de disco.
- Regresiones con fuentes propias: OBJ sustituido atómicamente en la misma ruta conservando mtime; MTL cambiada; transformación de mapa no soportada que vuelve al importador original; BMP sobrescrito con igual tamaño/mtime y otros píxeles; presupuestos y directorios de caché distintos; dependencia eliminada/restaurada y cancelación. El cuerpo geométrico/UV del proxy permanece idéntico al original salvo la referencia MTL.
- Las validaciones antiguas del inventario estricto permanecen: sin biblioteca devuelve error en `load`, ausencia se admite solo en la nueva variante opcional; bibliotecas múltiples o texturas faltantes siguen dando error.

## Builds y pruebas

- Release **iOS genérico sin firma**: aprobado, `build/Performance-20261020/Derived-iOS/Build/Products/Release-iphoneos/Forma.app`.
- Release **Mac arm64 nativo sin firma**: aprobado, `build/Performance-20261020/Derived-Mac/Build/Products/Release/FormaDesktop.app`.
- Release **iOS genérico firmado para desarrollo**: aprobado, `build/Delivery/Derived-Signed-iOS/Build/Products/Release-iphoneos/Forma.app`. `codesign --verify --strict --deep` pasó. App `com.robii.forma` y extensión `com.robii.forma.LiveActivity`, versión 0.9.5 (22), equipo `9X76Y99YGD`. Reutilizó perfiles locales existentes, sin solicitar renovación. Perfil principal válido hasta **22 oct 2026 20:23:53 UTC**; extensión hasta **22 oct 2026 17:36:37 UTC**. Es una compilación de desarrollo preparada, no una instalación ni un archivo de distribución App Store.
- Copia transportable de esa compilación: `build/Delivery/Forma-0.9.5-build22-signed-iOS-development.zip`. Se extrajo con `ditto` y la app extraída volvió a pasar la verificación estricta de firma. Este ZIP firmado contiene perfiles de desarrollo y se mantiene separado del ZIP de fuentes.
- Instalación física sobre `com.robii.forma` 0.9.4 (21): `devicectl` confirmó 0.9.5 (22), apertura normal y proceso principal activo. Las 18 rutas de `Documents/Forma` mantuvieron tamaño y fecha; los diez JSON de metadatos conservaron SHA-256. `Documents/FormaTraining` estaba vacío. Esta verificación no mide latencia, temperatura ni calidad del visor en el teléfono. Registro privado `build/Delivery/iPhone-0.9.5-build22/`.
- Build/pruebas de simulador iOS 27.0 en dispositivo temporal propio: **15 aprobadas, 0 fallidas, 0 omitidas**. Incluye siete casos nuevos de reutilización/inventario y regresiones del importador, recuperación y conservación de fuentes. No se repitieron baterías de entrenamiento ni reconstrucciones reales.
- Resultado completo: `build/Performance-20261020/Regression-Delivery.xcresult`. Resumen portable: `docs/performance/2026-10-20/tests.json`.
- Los primeros intentos señalaron artefactos generados ausentes en sus rutas. Se repusieron desde copias locales que coincidían con hashes ya registrados (incluidos shaders/worker/archivo nativo) y se restauró la licencia Apache existente. Ambos verificadores originales vuelven a pasar; no se cambiaron manifiestos para aceptar binarios distintos ni se modificó el motor.
- Skill utilizada: [SwiftUI Expert](~/.codex/skills/swiftui-expert-skill/SKILL.md), AvdLee/SwiftUI-Agent-Skill, MIT, referencia facilitada `204dba7c67256a8b707ee3fbc5759a824191974f`. Se siguieron rendimiento/estado/imágenes/listas y consulta acotada de APIs; no se hizo una migración masiva a Observation.

## Reproducción y entrega

```sh
bash scripts/benchmark_previews.sh
```

Genera solo fixture propia bajo `build/PreviewBenchmark-Reproduction`, ejecuta los dos comparadores intercalados y verifica igualdad de outputs. No abre apps ni usa dispositivos. JSON de esta medición en `docs/performance/2026-10-20/`.

ZIP de fuentes y proyecto: `build/Delivery/Forma-0.9.5-build22-sources.zip`. Incluye `ASO.md`, documentación, baselines, script de medición, pruebas y recursos de app existentes. Excluye datos de usuario, fixtures generadas, bibliotecas de capturas, derivados grandes, certificados/perfiles, toolchains y DerivedData. Para compilar desde el ZIP hay que generar artefactos nativos con los scripts existentes y disponer de las herramientas de desarrollo; el ZIP de fuentes no es un instalador ni contiene el build firmado.

## Límites y pendientes

Validar en iPhone físico la latencia percibida, memoria/GPU/temperatura y lectura APFS durante reaperturas de capturas grandes. Validar en Mac la interacción completa del visor y los distintos modelos del usuario cuando se autorice ese turno. No se han medido estos efectos ni se han iniciado escaneos/entrenamientos privados. Los shaders, precisión física y calidad geométrica no se evaluaron como parte de esta optimización.

La candidata iOS quedó instalada sin desinstalar, cambiar bundle ID ni renovar certificados/perfiles. La candidata Mac sigue sin instalar. No hay certificación de App Store ni afirmación de superioridad sobre otros productos.
