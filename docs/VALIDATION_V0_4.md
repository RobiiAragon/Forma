# Validación de Forma 0.4

Registro del 15 de octubre de 2026. Se distinguen pruebas sintéticas, procesamiento del OBJ real proporcionado por el usuario y ejecución de pruebas en simulador e iPhone. **Estos resultados no demuestran mayor precisión física, mejor FPS ni superioridad frente a Polycam.** La comparación anterior de las dos capturas conserva su alcance original; no se ha sustituido por datos sintéticos.

## Pruebas ejecutadas

| Entorno y alcance | Aprobadas | Omitidas | Fallos |
| --- | ---: | ---: | ---: |
| Mac: fotometría, texturizado LiDAR y atlas | 34 | 0 | 0 |
| Mac: continuidad geométrica | 8 | 0 | 0 |
| Simulador: pruebas unitarias tras corrección de integridad | 86 | 2 | 0 |
| Simulador: interfaz | 2 | 0 | 0 |
| Simulador: regresión focalizada de integridad y alias de ruta | 2 | 0 | 0 |
| iPhone físico: selección final de pruebas unitarias | 87 | 0 | 0 |

Las 88 pruebas unitarias de la tanda final del simulador incluyen dos omisiones explícitas: el entrenamiento Metal nativo y la captura real RGB-D requieren hardware físico. Las dos pruebas de interfaz aprobaron en la tanda anterior; después sólo cambió la integridad de archivos, sin cambios de código UI. Las 86 aprobaciones unitarias y las dos de interfaz son ejecuciones separadas, no 90 aprobaciones. La regresión focalizada vuelve a ejecutar dos casos de la suite, por lo que no se suma como pruebas únicas.

La selección física terminó con `TEST EXECUTE SUCCEEDED` y código de salida 0, confirmado por quien ejecutó el proceso. Incluye entrenamiento/renderizado Metal con datos sintéticos; no incluye la prueba de captura en vivo del sensor ni valida una nueva sala. Las pruebas no prueban por sí solas que la compilación final haya sido instalada o utilizada para escanear.

La compilación normal posterior y su instalación en el iPhone también se completaron, según confirmación de quien las ejecutó. Esa instalación no sustituye una medición de calidad sobre una nueva captura real.

Evidencias locales preservadas: [resumen y hashes](../build/Research/validation-v0.4/summary.json), [Mac: 34 casos](../build/Research/validation-v0.4/mac-textures-34.log), [Mac: ocho casos de continuidad](../build/Research/validation-v0.4/mac-continuity-8.log), [simulador: unitarias finales](../build/Research/validation-v0.4/simulator-integrity-final.log), [simulador: UI](../build/Research/validation-v0.4/simulator-final.log), [regresión de integridad](../build/Research/validation-v0.4/integrity-alias-2.log) e [iPhone físico final](../build/Research/validation-v0.4/device-integrity-final.log). Los paquetes completos permanecen en [FormaV4SimulatorIntegrityFinal.xcresult](../build/FormaV4SimulatorIntegrityFinal.xcresult), [FormaV4SimulatorFinal.xcresult](../build/FormaV4SimulatorFinal.xcresult) y [FormaV4DeviceIntegrityFinal.xcresult](../build/FormaV4DeviceIntegrityFinal.xcresult).

## Prueba sintética de exposición

Dos imágenes **creadas para la prueba**, cada una de 1000 × 1000 píxeles, proyectadas sobre dos triángulos de un plano. La razón de exposición conocida es 0.5. No son fotografías de la sala ni capturas de Polycam.

| Medida de la prueba | Antes | Después |
| --- | ---: | ---: |
| RMSE RGB lineal en las seis muestras reservadas | 0.111738189 | 0.000420562 |
| RMSE logarítmico de luminancia en esas muestras | 0.699933453 | 0.001397073 |

Se usaron 18 muestras en total, seis reservadas fuera del ajuste. La ganancia estimada de `left.png` fue 0.497312648, frente al valor conocido 0.5; `right.png` permaneció como referencia con ganancia exactamente 1. Se ajustó una fotografía y las dos fuentes originales continuaron idénticas byte a byte. Los colores muestreados sobre ambas caras del atlas codificado coincidieron en esta prueba uniforme; eso no establece ausencia de costuras en escenas generales.

El atlas contiene 148,512 píxeles, de los cuales 144,184 corresponden a recortes; las fuentes suman 2,000,000 píxeles y se conservan completas. El procesamiento medido en el Mac sin optimización fue 0.523214 s, incluida una etapa fotométrica de 0.013547 s y atlas de 0.006382 s. Son tiempos de este caso y de ese entorno, no del iPhone.

Datos exactos: [measurements.json](../build/Research/texture-photometric-tests/synthetic-native-1000-final/measurements.json). Salida: [OBJ y materiales de la prueba](../build/Research/texture-photometric-tests/synthetic-native-1000-final/baked/modelo.obj). El método aplica una ganancia escalar en RGB lineal, conserva una referencia observada y exige mejora de error RGB y logarítmico en las muestras reservadas; no estima un blanco neutro de toda la escena.

## Atlas: doce imágenes sintéticas 4K

El benchmark utiliza doce JPEG creados para la prueba de 3840 × 2160 píxeles; cada uno aporta una región central nativa de aproximadamente 512 píxeles de lado. Se aprovechan sólo las regiones utilizadas por las caras, manteniendo su densidad de texeles, sin reducir las fuentes completas.

| Resultado verificado | Valor |
| --- | ---: |
| Fuentes | 12 |
| Píxeles totales de las fuentes | 99,532,800 |
| Píxeles de recortes utilizados | 3,151,872 |
| Páginas / materiales de salida | 1 / 1 |
| Píxeles del atlas, con márgenes | 3,734,808 |
| Tamaño del PNG escrito | 68,836 bytes |
| Desviación máxima numérica del intervalo de texeles | 0.000183105 píxeles |
| Empaquetado / renderizado / total en CPU del Mac | 0.007495 / 0.052754 / 0.060464 s |

El tamaño PNG depende del contenido sintético y no representa compresión típica de una sala. Un búfer RGBA8 de esos 3,734,808 píxeles ocuparía aproximadamente 14.25 MiB: es un cálculo de almacenamiento de píxeles, no memoria GPU o RAM observada. No se deduce una mejora de FPS del menor número de materiales.

Fuente: [BenchmarkTextureAtlas/latest.json](../build/Benchmarks/TextureAtlas/latest.json). Las pruebas cubren orientación con píxeles asimétricos, coordenadas fraccionarias sin remuestreo, márgenes contra contaminación entre fotos, perfiles de color separados, conservación de fuentes con más de ocho bits y originales dedicadas para recortes demasiado grandes. Que esos casos aprueben no convierte el benchmark en una medición de fidelidad de una sala real.

## Continuidad sobre el OBJ real del usuario

Entrada: `~/Downloads/modelo.obj`, 12,243,042 bytes, SHA-256 `7fd0a894fd488c43bba174015212b8ed898908d468a1e506180005b568d1fb8e`. Se generó una copia derivada; el archivo de entrada conservó su hash.

| Dato | Original | Derivado |
| --- | ---: | ---: |
| Vértices escritos | 168,280 | 166,651 |
| Caras triangulares | 306,113 | 306,113 |
| Componentes con caras | 924 | 860 |
| Vértices aislados, conservados | 1,752 | 1,752 |
| Componentes contando los aislados | 2,676 | 2,612 |
| Aristas de borde por incidencia | 26,361 | 24,133 |

Se unieron 1,629 vértices. La tolerancia solicitada fue 0.5 mm; el desplazamiento **real máximo medido** fue `4.915124923727108e-7 m`, aproximadamente 0.000492 mm. Son magnitudes distintas: la tolerancia es un criterio del algoritmo, no una precisión del escáner. El tiempo de procesamiento fue 0.203454 s en el Mac.

Una comprobación independiente, con lectura escalar de coordenadas Float32 y aristas dirigidas en Python, verificó las 306,113 caras en su orden original, posiciones procedentes del original, cero aristas no manifold y cero aristas compartidas por dos caras con orientación inconsistente. El cambio máximo relativo de área fue 0.00120351046 —aproximadamente 0.12035 %— y el coseno mínimo entre la normal original y derivada fue 0.99999947251.

No se suavizaron superficies, rellenaron huecos, añadieron caras ni borraron objetos o componentes. Las uniones están restringidas a bordes de componentes originales distintos, con distancia euclídea exacta, orientación compatible y apoyo de otra arista de borde. Se conservan posiciones representantes ya existentes, sin promediar. Las esquinas, hojas opuestas y capas paralelas próximas tienen protecciones explícitas. La conectividad resultante describe índices de una exportación: no prueba que las superficies estén físicamente unidas, ni que se hayan recuperado detalles nuevos.

Evidencia: [métricas completas](../build/Comparison/2026-10-15/Continuity-v0.4/continuidad.json), [verificación independiente](../build/Comparison/2026-10-15/Continuity-v0.4/independent-verification.json) y [OBJ derivado](../build/Comparison/2026-10-15/Continuity-v0.4/continuidad.obj). Reproducción: [MeshContinuityBenchmark.swift](../Tools/MeshContinuityBenchmark.swift), compilado con los mismos tipos y algoritmo del proyecto; el encabezado documenta los comandos. El OBJ antiguo carece de fotografías calibradas y no adquiere textura al unir vértices.

## Conservación y reproceso en la aplicación

La cadena actual guarda la malla original en `malla-original.json` antes de derivar continuidad y textura. Si ya existe, comprueba que corresponde a la entrada. Si la unión conservadora no puede aplicarse, mantiene la malla original y lo informa; una cancelación no publica un resultado parcial.

«Reprocesar con mejoras» trabaja en un espacio nuevo, copia las fuentes disponibles y guarda una versión nueva de la captura. El resultado conserva `sourceScanID`, que también se incluye en la información exportada, y permite abrir la captura original. Cuando sólo queda geometría, el resultado continúa con material neutro; no se fabrican fotografías. Con fuentes RGB-D, se vuelven a evaluar las proyecciones y el ajuste de exposición validado. Los recortes de atlas son una representación derivada; la captura original y sus fotografías no se reemplazan.

Código de referencia: [LiDARProcessingPipeline.swift](../Forma/Core/LiDARProcessingPipeline.swift), [SavedScanRefinement.swift](../Forma/Core/SavedScanRefinement.swift), [ScanStore.swift](../Forma/Core/ScanStore.swift) y [ScanDetailView.swift](../Forma/Features/ScanDetailView.swift). No se incorporó implementación de ScanSpace; el análisis previo identificó que ese repositorio no declara una licencia general reutilizable.

## Comprobación manual en el iPhone y corrección de rutas

En el iPhone, «Reprocesar con mejoras» creó la captura `174F8E85-8DDC-44A6-B0B5-F81D222FF29B` desde `0A7A1393-6D40-4E6F-ABC6-A6F09CFAE9D1`. La interfaz mostró 166,651 vértices y 306,113 caras; «Abrir captura original» volvió a la captura de 168,280 vértices y las mismas 306,113 caras. Los siete archivos del original se descargaron otra vez y conservaron sus bytes y hashes: [comparación del original](../build/Comparison/2026-10-15/Phone-v0.4/original-unchanged.json). El visor físico mostró las opciones de bordes 4×, 2× y sin suavizado; no se obtuvo una medida de FPS sostenida.

Esta comprobación descubrió que la enumeración de URLs de iOS podía resolver `/var` como `/private/var`, desfasando los nombres relativos del índice de integridad. Se corrigió la persistencia para enumerar nombres relativos directamente. La regresión reproduce una biblioteca mediante un enlace simbólico, incluye archivos anidados y detecta su alteración. Las tandas finales unitarias de simulador e iPhone de la tabla incluyen esa corrección.

La primera copia refinada ya creada conservaba sus once archivos correctos; se repararon únicamente las rutas de su manifiesto después de verificar todos sus hashes y tamaños. El manifiesto anterior quedó respaldado en el proyecto y en `Documents/Forma/.metadata-backup-174F8E85/integridad-original.json` del teléfono. Se volvió a descargar el manifiesto corregido y coincidió exactamente con el escrito: [auditoría de la reparación](../build/Comparison/2026-10-15/Phone-v0.4/metadata-repair-174F8E85/repair-audit.json) y [verificación física](../build/Comparison/2026-10-15/Phone-v0.4/physical-refinement-verification.json).

La compilación normal final 0.4.0, build 4, se instaló y su lanzamiento mediante CoreDevice terminó correctamente. No se repitió manualmente el reprocesado después de la corrección: Duplicación informó que la cámara del iPhone estaba en uso. No se atribuye a esta ejecución una captura nueva con fotografías.

## Qué queda por medir

La captura real posterior, con fotografías calibradas y guardado pendiente preservado, se documenta por separado en [NEW_ROOM_COMPARISON.md](NEW_ROOM_COMPARISON.md). Muestra problemas visibles y no demuestra superioridad. Todavía hace falta comparar regiones equivalentes, manteniendo luz y recorrido comparables, y medir textura, detalle visible y fluidez. No se ha medido aquí error dimensional contra una referencia, rendimiento del visor sobre la misma sala ni una ventaja global frente a Polycam. Los resultados sintéticos y de conectividad sustentan cambios concretos del procesamiento, no esas afirmaciones adicionales.
