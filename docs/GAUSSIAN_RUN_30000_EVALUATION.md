# Evaluación preparada para el run Mac de 30000 pasos

Actualización del 15 de octubre: el estado de este run quedó `cancelled` en 20,207 pasos y el PID 51835 ya no existe. Su checkpoint permanece intacto. No se reanudó ni se ejecutó este evaluador sobre una salida incompleta. Las referencias al trabajador activo más abajo describen la preparación histórica del ensayo.

Esta es una receta preparada, **no un resultado de calidad del entrenamiento nuevo**. No se ha renderizado su modelo ni ejecutado GPU para esta evaluación mientras entrena el worker 51835. No se han enviado controles ni pausado, cancelado o modificado el trabajo.

El trabajo es `FAC12FBD-D8D3-471F-B107-558A10F3A58F`, run `A26E5CCA-D562-4A4A-B094-E82EFA011213`. Su configuración declara `targetIterations=30000`, `downscale=1` y no contiene `resumePath`. El inicio del log registra `iteration=0` y 199868 Gaussianas al arrancar la fase `running`: parte de la inicialización, en lugar de cargar el checkpoint 3000 usado por las continuaciones anteriores.

La ruta declarada de fuentes es `~/Library/Application Support/FormaDesktop/Incoming/8CA53ED6-74E0-4AAB-9B13-6E562562081F/dataset`. El índice de las 566 observaciones tiene SHA256 `74022374a2d313a865b8b8128ab4e8fc46290d694b03537baa12b50b62304e7e`, igual al índice de los comparadores. La comprobación de los otros archivos se realiza al evaluar; no se sustituye por una afirmación basada sólo en ese índice.

El [bridge nativo](../Vendor/Msplat/core/src/forma_bridge.mm) fija `keepCrs=true`, `numDownscales=0` y `stopDensifyAt=iterations`, aquí 30000. Por tanto, este run mantiene el refinamiento nativo disponible hasta el final del horizonte. Sus operaciones de división, duplicación, poda y reset de opacidad son parámetros del algoritmo, no cuotas de población. La curva de aprendizaje de posiciones también usa ese horizonte desde el inicio.

## Invocación al terminar

Desde la raíz del workspace, una vez que el entrenamiento termine y el worker salga:

```sh
python3 Tools/evaluate_gaussian_run.py \
  --run '~/Library/Application Support/FormaDesktop/Work/Gaussian-FAC12FBD-D8D3-471F-B107-558A10F3A58F/runs/A26E5CCA-D562-4A4A-B094-E82EFA011213' \
  --output 'build/Research/GaussianRun30000/FAC12FBD-A26E5CCA-final'
```

El directorio de salida debe ser nuevo. El script no espera ni vigila: si el run no está `completed` en 30000, si vive un `FormaGaussianWorker` o si el worker conserva su bloqueo, sale antes de crear salida, compilar, cargar un modelo o llamar a Metal. No reanuda ni controla ningún proceso. El bloqueo de lectura durante la evaluación no cambia el contenido de los archivos de trabajo y evita abrir simultáneamente ese workspace con otro worker.

Para inspeccionar exclusivamente la identidad y configuración, sin compilar, cargar modelos ni renderizar:

```sh
python3 Tools/evaluate_gaussian_run.py --inspect
```

Esta herramienta está acotada a los ID de este ensayo y sus 566 fotogramas; esa verificación de identidad pertenece al experimento, no impone un límite a las apps.

## Método y comprobaciones

El [script](../Tools/evaluate_gaussian_run.py) verifica que el resultado final pertenece al run y usa el detalle declarado. Después valida un [snapshot inmutable del runtime anterior](../build/Research/GaussianRun30000EvaluationPreparation/frozen-runtime/snapshot.json), fijado por SHA256 `43dcc6a039966bd855b3b8c953989a09f76bbb93fe06aadd6e76869d4becbacc`. Comprueba cada archivo de ese snapshot y el ABI 2 declarado por run/exportación. No usa ni pretende validar como equivalentes el Vendor, archivo nativo o helper reconstruidos después.

Durante este entrenamiento, la reconstrucción para el nuevo lease atómico reemplazó `build/GaussianDesktopWorker/native/libmsplat_core.a`. El archive original con SHA256 `3de09b4ec57f0f4458ed7f632a5aab028deb882d667abf13eb52711f3626d537` ya no está retenido; los otros archives encontrados tenían huellas distintas y no se usaron. Sí se conservó el evaluador compilado **antes** de ese cambio, con SHA256 `891f9378d6b39aaf0a34f9344e3fbf91fdf4f24ed0d3ed42c6324d6336e6d678`: contiene estáticamente el código del archive anterior. Se conservaron su fuente exacta y comando de compilación, junto con helper, shader y manifest del app 0.9.1. Las huellas del helper y shader se comprobaron contra ese manifest al capturarlos.

La evaluación reutiliza ese ejecutable exacto sin reenlazar. Esto permite repetir la medición con los artefactos retenidos; no permite reconstruirla desde el archive original ausente. El reporte declara esa limitación y que el `sourceFingerprint` histórico difiere del código actual. Si cambia cualquier artefacto fijado, rechaza la ejecución; no relaja las comprobaciones de compatibilidad ni selecciona silenciosamente otro archive.

Después calcula SHA256 de las 566 fotografías y los cuatro archivos de entrada `dataset.json`, `cameras.txt`, `images.txt`, `points3D.txt`: 570 entradas del dataset. Deben coincidir individualmente con el manifiesto del baseline. Añade por separado las huellas del checkpoint y PLY finales. Copia sólo el checkpoint y los pequeños artefactos fijados del evaluador a su propia salida; no copia ni modifica las fotografías y no importa derivados en la biblioteca.

La utilidad nativa conservada reutiliza las funciones de medición del harness original. Se comprueban la huella del harness y la igualdad de su código de evaluación con la fuente del ejecutable fijado; no se compila contra el archive nuevo. Su código generado carece de llamadas para avanzar entrenamiento o guardar checkpoints. Carga la copia y ejecuta exactamente tres renderizados con la API nativa, sin redimensionar:

| Vista cronológica | Fotograma | Resolución de referencia |
| ---: | --- | --- |
| 0 | C5E81472-7310-4B0E-A41A-3BF478679B1D | 3840 × 2160 |
| 283 | D57CBC28-36E2-41BA-AD2C-99B1AA8950B5 | 3840 × 2160 |
| 565 | AF41061B-731E-419F-AB9E-36FF365E3A4C | 4224 × 2376 |

Los índices nativos se encuentran por archivo/ID, sin asumir que coinciden con el orden cronológico. La referencia RGB se decodifica con `imreadRGB`, igual que en las mediciones anteriores. Se calculan L1, RMSE y PSNR sobre todos los componentes float RGB antes del recorte/cuantiﬁcación de PNG. SSIM usa `ssim_eval` CPU existente: ventana gaussiana 11 × 11, sigma 1.5, bordes replicados y media RGB. No se usa el cero que proporciona la API de evaluación cuando el dataset carece de conjunto reservado.

Se recorren íntegramente los 18 tensores del checkpoint: parámetros, armónicos esféricos y momentos Adam deben ser finitos; los seis segundos momentos deben ser no negativos. Se recorre además **cada float del PLY completo**, comprobando población igual al checkpoint y los 45 coeficientes SH adicionales de grado 3 por Gaussiana. El bloque de lectura de 4096 registros es sólo memoria temporal; no elimina registros ni trunca el modelo. Si el formato o un valor no cumple, el ensayo falla y conserva su salida parcial para diagnóstico, sin sustituir valores.

Al final vuelve a medir los SHA256 del dataset y de los dos originales evaluados. Comprueba también que su copia de checkpoint no cambió. La salida principal contiene:

- `comparison.json`: métricas completas, diferencias respecto a los comparadores, configuración y huellas reproducibles.
- `evaluation.json` y `view-0.png`, `view-283.png`, `view-565.png`: renderizados nativos completos; el JSON declara cero pasos de entrenamiento ejecutados.
- `checkpoint-validation.json`, `ply-validation.json`: validez numérica y población sin truncar.
- `input-sha256-before.json`, `input-sha256-after.json`: integridad por archivo.
- `run-config.json`, `run-status.json`, `export-metadata.json`, `source-worker.log`, `training-log-summary.json`: procedencia y eventos reales de refinamiento/reset.
- `worker-artifacts.json`, `runtime-snapshot.json`, fuente y ejecutable fijados, shader y comando original de compilación; log de ejecución. El archive original no se incluye porque ya no está disponible.

## Comparadores y límites de interpretación

La comparación usa los datos ya conservados del [baseline Mac 3000 y continuación de horizonte 30k a 5000](../build/Research/GaussianQualityContinuation/room-3000-to5000-horizon30000-pooled/comparison.json) y del [control terminal a 5000](../build/Research/GaussianQualityContinuation/room-3000-to5000-terminal3000-pooled/comparison-terminal-vs30k.json). El método de esos ensayos y sus confusiones están en [GAUSSIAN_QUALITY_CONTINUATION.md](GAUSSIAN_QUALITY_CONTINUATION.md).

Este run nuevo usa desde el inicio una curva de aprendizaje y calendario de refinamiento de 30000. Los otros brazos terminaron con otra política o reanudaron un estado guardado. Las diferencias no aíslan únicamente el número de pasos, la tasa de aprendizaje, la opacidad o la densificación. Las cifras de memoria del evaluador describen evaluación, no el pico del entrenamiento original. No se presenta una comparación de velocidad controlada.

Las tres cámaras son vistas de entrenamiento, no vistas reservadas. Un mejor PSNR/SSIM aquí mide ajuste de esas imágenes; no prueba generalización, precisión métrica ni que Forma supere Polycam. Hay que revisar también las imágenes y declarar cualquier retroceso. No se elegirá sólo la mejor vista ni se ocultará la vista 0, que fue débil en los ensayos anteriores.

## Verificación hecha durante la preparación

Se ejecutó `--self-test`: fixture SH3 pequeño completo, rechazo de NaN/truncamiento y comprobación de que el código generado no contiene llamadas de entrenamiento. Se compiló la utilidad nativa sin ejecutarla, antes de reemplazar el archive; posteriormente se conservaron sus bytes y se validaron los hashes exactos del snapshot. Se invocó el flujo normal mientras el run seguía activo y se verificó que rechazó la operación **antes de crear el directorio de evaluación**. No hubo llamadas a Metal.

Los artefactos de esa comprobación están en [GaussianRun30000EvaluationPreparation](../build/Research/GaussianRun30000EvaluationPreparation/), incluido [el rechazo del run activo](../build/Research/GaussianRun30000EvaluationPreparation/live-worker-rejection.log). No contienen resultados ni métricas del run nuevo.
