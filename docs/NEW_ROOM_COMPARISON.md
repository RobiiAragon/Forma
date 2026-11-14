# Captura real nueva de Forma 0.4 frente al GLB de Polycam

Comprobación local del 15 de octubre de 2026. **La captura nueva sí contiene textura fotográfica, pero su apariencia sigue siendo más fragmentada que la del GLB de Polycam recibido. No se ha demostrado que Forma lo supere.** Forma registró una zona mayor; los recorridos, cobertura y presupuestos de procesamiento de ambas capturas no son equivalentes ni están controlados.

## Estado de guardado y preservación

La captura `CB7D23D7-5C49-4986-9D93-220C10F7086A` no apareció como una carpeta publicada en la biblioteca: permanecía en `.pending-CB7D23D7-5C49-4986-9D93-220C10F7086A`, sin `integridad.json`. La biblioteca mostraba tres capturas anteriores y ningún indicador de guardado. Por tanto, no se trató ese directorio como un guardado finalizado.

Se copió **todo** el directorio pendiente al Mac, sin renombrar, borrar, reinstalar ni modificar archivos del teléfono. La transferencia terminó con código 0. La copia contiene 2,672 archivos y 9,097,707,412 bytes; no faltan archivos ni hay diferencias de tamaño frente a la lista de origen. Se calcularon SHA-256 locales de los 2,672 archivos. Como aún no existía un manifiesto de hashes en el teléfono, esto preserva y audita la copia, pero no constituye una comparación independiente de hashes de origen y destino.

El directorio completo se conserva en [preserved-pending-CB7D23D7…](../build/Comparison/2026-10-15/NewRoom-v0.4/preserved-pending-CB7D23D7-5C49-4986-9D93-220C10F7086A). Evidencias: [auditoría completa](../build/Comparison/2026-10-15/NewRoom-v0.4/preserved-copy-audit.json) y [resultado de transferencia](../build/Comparison/2026-10-15/NewRoom-v0.4/preserve-copy-command.json). El respaldo original del Mac no se transformó para producir los renders.

Existe un informe de consumo de CPU de Forma entre 01:23:44 y 01:25:17, con 90 segundos de CPU en unos 94 segundos; indica `Action taken: none`. El evento Jetsam cercano, de 01:38:34, no contiene un proceso llamado Forma. **Estos informes no establecen la causa de la interrupción del guardado.** El guardado escribe `captura.json` y después calcula hashes antes de publicar la carpeta; los archivos observados sitúan la interrupción después de escribir ese registro y antes de publicar el manifiesto. Esto no identifica qué instrucción concreta falló. [Diagnóstico acotado](../build/Comparison/2026-10-15/NewRoom-v0.4/diagnosis-summary.json).

## Datos reales de captura y texturizado

El manifiesto RGB-D contiene 566 fotogramas calibrados: 530 imágenes de 3840 × 2160 y 36 de 4224 × 2376. Todos tienen profundidad y confianza de 256 × 144; sus referencias existen y las dimensiones de los JPEG coinciden con el manifiesto. Hay un JPEG adicional que no figura entre los fotogramas calibrados y que se conserva en el respaldo; no se cuenta como un fotograma utilizable más.

| Medida | Resultado real de Forma |
| --- | ---: |
| Tiempo activo de captura | 120.217 s |
| Fotogramas calibrados | 566 |
| Fuentes seleccionadas para textura | 562 |
| Caras con observación fotográfica válida | 244,786 de 366,954 |
| Cobertura por número de caras | 66.7075 % |
| Caras sin observación, con material neutro | 122,168 |
| Fotografías con ajuste de exposición aceptado | 0 |
| RMSE RGB reservado, antes / después | 0.118021228 / 0.118021228 |
| RMSE logarítmico de luminancia, antes / después | 0.479652745 / 0.479652745 |
| Muestras / muestras reservadas | 697,579 / 261,952 |
| Páginas atlas / fotografías originales dedicadas | 368 / 19 |
| Materiales fotográficos / material neutro | 387 / 1 |

La cobertura del 66.7 % cuenta caras, no área física ni porcentaje de toda la sala. Todas las ganancias de exposición conservadas valen 1 y no se aceptó ninguna corrección en esta captura. El buen resultado de la prueba sintética anterior no se extrapola a esta sala. Las fotografías y la calibración permanecen completas; las caras sin observación no reciben color inventado.

El registro informa unos 29.999 callbacks de AR por segundo y 29.995 callbacks en la última ventana de previsualización. Son telemetría de callbacks de esta captura: no demuestran FPS sostenidos del visor, fotogramas efectivamente presentados ni ventaja frente a Polycam.

## Coste de procesamiento observado

| Etapa medida en el iPhone | Segundos |
| --- | ---: |
| Continuidad geométrica | 1.190 |
| Selección de fotografías | 239.660 |
| Evaluación fotométrica | 466.706 |
| Coherencia entre caras | 45.638 |
| Atlas | 78.111 |
| Texturizado total, incluidas otras operaciones | 835.087 |

El texturizado total duró aproximadamente **13 min 55 s**, además de la captura de unos dos minutos y del guardado posterior. Los tiempos de etapas no incluyen toda la exportación, copia, ZIP o comprobación de integridad. Los archivos de textura terminaron de escribirse a las 01:36:27; `captura.json`, `informe.json` y el ZIP tienen fecha 01:37:17. No existe una hora de compromiso final de esta carpeta.

Se generaron 3,715,061,484 píxeles de atlas y se conservaron 190,688,256 píxeles en fotografías dedicadas: **3,905,749,740 píxeles en 387 imágenes**. Los ficheros de textura ocupan 3,467,155,715 bytes. Un único almacenamiento RGBA8 de todos esos píxeles requeriría unos 14.55 GiB: es un cálculo teórico, no una medición de RAM/GPU observada ni un diagnóstico de cierre. El coste de archivos, materiales y tiempos es un problema práctico aunque no exista cuota comercial.

## Comparación de los archivos de modelo

| Dato | Forma 0.4 nueva | Polycam GLB recibido |
| --- | ---: | ---: |
| Vértices escritos en el modelo | 199,383 | 38,801 |
| Vértices referidos por caras | 197,458 | 38,801 |
| Triángulos | 366,954 | 65,477 |
| Materiales totales | 388 | 2 |
| Imágenes de textura | 387 | 2 |
| Píxeles de textura | 3,905,749,740 | 19,005,440 |
| Modelo utilizable con sus materiales e imágenes | 3,528,203,715 bytes | 3,008,972 bytes |
| Extensión de geometría referida, X/Y horizontal en Blender | 7.845 × 7.219 m | 3.789 × 3.881 m |

Los 1,925 vértices de Forma no referidos por caras se mantienen en el OBJ pero no añaden superficie visible. En Forma, el tamaño de paquete suma OBJ, MTL, texturas y su informe; el GLB integra su geometría y sus dos imágenes. Los 9.10 GB del respaldo de Forma incluyen además fuentes RGB-D y exportaciones redundantes, por lo que no se comparan directamente con el GLB como si ambos fueran respaldos de captura completos. No recibimos los originales RGB-D de Polycam.

Más triángulos y píxeles no prueban más detalle óptico. Forma ocupa una región mayor y conserva mucha más información de origen. Aun así, su modelo de visualización es excesivamente pesado para el resultado observado. La geometría conserva sus 366,954 caras después de unir 1,407 vértices; los componentes con caras pasaron de 1,416 a 1,344. Es conectividad de índices, sin suavizado ni relleno, y no constituye una medida de precisión física o un recuento de huecos reales.

## Inspección visual reproducible

Se generaron ocho imágenes nuevas de 1200 × 900 mediante Blender 5.2.2 LTS, Cycles CPU, 64 muestras, sin denoising: dos modelos × dos vistas —cenital y oblicua— × albedo sin iluminación y geometría neutral. Todos los pases terminaron correctamente y se inspeccionaron.

Cada pareja usa la misma cámara, escala, encuadre de la unión y descarte de caras posteriores. Todos los vértices quedan dentro del encuadre auditado. Se retuvieron las normales y posiciones originales; no se redimensionaron las fotografías, rellenaron superficies ni añadieron detalle. El albedo evita que las diferencias de parámetros PBR oscurezcan una aplicación. La geometría neutral tiene el mismo material y luces en ambos modelos y un nivel mínimo de emisión declarado para poder ver interiores; es inspección, no iluminación física.

La alineación rígida automática sólo propone giro alrededor de la vertical y traslación, sin escalado. Tiene soluciones competidoras y permanece **no verificada**; el giro propuesto de 148.901° no establece correspondencia exacta entre puntos. No se presenta distancia entre modelos como error de reconstrucción. Las vistas son inspecciones del contenido de los archivos y no una comparación píxel a píxel registrada.

En las vistas de albedo, Forma ya muestra colores y objetos reconocibles. También aparecen zonas neutras extensas, bordes fragmentados y discontinuidades visibles en suelo y mobiliario. El pase neutral confirma que parte de la fragmentación pertenece a la geometría y no sólo a la textura. Polycam ofrece un suelo y superficies visualmente más continuos en su porción menor de cocina, aunque también contiene bordes incompletos y deformaciones. **Para estos archivos y estas vistas, Polycam sigue presentando una apariencia más limpia.** Las imágenes no permiten aislar seguimiento, profundidad o proyección como causa de cada defecto.

Vistas nuevas: [Forma, oblicua con textura](../build/Comparison/2026-10-15/NewRoom-v0.4/Report/forma_oblique_albedo.png), [Polycam, oblicua con textura](../build/Comparison/2026-10-15/NewRoom-v0.4/Report/polycam_oblique_albedo.png), [Forma, cenital con textura](../build/Comparison/2026-10-15/NewRoom-v0.4/Report/forma_top_albedo.png) y [Polycam, cenital con textura](../build/Comparison/2026-10-15/NewRoom-v0.4/Report/polycam_top_albedo.png). El [informe visual local](../build/Comparison/2026-10-15/NewRoom-v0.4/Report/index.html) permite alternar los ocho pases.

Parámetros y métricas: [comparison.json](../build/Comparison/2026-10-15/NewRoom-v0.4/Report/comparison.json), [resumen de captura](../build/Comparison/2026-10-15/NewRoom-v0.4/comparison-summary.json), [log de render](../build/Comparison/2026-10-15/NewRoom-v0.4/render-inspection.log) y [herramienta reproducible](../Tools/compare_model_exports.py). La comparación antigua de los archivos originales conserva su alcance y no se sustituye con estos resultados.

## Prioridades que sustenta esta captura

1. Completar y comprobar el guardado de capturas grandes con recuperación conservadora de pendientes, conservando el respaldo íntegro antes de intervenir.
2. Reducir trabajo redundante de selección, fotometría y atlas: aquí 466.7 s de evaluación fotométrica no produjeron una corrección aceptada. Conservar las fotos originales y distinguir el modelo de visualización de sus fuentes nativas.
3. Mejorar la continuidad de la geometría y la asignación de fotografía en caras observables; aumentar indiscriminadamente el tamaño de atlas no resolvió los defectos visibles.
4. Medir después una región realmente equivalente, calidad de texturas y FPS sostenidos del visor. No se ha certificado precisión dimensional, completitud de la sala o superioridad global.

## Mejora posterior: atlas por regiones de Forma 0.5

La misma captura fue reempaquetada después con regiones UV. Sus imágenes de visualización pasaron de 3,905,749,740 a 676,379,333 píxeles —82.68 % menos— y de 387 a 41 materiales fotográficos, conservando las 366,954 caras y los 244,786 triángulos texturizados. La verificación independiente mantiene registros e índices geométricos idénticos; los renders neutrales son idénticos. La apariencia fotográfica se conserva prácticamente, con diferencias pequeñas de color declaradas. Este cambio no corrige la fragmentación ni demuestra superioridad frente a Polycam.

Además, la app Mac 0.5 procesó desde los 566 fotogramas calibrados y guardó una salida distinta, de 42 materiales fotográficos —43 con el neutro— y 688,198,711 píxeles de atlas. Registró 124.287504 s de texturizado total, con pausa y reanudación comprobadas. Esa ejecución usa hardware, compilación y código distintos del registro anterior del iPhone y puede incluir la pausa; no establece un factor controlado de aceleración.

Los datos, pruebas y el antes/después se distinguen en [TEXTURE_CHART_VALIDATION.md](TEXTURE_CHART_VALIDATION.md) y en el [comparador local](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/index.html). Las cifras y vistas de las secciones previas describen el artefacto anterior preservado; no se reemplazaron por el derivado.
