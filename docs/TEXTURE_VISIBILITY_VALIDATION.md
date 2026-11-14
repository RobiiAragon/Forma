# Visibilidad fotográfica en bordes: validación del 15 de octubre de 2026

Se corrigió una inconsistencia concreta de selección: cuando había profundidad LiDAR, el texturizador comprobaba siete muestras de profundidad —vértices, centro y puntos medios de las aristas— pero solo trazaba un rayo contra la malla, en el centro. Una superficie fina situada delante de una arista podía quedar dentro de la tolerancia del mapa de profundidad y prestar su color a otra superficie aunque el centro siguiera visible.

Ahora las mismas siete muestras deben superar también la prueba de visibilidad de la malla existente. No cambia la tolerancia de profundidad, la calibración, la resolución, las fotografías, el atlas ni la geometría. Una imagen alternativa debe pasar las comprobaciones completas; cuando ninguna lo hace, la cara conserva material neutro. Esta corrección evita una asignación incompatible con la malla, pero puede dejar más caras sin fotografía. No demuestra por sí sola mejor apariencia general ni superioridad frente a Polycam.

## Prueba controlada y exportación completa

Se construyeron dos triángulos, dos imágenes PNG de 128 × 128 y dos cámaras conocidas. Un triángulo estrecho, 4 cm por delante del fondo, oculta únicamente el punto medio de una arista desde la cámara preferida. Esa distancia cabe en la tolerancia existente de 5 cm para el mapa de profundidad de 2 m. La segunda cámara ve el fondo sin esa oclusión.

La versión anterior elegía la primera imagen para el fondo; la nueva elige la imagen visible. Ambas caras siguen texturizadas. Además de comprobar la selección, se ejecutó **la cadena de producción completa**, incluida coherencia, atlas y OBJ: el centro de la cara exportada tiene RGB `[40, 180, 60]`, idéntico al PNG alternativo, en lugar del color de la fotografía ocluida. Se conservaron todos los vértices, índices, orden de triángulos y bytes de las fotografías.

Evidencias locales:

- [Selección antes y después](../build/Research/TextureVisibility/authored-edge-v2/measurements.json).
- [Exportación de producción y lectura de sus texeles](../build/Research/TextureVisibility/authored-edge-full-export/verification.json).
- [Verificador de exportación](../Tools/verify_texture_visibility_export.swift).

Es un fixture con visibilidad conocida. Sus colores no representan mediciones de la sala.

## Misma sala preservada, comparación acotada

Se compararon las dos versiones con la **misma malla de 366,954 caras y los mismos 566 fotogramas calibrados** del respaldo `CB7D23D7…`. Para evaluar sin crear otro atlas grande, se seleccionaron determinísticamente 64 bloques de 64 caras, distribuidos por el orden original: 4,096 caras. La malla completa permaneció en el BVH de oclusión; no se eliminaron posibles obstáculos fuera de los bloques. La coherencia solo puede usar las caras evaluadas, por lo que estos resultados no sustituyen un reprocesamiento completo de la sala.

| Medida en las mismas 4,096 caras | Antes | Después |
| --- | ---: | ---: |
| Caras con fotografía elegida | 2,589 | 2,412 |
| Asignaciones bloqueadas en al menos una de las siete muestras de malla | 202 | 0 |
| Fuentes utilizadas | 268 | 257 |
| Aristas internas con cambio de fuente tras coherencia | 731 | 702 |
| Selección, segundos | 13.648 | 16.850 |
| Coherencia, segundos | 6.359 | 7.727 |

Cambió la asignación de 203 caras: 26 encontraron otra fotografía y 177 quedaron neutras. La cobertura fotográfica por número de caras pasó del 63.208 % al 58.887 % en esta muestra; **no se oculta esta pérdida de cobertura**. Los cambios de fuente bajaron en parte porque hay menos caras fotográficas, por lo que no se presentan como una mejora independiente de costuras o fluidez.

La métrica de oclusión reutiliza el BVH de la malla; comprueba consistencia geométrica interna, no exactitud óptica ni una referencia externa de la sala. El procedimiento no mide RGB reservado, nitidez final, FPS, temperatura del iPhone o calidad frente a Polycam. No se renderizó un antes/después fotográfico completo de la sala en esta ejecución.

Se calcularon hashes SHA-256 antes y después de los **1,700 archivos de entrada referenciados**, incluidas imágenes, profundidad, confianza, manifiesto y malla. Coincidieron todos. Se trabajó en CPU con copias instrumentadas del código para detenerse antes del atlas: no se usó una reconstrucción reducida como sustituto de las fuentes.

Evidencias: [mediciones y versiones del código](../build/Research/TextureVisibility/room-roi-4096-v1/measurements.json), [hashes de entrada](../build/Research/TextureVisibility/room-roi-4096-v1/input-sha256.json), [asignaciones anteriores](../build/Research/TextureVisibility/room-roi-4096-v1/baseline/selection.json) y [asignaciones nuevas](../build/Research/TextureVisibility/room-roi-4096-v1/candidate/selection.json).

## Regresiones y reproducción

Pasaron **37 pruebas Mac, sin fallos**, de fotometría, texturizado LiDAR y atlas. Cubren visibilidad, conservación de geometría/fuentes, selección de detalle, coherencia, exposición validada, perfiles P3, originales de mayor precisión y atlas. [Registro](../build/Research/TextureVisibility/regression-tests/results.log).

El [benchmark](../Tools/benchmark_texture_visibility.py) acepta una versión base del baker y una candidata, mantiene el contexto completo de oclusión y registra el SHA-256 de ambas. Su límite de caras es exclusivamente el tamaño de la muestra de investigación; no modifica la aplicación ni impone cuotas de captura o procesamiento.

```sh
python3 Tools/benchmark_texture_visibility.py \
  --baseline-source build/Research/TextureVisibility/baseline-LiDARTextureBaker.swift \
  --output build/Research/TextureVisibility/nueva-prueba-sintetica

python3 Tools/benchmark_texture_visibility.py \
  --baseline-source build/Research/TextureVisibility/baseline-LiDARTextureBaker.swift \
  --mesh /ruta/al/respaldo/malla.json \
  --dataset /ruta/al/respaldo/fuentes \
  --maximum-faces 4096 \
  --output /ruta/nueva/de/resultados
```

Las carpetas de salida deben ser nuevas. La comparación general preservada sigue en [NEW_ROOM_COMPARISON.md](NEW_ROOM_COMPARISON.md); esta prueba no reemplaza sus conclusiones visuales.
