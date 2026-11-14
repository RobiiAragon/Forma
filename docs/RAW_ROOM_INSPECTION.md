# Inspección de la sala reconstruida en Raw · Forma 0.5

La reconstrucción fotográfica local terminó y produjo un USDZ de **323,963,360 bytes**, con **1,614,034 vértices, 3,227,473 triángulos y cuatro texturas de 8192 × 8192**. Las vistas muestran un suelo y muebles mucho más continuos que el derivado LiDAR previo de estas fuentes; siguen visibles huecos, fragmentos flotantes y superficies deformadas. Esta observación no demuestra mayor precisión ni superioridad global frente a Polycam.

[Ver imágenes y comparación local](../build/Comparison/2026-10-15/NewRoom-v0.4/Raw-v0.5/index.html) · [Datos resumidos](../build/Comparison/2026-10-15/NewRoom-v0.4/Raw-v0.5/summary.json) · [Inventario USD nativo y renders](../build/Comparison/2026-10-15/NewRoom-v0.4/Raw-v0.5/Inspection-Readable/inspection.json).

## Resultado comprobado

| Medición del archivo guardado | Resultado |
| --- | ---: |
| Fotografías del manifiesto | 566 |
| Fotos omitidas notificadas por Apple | 0 |
| Reducción automática notificada por Apple | 0 |
| Vértices USD / Blender | 1,614,034 / 1,614,034 |
| Caras triangulares USD / Blender | 3,227,473 / 3,227,473 |
| Capas UV / materiales | 1 / 4 |
| Texturas originales del USDZ | 4 × 8192 × 8192, PNG RGB de 8 bits |
| Píxeles de atlas / bytes PNG | 268,435,456 / 223,861,266 |
| USDZ completo | 323,963,360 bytes |
| Archivos del manifiesto con tamaño y SHA correctos | 2,278 de 2,278 |
| Bytes verificados del manifiesto | 2,303,723,182 |

El registro guardado es `9D475662-CF01-40E1-AD0A-F556E9004F8A`. Sus campos de metadatos `vertexCount` y `faceCount` quedaron en cero; los conteos anteriores se leyeron de la malla nativa, sin subdividirla, y coinciden al importarla en Blender. El nivel `raw` es un ajuste de reconstrucción de Apple, no una afirmación de que las fotografías de entrada sean archivos RAW. Los ceros de fotos omitidas/reducción corresponden a lo notificado por la API; no describen cada operación interna de Apple.

## Integridad y procedencia

Se verificaron todos los nombres relativos, tamaños y SHA-256 con lectura streaming de 1 MiB. No hay rutas inseguras, duplicados, enlaces simbólicos, archivos faltantes ni extras; `integridad.json` permanece igual. También se leyeron los cinco miembros del USDZ y sus CRC sin errores, sin extraerlos ni modificar el original. El SHA-256 del USDZ antes y después de renderizar es `9a756eef0981c5273b7ad49d29aa66f7e0285e68a6da9a59f1fbfe94d9a5e920`.

[Evidencia de integridad completa](../build/Comparison/2026-10-15/NewRoom-v0.4/Raw-v0.5/integrity-verification.json). Las imágenes importadas conservan los mismos bytes codificados que sus miembros PNG del USDZ y sus dimensiones nativas.

La copia `9D475662-CF01-40E1-AD0A-F556E9004F8A` se entregó al iPhone y se publicó en `Documents/Forma` con el nombre **«Sala · Mac Raw»**, después de validar las 2,278 entradas de su manifiesto. En esa copia sólo cambió el nombre visible de `captura.json` y su registro de integridad; el manifiesto y los metadatos se leyeron de vuelta y coinciden con la copia preparada. La geometría, las texturas, las fotografías y la calibración conservan los SHA-256 del resultado Mac original, que permanece intacto. [Evidencia de entrega al iPhone](../build/Comparison/2026-10-15/NewRoom-v0.4/Raw-v0.5/phone-delivery-verification.json).

## Lectura visual y límites

El Raw reconstruye una región continua alrededor de la mesa, el suelo y el cuarto con la lavadora; las imágenes LiDAR anteriores exhibían muchas caras grises y fragmentos. En el Raw quedan paredes onduladas, bordes incompletos y piezas flotantes. Más polígonos y texeles no equivalen por sí solos a más detalle correcto.

El GLB de Polycam aportado contiene 38,801 vértices, 65,477 triángulos y dos texturas de 4096 × 4096 y 4096 × 544; ocupa 3,008,972 bytes. Sus vistas muestran una cocina con encimeras y suelo continuos, objetos estirados y recortes en los bordes. No coinciden las coberturas ni la disposición de todos los objetos con el nuevo Raw. No se atribuye un ganador global ni un error geométrico.

Los ocho PNG nuevos usan Blender 5.2.2 LTS, Cycles CPU, 64 muestras, 1200 × 900, sin denoise ni redimensionado de texturas. Se ocultan las caras posteriores conservando la orientación original. Albedo utiliza los colores y opacidad originales con emisión; el pase gris sirve para inspeccionar superficies y huecos. Cada modelo tiene su propio encuadre completo: **el tamaño en pantalla, el ángulo entre modelos y las distancias no constituyen una comparación métrica**. El USD declara Y vertical y 1 metro por unidad, pero su escala no se registró contra LiDAR ni contra una referencia física.

El primer diagnóstico gris a 5000 W quedó sobreexpuesto y se conserva en `Inspection/` como diagnóstico excluido. El informe usa únicamente `Inspection-Readable/` y `Polycam-Reference/`, ambos con relleno gris de 150 W y los mismos parámetros. Las cuatro cámaras verificaron cero vértices fuera del encuadre. La iluminación gris es diagnóstica; no mide fotometría real de la sala.

No se midieron FPS del iPhone ni precisión dimensional, no se calculó una alineación entre las reconstrucciones y no se dispone aquí de una duración fiable del procesamiento Raw. El `duration: 0` guardado no es su duración real. Los 124.2875 s del otro informe corresponden exclusivamente al texturizado LiDAR, una operación diferente.

## Reproducción local

Se utilizó [Tools/inspect_usdz.py](../Tools/inspect_usdz.py), sin descargas nuevas ni operaciones sobre la interfaz o las fuentes de la aplicación. Sus parámetros e inventario están guardados con los renders. Las fotos originales y el USDZ de la biblioteca no se modificaron.
