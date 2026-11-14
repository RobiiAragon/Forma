# Vista Gaussian desde las cámaras de captura

Investigación y componente matemático del 15 de octubre de 2026. La sala entrenada en Mac terminó en 3,000 pasos y contiene 425,928 Gaussianas. Este trabajo añade datos y proyección de cámaras calibradas; la integración del visor corresponde a la versión siguiente. Las pruebas descritas aquí no son un render comparativo ni una demostración de calidad superior a Polycam.

## Por qué el encuadre exterior muestra la sala pequeña

El visor anterior calcula el centro y radio usando todos los centros Gaussian, incluidos puntos extremos, y empieza a `3.2 × radio`. En esta exportación:

| Medida del encuadre existente | Resultado |
| --- | ---: |
| Centro AABB, metros | −0.667, −2.016, 0.694 |
| Radio de su esfera envolvente, metros | 8.8787 |
| Distancia orbital inicial, metros | 28.4119 |
| Distancia de ese ojo a la cámara de captura más cercana | 27.6856 m |

El modelo completo cabe en esa vista, pero buena parte del interior queda pequeña. La posición exterior también está lejos de las observaciones de entrenamiento. Los armónicos SH3 expresan color dependiente de la dirección: una vista exterior no equivale a una fotografía capturada y puede mostrar artefactos. Esto explica un riesgo de la vista inicial; no identifica por sí solo la causa de cada mancha verde observada ni garantiza que cambiar de cámara elimine defectos del modelo.

La alternativa propuesta conserva todos los puntos: abrir desde una cámara registrada, con su posición, orientación e intrínsecos. El modo orbital completo sigue disponible. No se propone descartar cuantiles, bajar resolución o eliminar Gaussianas de baja opacidad para mejorar el encuadre.

## Coordenadas comprobadas

`COLMAPDatasetExporter` convierte una pose ARKit `C` mediante `Wcol = F × inverse(C)`, con `F = diag(1,−1,−1,1)`. El cargador nativo recupera `Cnative = inverse(Wcol) × F`. Como `F² = I`, queda `Cnative = C`: cámara dextrógira, +Y arriba y −Z hacia delante.

El entrenamiento centra y escala posiciones: `pnormalizada = (pmundo − traslación) × escala`. La exportación `keepCrs=true` aplica `pmundo = pnormalizada / escala + traslación`. Por ello, las poses nativas del manifiesto pueden usarse con el PLY exportado sin añadir otra inversión Y/Z, rotación global o escala.

Se verificaron las 566 poses contra el `images.txt` COLMAP de esa misma entrada, no solo una cámara sintética. El error máximo de matriz con la API Swift fue `1.1921 × 10⁻⁶`.

## Intrínsecos y orientación del raster

La primera observación cronológica es `C5E81472…`: raster 3840 × 2160, `fx = fy = 2614.4946`, `cx = 1930.2549`, `cy = 1090.4849`. Su campo de visión nativo es aproximadamente 72.58° horizontal × 44.89° vertical; no debe sustituirse por un FOV simétrico fijo de 60°.

La API usa el centro del píxel superior izquierdo como `(0,0)`. Para un raster `W × H`, con cámara −Z, los desplazamientos de proyección incluyen `1 − 2(cx + 0.5)/W` en X y `2(cy + 0.5)/H − 1` en Y. También conserva términos de skew, focales X/Y distintas y profundidad Metal `0…1`.

La proyección entrega un rectángulo que ajusta el raster completo dentro del drawable, sin estirarlo. El integrador debe usar ese rectángulo como viewport y scissor, y pasar las focales escaladas al Jacobiano de covarianza del shader. Las bandas vacías corresponden al aspecto de la fotografía; no son datos eliminados del modelo. El modo orbital permite explorar el resto.

La primera cámara tiene su eje superior casi alineado con +X del mundo: el raster nativo está girado aproximadamente 90° respecto a la vertical de la sala. Reconstruir una cámara `lookAt` con +Y global sin transformar K cambiaría los rayos. En su lugar, la presentación opcional en cuartos de vuelta transforma **ambos**:

- Pose: columnas nuevas `[arriba anterior, −derecha anterior, atrás anterior, posición anterior]`.
- Dimensiones: `W′ = H`, `H′ = W`.
- Intrínsecos: `fx′ = fy`, `fy′ = fx`, `cx′ = H − 1 − cy`, `cy′ = cx`; los términos cruzados se intercambian y cambian de signo.

Así, cada píxel `(u,v)` pasa a `(H−1−v,u)` y conserva exactamente su rayo de mundo. No se rota ni reescribe la fotografía. `uprightPresentation` escoge entre las cuatro presentaciones equivalentes la que más aproxima su eje superior a +Y del mundo; no mueve el ojo ni la dirección frontal.

## API implementada y propuesta de interfaz

[GaussianViewpoint.swift](../Forma/Core/GaussianViewpoint.swift) incluye:

- `load(fromDataset:) async throws -> [GaussianViewpoint]`: lectura y validación fuera del ejecutor de interfaz; conserva todos los frames, ordenados por tiempo con empates estables. Un frame inválido genera un error identificable; no se salta silenciosamente.
- Pose, K, dimensiones, timestamp, ruta RGB relativa, índice de origen y proyección calibrada para cada observación.
- `rotatedForPresentation(quarterTurns:)`, `uprightPresentation` y consultas de índice anterior/siguiente, sin modificar fuentes.

Propuesta para integrar en el visor:

1. Abrir en **Vista de captura**, desde la primera observación válida, con presentación vertical opcional y K real.
2. Botones de **Anterior / Siguiente** y un selector de observación que recorra las 566 cámaras conservadas. Un recorrido automático puede visitar esas poses a sus timestamps; una interpolación entre poses debe presentarse como exploración, no como una nueva observación capturada.
3. **Orbitar** y **Encuadrar completo** siguen disponibles y usan el modelo completo. Cambiar de modo no debe reescribir la nube ni esconder puntos permanentemente. Evitar saltos al entrar en órbita requiere conservar el ojo y elegir un pivote sobre su rayo frontal; apuntar de golpe al centro AABB cambia el encuadre.
4. **Volver a la vista de captura** restaura pose, K y aspecto; zoom y exploración siguen siendo decisiones de visualización.

Para exportaciones autónomas se propone después un sidecar de cámaras que incluya todas las poses, K, dimensiones, IDs y timestamps, además del hash del índice de captura y `keepCrs=true`. No necesita copiar fotografías ni guardar rutas absolutas. El paquete debe vincular ese sidecar al modelo con su manifiesto de integridad. Las exportaciones antiguas sin cámaras mantienen una vista orbital explícita; no se deben inventar poses históricas.

## Pruebas y alcance

Pasaron **cinco pruebas XCTest Mac**, sin fallos: centro/esquinas con K asimétrica y skew; aspecto horizontal/vertical; profundidad Metal; los cuatro giros con rayos equivalentes; orientación vertical; identidad y orden de todos los frames; rechazo explícito de una pose malformada. [Registro](../build/Research/GaussianCameraPose/unit-tests/results.log).

El verificador de la API de producción leyó los **566 frames reales** y comprobó **22,640 rayos** de esquinas/centro, cuatro presentaciones y dos aspectos de drawable:

| Comprobación | Error máximo |
| --- | ---: |
| Pose Swift frente a extrínsecos COLMAP | 0.0000011921 |
| Reproyección al píxel nativo | 0.0012391 px |
| Posición en drawable Metal | 0.0003662 px |

Los SHA-256 de `dataset.json`, `cameras.txt` e `images.txt` coincidieron antes y después. No se decodificaron fotografías, abrió cámara, ejecutó GPU o envió información a servicios externos. El typecheck con SDK iOS 27 del componente también pasó. [Resultado completo](../build/Research/GaussianCameraPose/actual-566-views-v1/verification.json), [análisis de encuadre y coordenadas](../build/Research/GaussianCameraPose/pose-projection-verification.json) y [verificador reproducible](../Tools/verify_gaussian_viewpoint.swift).

```sh
bash Tools/verify_gaussian_viewpoint.sh /ruta/al/dataset /ruta/nueva/de/resultados
```

## Integración 0.8.1 y fallo de proyección corregido

La integración está instalada en iPhone y Mac como 0.8.1 build 11. Incluye navegación anterior/siguiente por todas las cámaras, selección de vista capturada/general y zoom óptico desde la calibración. La pose vertical conserva el ojo y los mismos rayos. La interfaz Mac se abrió sobre la sala real; se verificó también el cambio a la segunda observación.

Al comparar el visor con el renderizador nativo se aisló otro fallo: una gaussiana cercana fuera del campo visual podía expandir su elipse proyectada hasta cubrir la imagen. El shader del visor ahora estabiliza las coordenadas utilizadas por el Jacobiano EWA con el mismo margen de campo visual del motor nativo. No cambia la posición real del centro, no recorta la población ni modifica el modelo. La regresión `testNearOffscreenGaussianCannotExpandAcrossTheObservedImage` envía ambas gaussianas y comprueba que la exterior no oculte la observación central.

El PLY y el checkpoint original de 3,000 pasos coinciden en los 425,928 centros, escalas, cuaterniones, opacidades y coeficientes SH exportados; error máximo de posición 9.52 × 10⁻⁷ m. La conversión de coordenadas no era la causa de la imagen uniforme. Con la corrección EWA, doce renders Metal reales —tres observaciones, orientación nativa/vertical y dos formatos de lienzo— dejaron de ser uniformes. Los hashes de fuentes y modelo permanecen intactos. Evidencias: `build/Research/GaussianViewpointRender/v081-final-fixed1024/`, `v081-final-canvas1024/` y `quality-diagnostic.json`.

En las observaciones 0/283/565, el error absoluto medio RGB de 8 bits del visor frente a la foto pasó de 55.47/58.44/63.57 a 50.43/15.07/16.60. Son fotografías usadas para entrenar, redimensionadas para esta comparación; no son vistas reservadas ni medidas de precisión física. La primera vista sigue borrosa también en el renderizador nativo: PSNR 11.793 dB. Corregir el visor no acredita que el entrenamiento o Forma superen a Polycam.

Pasaron 32 casos seleccionados de simulador y nueve de la tanda final (cuatro de renderizado y cinco de cámaras). La biblioteca Metal comprobada en Mac tiene SHA-256 `eb136dd0892759d2d147ebf8ee101b18e276ff85be9ac242dc315ad2e2e085aa`. No se lanzó otra tanda física para evitar interrumpir el trabajo del usuario en el iPhone; la app Release fue instalada y abierta con sus cinco capturas conservadas.
