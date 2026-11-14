# Texturas de la sala: resultado del ensayo

**Se mantiene Raw.** Ni personalizado 16K ni los dos retexturizados justifican reemplazarlo. MVE recupera algunos textos más definidos, pero introduce discontinuidades de color en paredes, suelo y silla. No se instalaron como una mejora visual de Forma.

![Raw frente a textura nueva](../build/Research/PhotogrammetryCalibration/room-native/comparison-retextured-v2/detail-camera-482.png)

![Control sin ajuste de color de costuras](../build/Research/PhotogrammetryCalibration/room-native/comparison-retextured-v3/comparison-camera-283.png)

## Evidencia

- Misma sesión y 566 fotos: Raw produjo 3,256,312 triángulos y cuatro atlas 8192²; personalizado produjo 250,000 triángulos y un atlas de color 16384². Ambos contienen los mismos texeles de color totales.
- Se conservaron 565 cámaras con K/LUT, 59,773 puntos y el registro de una foto sin pose. No se mezclaron cámaras ARKit con geometría fotogramétrica.
- SIFT independiente identificó el sentido correcto de LUT. Sobre todos los matches mutuos, el error mediano de las cámaras 0/283/482 pasó de 21.18/20.63/15.59 px a 4.71/2.28/1.71 px al convertir las coordenadas fotográficas a pinhole. La dirección inicial era incorrecta. Es una validación de convención geométrica, no de calidad global.
- El worker ahora proyecta exactamente de pinhole a foto original: `s = c + (p-c) * (1 + LUT(r))`. Usa JPEG, dimensiones y FOV originales, sin recortar, remuestrear ni recodificar entradas. `--forma_native_lut` exige una LUT por foto. Una LUT faltante impide publicar un resultado.
- C++ coincidió con Float64 en 3,270 puntos nativos: error máximo 0.000166 px. El caso pequeño completo pasó y el caso de LUT obligatoria ausente se rechazó.
- Un perfil mostró contención al registrar cada vértice de los parches. Agrupar el registro por foto conservó OBJ/MTL/PNG idénticos en el caso pequeño. La fase completa de 565 fotos terminó en 5.335 s. El benchmark antiguo seguía en esa fase tras más de nueve minutos y fue terminado como obsoleto; sus costes y etiquetas ya guardados se conservaron. Ningún trabajo iniciado por el usuario en la app se detuvo.

## Dos variantes completas

En `build/Research/PhotogrammetryCalibration/room-native`:

1. `retextured-native-lut-batch-v2`: mismas 565 fotos, mismos 3,256,312 triángulos y etiquetas/costes ya calculados. Incluye ajustes global/local de costuras. Las etapas posteriores tardaron 98.847 s; **no es el tiempo del pipeline completo desde cero**. Generó 187 atlas, 588,316,672 texeles y 439,917,956 bytes PNG. El render confirma la misma cantidad de triángulos que Raw.
2. `retextured-native-lut-source-colors-v3`: mismas fotos, geometría y etiquetas; desactiva sólo los ajustes global/local de color. Esas etapas posteriores tardaron 63.597 s. Los parches persisten y aparecen cortes: los ajustes de costura no son su única causa.

En las cohortes exactamente comunes Raw/candidato v2 hay 29/88/193 rasgos fuente. Sus errores medianos son Raw 4.69/1.81/1.70 px y candidato 4.38/2.07/2.02 px; no mejoran de forma uniforme. SIFT no mide nitidez global. Los renders usan los mismos K, C2W, resolución nativa e iluminación constante, con caras traseras ocultas. Informes en `comparison-retextured-v2` y `comparison-retextured-v3`.

Los originales permanecen intactos. No se demuestra superioridad frente a Polycam. El worker experimental todavía no está integrado ni empaquetado en las apps.

## Siguiente paso

Conservar geometría, UV y colores base Raw; probar transferencia del detalle fotográfico en la pequeña zona ya alineada mediante correspondencias nativas. Validar máscaras antes de modificar una copia de modelo. Una mejora local no acredita toda la sala.

## Reproducción

`Tools/FormaRadialProjection.h` contiene el proyector. `Tools/mvs-texturing-forma.patch` contiene los cambios del worker. Para reconstruir, copiar el header a `libs/tex/forma_radial_projection.h` y aplicar el patch sobre la revisión/dependencias de `build/Tools/MVS_TEXTURING_BUILD.md`. Conservar los avisos de licencia al distribuir. Los binarios congelados v1/v2 y sus hashes quedan junto a los manifiestos de ejecución.
