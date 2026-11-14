# Continuación Gaussian de la sala: 3000 → 3500 → 5000

Evaluación local realizada el 15 de octubre de 2026 sobre una copia del checkpoint nativo de la sala. A 5000 pasos las tres vistas medidas mejoran su PSNR y SSIM frente a 3000. Las vistas 283 y 565 alcanzan mejores resultados a 3500 que a 5000; la vista 0 sigue mostrando detalle borroso. La prueba no demuestra una mejora monótona, precisión geométrica ni superioridad sobre Polycam.

## Entradas y ejecución

Se empleó el dataset de 566 fotografías de `Incoming/8CA53ED6-74E0-4AAB-9B13-6E562562081F/dataset` y el checkpoint de 3000 pasos de la ejecución `6E1C75AF-6514-403F-80F2-6AFD1D1F4A71`. Las rutas absolutas y los SHA256 individuales están en los manifiestos de evidencia. El dataset contiene 530 fotogramas `streamRGBD` y 36 fotos `highResolution`.

El [harness independiente](../Tools/benchmark_gaussian_continuation.mm) carga una copia exacta del checkpoint y todos sus momentos Adam mediante la API C del motor Metal para macOS. Usa un autorelease pool por paso, como la ruta de producción. No modifica el código del motor, el dataset, el checkpoint original, la biblioteca de Forma ni el iPhone. No utiliza ComfyUI ni servicios de red.

La configuración formal fue:

| Parámetro | Valor |
| --- | --- |
| Horizonte de la curva de aprendizaje (`iterations`) | 30000 |
| Fin del refinamiento nativo (`stopDensifyAt`) | 30000 |
| `downscaleFactor` | 1 |
| `numDownscales` | 0 |
| `keepCrs` | true |
| Armónicos esféricos | grado 3 |
| Estados evaluados | 3000, 3500, 5000 |
| Población en esos estados | 425928, 425928, 564381 |

Se mantuvieron las operaciones nativas de división, duplicación y poda; no se añadió un límite de población. El primer refinamiento de la continuación cambió 425928 a 349714 Gaussianas y los siguientes aumentaron la población hasta 564381. Por tanto, se preservaron los archivos originales, pero no se pretende que la topología aprendida permanezca idéntica. No se redujo la resolución de las fotos ni se truncaron los puntos para la evaluación.

El [directorio formal](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/) contiene un checkpoint, PLY con SH3, SPLAT y los tres PNG en cada estado. La ejecución terminó correctamente. Los derivados permanecen separados de la biblioteca del usuario.

## Medición

Los índices se refieren al orden cronológico de `dataset.json`; el harness los relaciona con la cámara nativa por el nombre exacto del archivo. Son tres fotografías ya utilizadas para entrenar, **no vistas reservadas**.

| Índice cronológico | ID de fotograma | Índice nativo | Resolución evaluada |
| ---: | --- | ---: | --- |
| 0 | C5E81472-7310-4B0E-A41A-3BF478679B1D | 445 | 3840 × 2160 |
| 283 | D57CBC28-36E2-41BA-AD2C-99B1AA8950B5 | 475 | 3840 × 2160 |
| 565 | AF41061B-731E-419F-AB9E-36FF365E3A4C | 388 | 4224 × 2376 |

Se renderizó mediante `msplat_trainer_render` y se decodificó la referencia mediante `imreadRGB`, la misma ruta nativa de lectura del motor. L1 y RMSE son medias sobre todos los componentes RGB float; PSNR es `−10 log10(MSE)` para referencia RGB en escala 0–1. Las métricas se calculan antes del recorte de valores y cuantización usados exclusivamente para escribir el PNG. No se redimensiona el raster.

SSIM usa la implementación CPU existente `ssim_eval`: ventana gaussiana 11 × 11, sigma 1.5, bordes replicados y media de los tres canales. No se usan los ceros que devuelve la API de evaluación cuando el dataset carece de conjunto reservado.

Los siguientes valores reproducen los números de [room-3000-to5000-horizon30000-pooled/comparison.json](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/comparison.json), sin redondear deliberadamente a tres decimales. L1 y RMSE menores son mejores; PSNR y SSIM mayores son mejores.

| Vista | Pasos | L1 RGB | RMSE RGB | PSNR, dB | SSIM |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 3000 | 0.1984398393861859 | 0.25724565990449083 | 11.793038873229404 | 0.6662802696228027 |
| 283 | 3000 | 0.05883704197619993 | 0.11174378905420439 | 19.03553212981724 | 0.8581902384757996 |
| 565 | 3000 | 0.06882196993269626 | 0.11618466444212724 | 18.697023839548535 | 0.6762853264808655 |
| 0 | 3500 | 0.20217174595777426 | 0.26209186523836703 | 11.63092916801303 | 0.668618381023407 |
| 283 | 3500 | 0.05101021148821893 | 0.09614309563667009 | 20.34163796944812 | 0.8718919157981873 |
| 565 | 3500 | 0.06213923775661943 | 0.10673284245518709 | 19.434038490165563 | 0.6862650513648987 |
| 0 | 5000 | 0.19092425118238335 | 0.2518711309322094 | 11.976432155820667 | 0.6798510551452637 |
| 283 | 5000 | 0.052140566954834364 | 0.09958585976747183 | 20.03604645661084 | 0.8688612580299377 |
| 565 | 5000 | 0.06248769429462655 | 0.10816074782738833 | 19.318606373280776 | 0.6841256022453308 |

Frente a 3000, el PSNR a 5000 aumenta aproximadamente 0.183 dB, 1.001 dB y 0.622 dB en las vistas 0, 283 y 565, respectivamente. A 3500 la vista 0 empeora en L1, RMSE y PSNR, aunque aumenta ligeramente SSIM. Estos resultados mixtos impiden elegir el número de pasos como garantía de calidad. La vista 0, con PSNR final de 11.976432155820667 dB, sigue siendo una debilidad visible de esta reconstrucción.

## Tiempo, memoria y validez numérica

| Medida | Resultado |
| --- | ---: |
| Entrenamiento adicional hasta 3500 | 76.40638229099568 s |
| Entrenamiento adicional total hasta 5000 | 282.7488212910248 s |
| Intervalo medido después de la carga inicial, con evaluación, guardados, exportaciones y hashes finales | 297.62166583398357 s |
| Pico RSS del proceso durante su vida | 4036.671875 MiB |
| Mayor huella física entre las muestras registradas | 4337.284477233887 MiB |

El intervalo de 297.62 s **no incluye** los hashes iniciales, la copia ni la carga inicial del trainer. El máximo de huella física es un máximo observado en las muestras de etapa/evaluación, no una medición continua que garantice el pico real. Las cifras proceden de esta Mac y esta sala; no representan un rendimiento general ni una comparación de velocidad con otras aplicaciones.

Se comprobaron independientemente los 18 tensores completos de cada checkpoint y todos fueron finitos. Los seis grupos de segundos momentos Adam fueron no negativos en 3000, 3500 y 5000. La escritura nativa del checkpoint también conserva su validación. Las evidencias son el [estado original](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/source-checkpoint-validation.json), el [estado 3500](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/step-3500/checkpoint-validation.json) y el [estado 5000](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/step-5000/checkpoint-validation.json).

## Integridad y artefactos

Los 571 hashes SHA256 de entrada coinciden exactamente antes y después: las 566 fotos, `dataset.json`, `cameras.txt`, `images.txt`, `points3D.txt` y el checkpoint original. Esto comprueba las entradas de este entrenamiento Gaussian; no afirma haber vuelto a medir todos los archivos de profundidad/confianza de la captura, que este experimento no consume.

| Entrada | SHA256 conservado |
| --- | --- |
| Checkpoint original 3000 y su copia | `7ce92059d9cf72fb20836cc9bf352dd0aba9daa1b8e1f641e51c510aab299be1` |
| `dataset.json` | `74022374a2d313a865b8b8128ab4e8fc46290d694b03537baa12b50b62304e7e` |
| `cameras.txt` | `3849592b0e00ce7f4d17081241e9a92d3267adf4a48317beb3b1c858232e26d9` |
| `images.txt` | `ab38bfa872711375f1043b2372e3464a93f986d5e3e8075180aab921760eae34` |
| `points3D.txt` | `74fbc8d3873efbbc0af8fe8a831146c6e7052fb67d30593d0fdbde64221a245f` |

El campo histórico `nativeSourceSHA256` de `configuration.json` designa el checkpoint de origen, no una huella del código C++.

Las huellas de implementación registradas en `comparison.json` son:

| Artefacto | SHA256 |
| --- | --- |
| Harness `Tools/benchmark_gaussian_continuation.mm` | `372cf1ab1bbcd604363d0ff5fcd926e2e446aac05815d0890a9f7c96195ec68f` |
| Ejecutable `benchmark-pooled` | `c29f5310c78375d406d2a16292fdcb44ec756dcb24e67e75d8a46b823943c34f` |
| Biblioteca nativa `libmsplat_core.a` | `3de09b4ec57f0f4458ed7f632a5aab028deb882d667abf13eb52711f3626d537` |
| Shader `msplat-macos.metallib` | `794a2af3f3ab86bad25bfe2163c4b00fd47e0bfb87143deb8e534a025ba4a532` |

Evidencias completas:

- [Comparación y huellas de implementación](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/comparison.json).
- [Resumen de ejecución y memoria](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/summary.json), [etapas](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/stages.json) y [configuración](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/configuration.json).
- [SHA256 anteriores](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/input-sha256-before.json) y [posteriores](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/input-sha256-after.json).
- [Renderizados, checkpoint, PLY y SPLAT a 3000](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/step-3000/), [3500](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/step-3500/) y [5000](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/step-5000/).
- [Log local de la ejecución](/tmp/forma-gaussian-quality-continuation-pooled.log). El archivo de `/tmp` es temporal; los JSON y resultados anteriores son la evidencia persistente dentro del workspace.

Se conserva aparte un intento preliminar, detenido cooperativamente en 3309 al introducir el drenaje de autorelease por paso que faltaba en el harness directo. El ensayo formal se reinició desde el checkpoint original 3000, con esa corrección. Las métricas de este documento proceden únicamente de la ejecución `pooled`; no se mezclan ambos intentos.

## Límites causales y siguiente experimento propuesto

Cambiar el horizonte de 3000 a 30000 modifica más que el número de actualizaciones. El [scheduler](../Vendor/Msplat/core/src/model.cpp) calcula `t = clamp(step / maxSteps, 0, 1)` e interpola logarítmicamente la tasa de posiciones. El checkpoint original almacena una tasa de `1.6000004734451068e-6`; el checkpoint de 3500 almacena `9.349468018626794e-5` y el de 5000 `7.42654301575385e-5`. El primer paso reanudado usa la tasa restaurada y el scheduler cambia los siguientes.

Además, extender `stopDensifyAt` reactiva la política nativa de refinamiento y el reset de opacidad en 3100. Ese reset limita los logits de opacidad superiores a `−1.3862943611198906` a ese valor, equivalente a alfa 0.2, y reinicia los momentos Adam del grupo de opacidad. Por ello, la continuación mide conjuntamente más actualizaciones, distinta curva de aprendizaje, reset de opacidad y cambios de topología. No se pueden separar sus aportaciones con estos resultados.

El checkpoint tampoco guarda la posición del cursor ni el estado RNG de la selección de cámaras. Al cargarlo, el trainer vuelve a barajar la lista. El ensayo es una continuación reproducible desde un estado guardado con la política de reanudación del motor; no una reproducción exacta del orden de cámaras de una sesión ininterrumpida.

El brazo de control propuesto se ejecutó posteriormente sobre otra copia idéntica de 3000, manteniendo `iterations=3000` y `stopDensifyAt=3000`. La API nativa permite avanzar más allá de ese horizonte; el scheduler se queda en su tasa final y el refinamiento/reset permanecen inactivos. Se conservan las 566 fotos completas, SH3, todas las Gaussianas iniciales y todo su estado Adam. Mantener temporalmente la topología es un control experimental para aislar las actualizaciones adicionales; no se propone convertirlo en una cuota de producción.

En ese control se registraron las mismas etapas y métricas, primero comprobando que cargar sin actualizar reproduce exactamente las métricas base. Un conjunto mayor de vistas fijado antes de ejecutar reduciría el sesgo de las tres elegidas, pero seguiría siendo un conjunto observado durante el entrenamiento. Para medir generalización hace falta entrenar desde el inicio con vistas reservadas; reservarlas ahora no elimina la exposición previa del checkpoint.

Los resultados de ese control constan a continuación. Ninguno de los dos brazos justifica aumentar pasos automáticamente ni prometer superar Polycam.


## Control posterior: horizonte terminal 3000/3000

La ejecución aislada con `iterations=3000` y `stopDensifyAt=3000` terminó correctamente en 5000 pasos. La API nativa permite esas actualizaciones posteriores al horizonte; no se cambió el comportamiento del worker ni de las apps. El [harness de control](../Tools/benchmark_gaussian_terminal.mm) mantiene el método anterior, con los dos parámetros terminales y comprobaciones explícitas de población y tasa constantes. El harness del brazo 30k conserva su huella original.

Las tres métricas base a 3000 coinciden exactamente con las del primer brazo. En 3000, 3500 y 5000 se conservaron **425928 Gaussianas**, la tasa de posiciones fue exactamente **1.6000004734451068e-6**, los 18 tensores fueron finitos y todos los segundos momentos Adam fueron no negativos. El log registra **cero resets de opacidad y cero densificaciones**. No se redujo resolución ni se eliminaron fotos o puntos para imponer una cuota.

| Vista | Pasos | L1 RGB terminal | RMSE RGB terminal | PSNR terminal, dB | SSIM terminal |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 3000 | 0.1984398393861859 | 0.25724565990449083 | 11.793038873229404 | 0.6662802696228027 |
| 283 | 3000 | 0.05883704197619993 | 0.11174378905420439 | 19.03553212981724 | 0.8581902384757996 |
| 565 | 3000 | 0.06882196993269626 | 0.11618466444212724 | 18.697023839548535 | 0.6762853264808655 |
| 0 | 3500 | 0.1994340099388563 | 0.2596944457964851 | 11.710746774509262 | 0.6663629412651062 |
| 283 | 3500 | 0.0524888057403563 | 0.10148423654726836 | 19.872028221458613 | 0.8670049905776978 |
| 565 | 3500 | 0.06301310929562229 | 0.10936562332747936 | 19.222383348960584 | 0.6825922131538391 |
| 0 | 5000 | 0.19554532449707712 | 0.2559939605120896 | 11.83540561151403 | 0.6746512055397034 |
| 283 | 5000 | 0.047582377122587886 | 0.09304912060564538 | 20.62575453941664 | 0.874070942401886 |
| 565 | 5000 | 0.05910795858866554 | 0.10381432575432648 | 19.674854246367428 | 0.6868147850036621 |

A 5000, frente al checkpoint original, el PSNR aumenta 0.04236673828462578 dB en la vista 0, 1.5902224095993986 dB en la 283 y 0.9778304068188923 dB en la 565. Frente al brazo de horizonte 30k a los mismos 5000 pasos, las diferencias son respectivamente −0.1410265443066372 dB, +0.5897080828057994 dB y +0.3562478730866516 dB. SSIM también favorece al terminal en las vistas 283/565 y al brazo 30k en la vista 0.

El control muestra que actualizaciones adicionales con la política terminal conservada mejoran estas tres vistas al final, con una ganancia pequeña en la 0. Esa vista sigue débil y su PSNR primero cae en 3500. No hay un ganador universal entre políticas ni se demuestra calidad en vistas nuevas. Comparar los brazos permite distinguir ambas políticas, pero no separar por sí solo cuánto aporta cada cambio de LR, reset y refinamiento del brazo 30k.

El entrenamiento adicional consumió **307.6764907920733 s**. El intervalo posterior a la carga inicial, incluyendo evaluaciones, guardados, exportaciones y hashes finales, fue **322.93545654206537 s**. El pico RSS fue **3908.71875 MiB** y la mayor huella física muestreada **4148.065635681152 MiB**. Se aplican las mismas limitaciones de medición que al primer brazo; estas ejecuciones no constituyen una comparación de velocidad controlada.

Los **571 SHA256** coinciden antes/después y también con los del brazo 30k. El checkpoint original conserva `7ce92059d9cf72fb20836cc9bf352dd0aba9daa1b8e1f641e51c510aab299be1`. También se comprobó que la biblioteca nativa, el shader y el harness anterior conservan las huellas registradas. No se modificaron Vendor, las apps, el iPhone ni la biblioteca del usuario.

- [Comparación exacta, diferencias y huellas del control](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/comparison-terminal-vs30k.json).
- [Resumen del control](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/summary.json), [configuración](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/configuration.json) y [etapas](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/stages.json).
- [SHA256 anteriores](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/input-sha256-before.json) y [posteriores](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/input-sha256-after.json).
- [Estado 3000](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/step-3000/checkpoint-validation.json), [3500](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/step-3500/checkpoint-validation.json) y [5000](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/step-5000/checkpoint-validation.json).
- [Derivados y PNG a 3000](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/step-3000/), [3500](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/step-3500/) y [5000](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/step-5000/).

Este control cierra los entrenamientos de este experimento. Los resultados derivados permanecen aislados para su comparación.
