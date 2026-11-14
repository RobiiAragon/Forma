# Validación de regiones UV y atlas de Forma 0.5

Se corrigió un coste concreto de la captura real: un único rectángulo por fotografía incluía espacios entre caras observadas y producía casi cuatro mil millones de píxeles. El atlas ahora conserva regiones conectadas por aristas UV y divide regiones cóncavas cuando disminuye el coste rectangular con márgenes, manteniendo cada triángulo completo. No cambia posiciones, caras, normales ni densidad de texeles; las fotografías fuente permanecen disponibles.

## Resultado sobre el OBJ real preservado

Esta ejecución **reempaca las texturas existentes** del OBJ recuperado. No repite selección de fotografías, captura RGB-D o corrección de exposición, ni mide FPS.

| Dato | Paquete de entrada | Derivado con charts |
| --- | ---: | ---: |
| Caras totales | 366,954 | 366,954 |
| Caras fotográficas | 244,786 | 244,786 |
| Materiales fotográficos | 387 | 41 |
| Materiales totales, incluido el neutro | 388 | 42 |
| Píxeles de imágenes de visualización | 3,905,749,740 | 676,379,333 |
| Bytes de las imágenes | 3,467,155,715 | 307,734,209 |

Los píxeles disminuyeron **82.68 %**, los materiales fotográficos **89.41 %** y los bytes codificados **91.12 %** en este caso. No se redujo la resolución de las regiones conservadas ni se eliminaron caras. La salida contiene 54,235 charts de 44,632 islas UV; sus recortes suman 260,191,518 píxeles. Los 676,379,333 píxeles codificados incluyen márgenes y espacio libre de empaquetado, por lo que aún existe margen de optimización. No se establece una cuota de páginas, fotos o charts.

El empaquetado tardó 0.163610 s y el renderizado/codificación 98.796132 s: total 98.960116 s en CPU del Mac con compilación optimizada. Se realizaron 1,129 decodificaciones explícitas de fuente por pareja fotografía/página, frente a 54,235 charts; no se decodifica una fotografía completa por cada chart. Este tiempo usa los PNG/JPEG del paquete ya texturizado, con entradas distintas de la cadena original del iPhone.

Los hashes SHA-256 del OBJ original y de las 387 imágenes de entrada coincidieron antes y después. Las fuentes no se sustituyeron. Las originales de más de ocho bits y las imágenes que requieren una página dedicada se copian sin alterar sus bytes y se deduplican por fotografía, aunque haya múltiples charts.

Datos: [measurements.json](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/measurements.json), [ejecución completa](../build/Comparison/2026-10-15/NewRoom-v0.4/charts-v0.5-benchmark.log) y [OBJ derivado](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/modelo.obj). Reproducción con el mismo algoritmo del proyecto: [TextureChartBenchmark.swift](../Tools/TextureChartBenchmark.swift).

## Verificación independiente

Una segunda lectura en Python comprobó los registros de vértices y normales y todos los índices de vértice/normal de las **366,954 caras, en el mismo orden y orientación**. Sus hashes coinciden entre entrada y salida. Los 244,786 identificadores de caras fotográficas permanecieron únicos.

El error máximo de intervalo de texeles medido para todas las caras fue 0.000244141 píxeles. En 4,149 caras distribuidas determinísticamente se compararon 16,596 muestras bilineales: el RMSE RGBA fue 0.291093 unidades de ocho bits y la diferencia máxima 2.391380 unidades sobre 255. La conversión y codificación RGBA8 y la aritmética de UV conservan una diferencia pequeña de color; **no se afirma identidad bit a bit de todos los colores derivados**.

Dos vistas se renderizaron antes y después con cámaras y ajustes idénticos. Los pases de geometría neutral son idénticos píxel a píxel. En albedo, el RMSE RGB es 0.111640 sobre 255 en la vista oblicua y 0.113905 en la cenital; el cambio máximo de píxel es 2 sobre 255. La apariencia se conserva prácticamente, incluidos los defectos de la captura: el empaquetado no recupera detalle ni repara la fragmentación.

Evidencias: [verificación independiente](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/independent-verification.json), [diferencias entre renders](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/render-difference.json) y [comparador visual local antes/después](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/index.html).

## Pruebas de algoritmo

Se ejecutaron **19 pruebas Mac sin fallos**: siete de agrupación UV y doce de atlas, incluidas las diez anteriores. Cubren adyacencia por arista, islas separadas, una región cóncava conectada, ausencia de cuantización para unir UV próximas, identidad de fuentes distintas, conservación de caras y coordenadas, cancelación y entradas inválidas. Las pruebas de imagen verifican orientación asimétrica, muestreo bilineal fraccional, márgenes, perfiles de color separados, alfa, copias de originales de 16 bits con múltiples charts y una sola decodificación por fotografía/página.

La comprobación de memoria consulta el estado disponible del sistema, conserva margen para el proceso y rechaza una asignación que no cabe; no introduce límites comerciales. La publicación del directorio de atlas sigue siendo atómica y la cancelación retira la salida temporal. El código conserva los puntos de pausa/cancelación de la cadena.

Fuentes: [TextureChartBuilder.swift](../Forma/Core/TextureChartBuilder.swift), [TextureAtlasBuilder.swift](../Forma/Core/TextureAtlasBuilder.swift), [TextureChartTests.swift](../Tests/TextureChartTests.swift), [TextureAtlasTests.swift](../Tests/TextureAtlasTests.swift) y [registro de las 19 pruebas](../build/Research/texture-chart-tests/results.log). Las pruebas finales de aplicación y dispositivo se documentan por separado por quien las ejecutó.

## Ejecución adicional desde la aplicación Mac

La aplicación Mac 0.5 Release procesó de nuevo las **566 fotografías calibradas de origen**, en lugar de reempacar el OBJ existente, y guardó la captura `28D5F554-465E-48FC-BEA0-BA9F3414C146`. Sus informes y el MTL guardados se leyeron directamente de la biblioteca y se preservó una copia de esos metadatos.

| Dato de esa ejecución independiente | Valor |
| --- | ---: |
| Caras totales / fotográficas | 366,954 / 244,786 |
| Materiales fotográficos / totales con el neutro | 42 / 43 |
| Píxeles de atlas | 688,198,711 |
| Bytes de atlas | 309,348,295 |
| Selección / evaluación fotométrica | 46.299469 / 13.747524 s |
| Decodificaciones fotométricas | 562 |
| Coherencia / atlas | 13.099121 / 50.606105 s |
| Texturizado total registrado | 124.287504 s |
| Ajustes de exposición aceptados | 0 |

También se comprobó manualmente que la aplicación reconoció una pausa de procesamiento y continuó al reanudarla, pasando del 21.885 % al 23.0046 % y terminando el guardado. El tiempo total puede incluir esa pausa. El registro anterior del iPhone era de 835.087 s, pero cambian hardware, compilación y código: **no es una medición controlada de un factor de aceleración**. Tampoco se suman ambas ejecuciones como una sola prueba de conservación de UV; la verificación bit a bit de geometría y las muestras antes/después corresponden al reempaquetado descrito arriba.

Metadatos: [informe guardado en Mac](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/MacGUI-28D5F554/informe.json) y [procedencia y hashes](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/MacGUI-28D5F554/evidence.json).

La [comparación con el GLB de Polycam](NEW_ROOM_COMPARISON.md) sigue mostrando los límites de la captura. Esta mejora reduce almacenamiento y materiales conservando muestreo y geometría; no demuestra mayor precisión, mejor FPS o una apariencia superior a Polycam.
