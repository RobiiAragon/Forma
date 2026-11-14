# Validación de Forma 0.5

Registro del 15 de octubre de 2026. Documenta únicamente tandas y resultados terminados que se han confirmado. Distingue pruebas de algoritmo, aplicación, transporte loopback y procesamiento real. Los trabajos en curso no se cuentan como aprobados; las pruebas generales y la regresión posterior de recuperación se distinguen.

## Pruebas confirmadas

| Entorno y alcance | Aprobadas | Omitidas | Fallos |
| --- | ---: | ---: | ---: |
| Simulador: unitarias, 119 ejecuciones | 116 | 3 | 0 |
| Simulador: interfaz, tanda separada | 2 | 0 | 0 |
| iPhone físico: selección de unitarias | 118 | 0 | 0 |
| Mac: procesamiento cooperativo y archivos | 54 | 0 | 0 |
| Mac: charts y atlas | 19 | 0 | 0 |
| Mac: transporte TCP loopback | 5 | 0 | 0 |
| Mac: preparación de entradas fotográficas | 4 | 0 | 0 |
| Simulador: recuperación posterior, selección independiente | 9 | 0 | 0 |
| iPhone físico: fixture de Wi-Fi y USB, tanda independiente | 1 | 0 | 0 |

Los casos se repiten entre suites y plataformas; esta tabla no suma pruebas únicas. La regresión posterior de recuperación contiene seis casos anteriores y tres nuevos: no son nueve pruebas únicas adicionales ni una repetición de toda la selección física después de ese cambio. Las dos pruebas de interfaz pertenecen a una ejecución distinta de la suite unitaria final. Las tres omisiones del simulador son la consulta de formatos físicos de ARKit, el entrenamiento Metal nativo y la captura RGB-D real. La selección física excluyó `PhysicalCaptureTests`: no prueba una nueva captura en vivo completa.

La suite del simulador terminó con `TEST SUCCEEDED` y la selección física con `TEST EXECUTE SUCCEEDED`. Registros: [unitarias del simulador](/tmp/forma-v5-sim-final.log), [interfaz](/tmp/forma-v5-ui.log), [iPhone físico](/tmp/forma-v5-device-final-tests.log), [54 casos Mac](../build/Research/processing-tests/results.log), [19 casos de charts/atlas](../build/Research/texture-chart-tests/results.log), [cinco comprobaciones loopback](/tmp/forma-hybrid-verify.log), [cuatro de preparación fotográfica](/tmp/forma-photoinput-verify.log) y [nueve de recuperación posterior](/tmp/forma-v5-restore-tests.log). Los paquetes completos están en [FormaV5SimulatorFinal.xcresult](../build/FormaV5SimulatorFinal.xcresult), [FormaV5UI.xcresult](../build/FormaV5UI.xcresult), [resultado físico final de esa tanda](../build/device-v5-final-tests-20261015T091647.xcresult) y [regresión de recuperación](../build/FormaV5RestoreRecovery.xcresult).

## Sensor, previsualización y modo híbrido

La prueba física enumeró los formatos reales ofrecidos por ARKit, incluidos 3840 × 2160 a 30, 25 y 24 FPS; no ofreció un formato de 15 FPS. El formato seleccionado reportó **24 FPS** y el objetivo de la previsualización fue **15 FPS**. Se comprueba la configuración y su procedencia: no se presenta ese objetivo como una frecuencia ficticia del sensor ni como una medición de fotogramas efectivamente mostrados. La frecuencia observada del visor y la captura del sensor son medidas distintas.

El modo Híbrido guarda primero la malla y las fuentes RGB-D en el iPhone y transmite después de capturar. Wi-Fi es la opción inicial; USB-C es la alternativa mediante el helper local descrito en la guía Mac. No se anuncia transmisión del sensor en tiempo real.

Las cinco comprobaciones loopback ejercitaron transmisión de 8 MiB + 33 bytes y malla, hashes y confirmación después del commit; rechazo de clave incorrecta; cancelación y limpieza; las dos direcciones del protocolo; y conservación de las fuentes. Son conexiones TCP reales en el mismo Mac. Un ensayo posterior y separado sí comprobó el transporte físico: **un XCTest del iPhone aprobado, sin fallos ni omisiones, en 10.952 s**, realizó dos transferencias del mismo fixture de **8,388,641 bytes y malla**. Wi-Fi y USB produjeron dos confirmaciones después de guardar, con bytes y SHA-256 coincidentes y `ORIGINALS_UNCHANGED`.

En Wi-Fi se descubrió un endpoint Bonjour asociado a `en0` y el endpoint de carga quedó ligado a Wi-Fi. Una conexión de sondeo al mismo endpoint informó `NWPath` Wi-Fi; esa observación corresponde al sondeo, no a una instrumentación de la conexión de carga interna. USB usó `iproxy -l -u` con el identificador exacto del teléfono y la opción de reenvío exclusivamente USB local. No se usó nube.

El alcance es un fixture controlado del protocolo en los dos transportes físicos. **No valida el dataset completo de la sala ni la interfaz de emparejar y capturar.** Evidencia: [registro del XCTest físico](/tmp/forma-hardware-physical-tests.log), [resultado completo](../build/Validation/HybridHardwarePhysicalFinal/HardwareFixture.xcresult) e [informe de recepción y rutas](../build/Validation/HybridHardwarePhysicalFinal/hardware-report.json).

Referencias: [Forma Desktop](FORMA_DESKTOP.md), [prueba de transporte](../Tools/verify_hybrid_transfer.swift), [preparación fotográfica](../Tools/verify_photogrammetry_input.swift) y [configuración comprobada en el registro físico](/tmp/forma-v5-device-final-tests.log).

## Captura real procesada en la aplicación Mac

Forma Desktop 0.5 Release procesó desde los **566 fotogramas calibrados originales** y guardó la captura `28D5F554-465E-48FC-BEA0-BA9F3414C146`. Se comprobó manualmente que la pausa fue reconocida y que reanudar continuó el procesamiento —del 21.885 % al 23.0046 %— hasta guardar. El tiempo registrado puede incluir esa pausa.

| Resultado guardado | Valor |
| --- | ---: |
| Vértices / caras | 199,383 / 366,954 |
| Caras con observación fotográfica | 244,786 |
| Caras neutras | 122,168 |
| Cobertura por número de caras | 66.7075 % |
| Materiales fotográficos / totales con el neutro | 42 / 43 |
| Píxeles de atlas | 688,198,711 |
| Bytes de atlas | 309,348,295 |
| Selección fotográfica | 46.299469 s |
| Evaluación fotométrica / decodificaciones | 13.747524 s / 562 |
| Coherencia / atlas | 13.099121 / 50.606105 s |
| Texturizado total registrado | 124.287504 s |
| Ajustes de exposición aceptados | 0 |

El registro anterior del iPhone fue de 835.087 s, pero varían hardware, código, compilación y condiciones de pausa. No establece un factor controlado de aceleración. Tampoco representa 124 s de reconstrucción fotogramétrica Raw: es otra operación, el texturizado de la malla LiDAR. La cobertura cuenta caras y no mide qué porcentaje de toda la sala está completo.

Los metadatos se preservaron en [informe Mac](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/MacGUI-28D5F554/informe.json) y [procedencia y hashes de los metadatos](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/MacGUI-28D5F554/evidence.json). La biblioteca de origen permanece en `~/Library/Application Support/FormaDesktop/Library`.

## Integridad del resultado Mac

Una verificación independiente leyó por bloques de 1 MiB **todas las 2,327 entradas** de `integridad.json`. Los 2,327 tamaños y SHA-256 coincidieron: **2,832,306,840 bytes** de contenido. El inventario coincide exactamente, sin nombres inseguros, duplicados, archivos faltantes o adicionales, enlaces simbólicos ni archivos especiales. El manifiesto y los archivos permanecieron estables durante la lectura.

Esta comprobación no reconstruyó modelos, abrió interfaz ni modificó el resultado. SHA-256 comprueba integridad respecto al manifiesto, no precisión dimensional o fidelidad fotográfica. [Evidencia completa](../build/Comparison/2026-10-15/NewRoom-v0.4/Mac-v0.5/integrity-verification.json).

## Atlas por regiones: otra ejecución de conservación

El benchmark separado reempaquetó el OBJ y sus texturas ya existentes, conservando vértices, normales, índices y orden de las 366,954 caras. Pasó de 387 a 41 materiales fotográficos —388 a 42 con el neutro— y de 3,905,749,740 a 676,379,333 píxeles de imágenes: **82.68 % menos**. Los bytes de textura disminuyeron 91.12 %. Las fotografías originales mantuvieron sus hashes y la densidad nativa no se redujo.

Los pases de geometría neutral antes/después coinciden píxel a píxel. Se declararon diferencias pequeñas de color derivado: RMSE de 0.291 unidades RGBA8 y máximo de 2.391 sobre 255 en 16,596 muestras bilineales. Esta conservación pertenece al reempaquetado del OBJ; no se atribuye como comparación exacta de UV a la ejecución Mac que volvió a seleccionar fotografías desde el dataset.

El [informe de charts](TEXTURE_CHART_VALIDATION.md) separa ambas ejecuciones, sus tiempos y las 19 pruebas. El [comparador visual local](../build/Comparison/2026-10-15/NewRoom-v0.4/Charts-v0.5/index.html) mantiene vistas con igual cámara y escala. La captura continúa mostrando zonas neutras y fragmentación; estos resultados no demuestran mayor detalle físico, FPS mejores ni superioridad frente a Polycam.

## Instalación y recuperación de la sala

El script de instalación completó `--build-only` y una ejecución completa de compilación, comprobación de firma e instalación. Forma 0.5 Release quedó instalada y se abrió después. El script conserva su contrato de no desinstalar, borrar documentos ni lanzar la app por sí mismo. [Registro de instalación completa](/tmp/forma-renewal-script-install.log) y [guía de instalación y renovación](IPHONE_INSTALLATION.md).

El usuario había borrado manualmente dos capturas y pidió restaurarlas; no había borrado la aplicación. La sala nueva `CB7D23D7-5C49-4986-9D93-220C10F7086A` se restauró y la aplicación recuperó su carpeta final. El teléfono leyó el contenido y generó un manifiesto; ese manifiesto se copió de vuelta al Mac y se contrastó con el respaldo preservado: **2,672 archivos, 9,097,707,412 bytes y todos los SHA-256 coinciden**, sin faltantes, extras ni discrepancias de tamaño o hash. El respaldo original del Mac permanece intacto; el único metadato nuevo es `integridad.json`. [Verificación de restauración física](../build/Comparison/2026-10-15/NewRoom-v0.4/Phone-v0.5/restoration-verification.json).

La captura original `0A7A1393-6D40-4E6F-ABC6-A6F09CFAE9D1` también se restauró y se leyó de vuelta: **sus siete archivos y 95,014,435 bytes coinciden exactamente en SHA-256 con el respaldo**. Ambas restauraciones quedan comprobadas. [Verificación de la captura original](../build/Comparison/2026-10-15/NewRoom-v0.4/Phone-v0.5/original-restoration-verification.json). Las nueve pruebas seleccionadas del simulador de recuperación sí terminaron sin fallos; su solapamiento con las tandas anteriores se declara en la tabla.

## Compilación Mac y reconstrucción Raw terminada

La nueva compilación Mac Release universal, con optimización `-O` y firma ad hoc comprobada, terminó y se copió a `/Applications/FormaDesktop.app`. [Registro de compilación universal](/tmp/forma-desktop-final-release.log) y [guía Mac](FORMA_DESKTOP.md). Esto no reemplazó ni interrumpió la reconstrucción Raw que ya ejecutaba la compilación anterior de `build/mac`.

Esa reconstrucción fotográfica Raw de la sala real terminó y guardó `9D475662-CF01-40E1-AD0A-F556E9004F8A`. El USDZ mide **323,963,360 bytes** y la lectura nativa USD coincide con Blender: **1,614,034 vértices, 3,227,473 triángulos, una capa UV y cuatro materiales**, con cuatro atlas PNG RGB de 8 bits de **8192 × 8192**. Los metadatos generales guardaron cero en caras/vértices; esos campos no se usan como conteos reales. El manifiesto conserva 566 fotos y la API notificó cero fotos omitidas y cero reducciones automáticas.

Se verificaron por lectura streaming todos los **2,278 archivos y 2,303,723,182 bytes** del manifiesto: nombres seguros, inventario exacto, tamaños y SHA-256 coincidentes, sin faltantes ni extras. El manifiesto y el USDZ quedaron intactos. Se generaron ocho vistas propias de Raw y del GLB aportado de Polycam, con texturas nativas y culling, sin alineación ni ajuste de escala. La mayor continuidad visible respecto al LiDAR anterior no prueba precisión física ni superioridad global frente a Polycam; siguen presentes huecos, fragmentos y deformaciones. [Inspección e imágenes Raw](RAW_ROOM_INSPECTION.md), [informe visual local](../build/Comparison/2026-10-15/NewRoom-v0.4/Raw-v0.5/index.html) y [verificación íntegra](../build/Comparison/2026-10-15/NewRoom-v0.4/Raw-v0.5/integrity-verification.json).

No se deriva un tiempo Raw del campo `duration: 0`; los 124.2875 s del apartado anterior son únicamente el texturizado LiDAR. Queda pendiente validar el envío de la captura completa y su flujo de emparejamiento/captura en la interfaz; el fixture físico de Wi-Fi y USB ya comprobado se documenta por separado arriba.
