# Validación de restauración local de texturas

Mediciones del 15 de octubre de 2026. Las pruebas de la sala de Forma 0.6 se hicieron en un Mac Apple M5 Max de 48 GB, con el motor Swift de producción compilado con `-O` y Core ML real (`cpuAndGPU`). La sección de iPhone 0.7 registra por separado sus propios tiempos y estados de segundo plano. No se ejecutó Comfy ni un servicio remoto para la inferencia.

## Gaussian continuo 0.7.2

Después de instalar 0.7.1, el usuario informó **«Vuelve a avisar de poca memoria»** durante su flujo real y pidió expresamente eliminar las pausas automáticas y cualquier máximo de avisos. Por ello el éxito nativo previo de 80 pasos no se registra como resolución del problema real. El último checkpoint respaldado antes de 0.7.2 está en el **paso 936**, factor 1: 397.936.232 bytes y SHA-256 `9621f59472d6383daf2617ac16bf6ec2d879d0b5b2955f886bd2a1ace3624638`.

Gaussian ahora usa `MobileProcessingPolicy.Mode.continuous`: no añade descansos ni espera enfriamiento en ninguno de los cuatro estados térmicos. El observador de memoria reside en el servicio de producción, no sólo en la pantalla; cada aviso añade telemetría sin cambiar fase, acción o causa de pausa. No hay un umbral de cantidad de avisos. La pausa manual prevalece sobre notificaciones de ciclo de vida. Las suspensiones necesarias de GPU al perder primer plano se reanudan al volver, conservando una exportación ya solicitada. La pantalla no se bloquea automáticamente durante ejecución/exportación. Cada 30 segundos, al terminar un paso, se guarda checkpoint atómico sin desmontar el motor ni pasar a pausa. Un fallo real de escritura o de asignación sigue siendo un error, no una cuota comercial.

`FormaV072FinalControlSimulator.xcresult` aprobó **40 casos** de dominio, control, modo continuo y política independiente de texturas. Los diez avisos usados en la aceptación física son entradas de prueba para el observador real, no un máximo permitido. La primera ejecución física no pudo iniciar el runner (`CoreDeviceError 10004`); la repetición sí entrenó desde el checkpoint 936 y encontró un fallo numérico al guardar después de activar armónicos esféricos en el paso 1000. Ese intento se registra como fallo y el original no fue modificado.

La firma gratuita y el perfil renovado autorizan `com.apple.developer.kernel.increased-memory-limit=true` para el iPhone conectado. Se verificaron ambos, no sólo el archivo fuente de entitlements. No se solicita Extended Virtual Addressing, que el Personal Team no autoriza. El perfil no garantiza una cantidad concreta de RAM; los ensayos registran la memoria disponible que informa iOS. El primer intento de renovación informó un perfil antiguo sin la capacidad y `No Accounts`; el perfil nuevo fue generado y la segunda compilación firmó correctamente. Evidencia: `build/Research/GaussianContinuous/increased-memory-authorization.json`.

La investigación posterior identificó el origen numérico: `Forma/Resources` seguía conteniendo metallibs anteriores, mientras el XCFramework ya reservaba el layout SSIM nuevo de nueve floats. Los shaders viejos escribían quince campos fuera de ese búfer. El checkpoint 936 tenía todos los tensores finitos, pero 11.826.661 segundos momentos SH negativos; al activar SH en el paso 1000 aparecía NaN. No era evidencia de insuficiencia física de RAM. El empaquetado ahora copia ambos recursos desde la misma compilación, registra hashes/fingerprint de fuentes y se verifica en cada build. El motor exige un kernel ABI 2 y readback GPU antes de iniciar buffers de entrenamiento. El test físico rechaza una biblioteca Metal de renderizado sin ABI y después entrena con la correcta.

La recuperación del checkpoint reconstruye únicamente los segundos momentos SH aún sin usar, antes del intervalo de activación, con coeficientes y primeros momentos exactamente cero, contador Adam coincidente y los 18 tensores finitos. No reescribe el original, no sustituye NaNs y rechaza estados activos inválidos. La sala real Mac completó **936→1046, 110 pasos**, validando estado finito en cada paso, densificación y checkpoint. Siete regresiones de caché/estado/densificación y cinco tamaños SSIM aprobaron; ocho densificaciones sintéticas conservaron cero en el SH inactivo al crecer de 32 a 8192 puntos.

`FormaV072FinalNativeProduction.xcresult` aprobó **28 casos físicos**, incluidos el rechazo ABI y el servicio `GaussianTrainerService` real sobre una copia de la sala del usuario: aviso inyectado en 945, diez notificaciones recibidas y avance hasta **1045** sin pausa automática. Después se confirmó pausa manual, checkpoint y reanudación. El SHA-256 del original 936 y su índice no cambiaron. El proceso informó 6.410.516.784 bytes disponibles al comenzar y 5.035.390.920 al final, con 12.104.073.216 bytes de memoria física. No es una medición continua de pico ni una comparación controlada con el perfil anterior.

Forma **0.7.2 build 9 Release** quedó instalada y abierta, con sus cinco directorios de captura conservados. Los hashes de los dos shaders del paquete real coinciden con los construidos; el verificador también rechazó una copia temporal con un shader antiguo. La firma/perfil contienen Increased Memory Limit. Este ensayo cubre el servicio real y 100 pasos posteriores a los avisos, no toda la sesión de 3000 ni la aceptación manual de la interfaz. El objetivo amplio de reestructuración, sensores, Mac y comparación continúa activo.

Los visores de fichas antecesoras se desmontan al navegar a copias/originales descendientes. Ésta es una diferencia de residencia concreta frente al fixture aislado, además de la población mayor que ya tiene la sesión del usuario en el paso 936.

## Corrección Gaussian 0.7.1: pausa repetida

El usuario informó que Gaussian avanzaba unos pasos y se pausaba otra vez al continuar, incluso con Forma visible, con un mensaje de petición de iOS. La ruta de ese mensaje responde a `didReceiveMemoryWarningNotification`; no demuestra temperatura crítica. También se encontró una contradicción térmica: el servicio pausaba cada cinco pasos con estado `serious`, aunque la política de trabajo/descanso ya debía continuar al 20 %.

La corrección conserva causas tipadas (memoria, temperatura crítica, inactividad, autorización y pausa manual) después del checkpoint. `serious` ya no fuerza una pausa de sesión; `critical` sigue liberando GPU y necesita enfriamiento. Continuar sincroniza actividad y acción en un solo bloqueo, evitando reanudar con un indicador de primer plano obsoleto. La memoria requiere una nueva acción explícita de reintento, conserva la resolución elegida y no se reintenta automáticamente en bucle.

El visor incrustado se desmonta durante Gaussian, igual que durante la restauración de texturas. El motor desaloja fotos antes de decodificar otra, libera las copias CPU después de subir sus mismos píxeles a GPU y drena objetos temporales de Metal/Foundation al terminar cada operación nativa. La caché de fotos descartables en iOS usa hasta 128 MiB y se adapta a la memoria disponible; una imagen nativa necesaria puede exceder ese presupuesto. No cambia resolución, población de gaussianas ni número de cámaras. La caché Mac mantiene 2 GiB.

Cinco regresiones nativas en Mac aprobaron reutilización exacta de píxeles 4K, recarga de pirámides y calibración/distorsión, desalojo previo a una decodificación fallida y entrenamiento Metal con checkpoint/destrucción/reanudación a través del puente con autoreleasepool. Una imagen 3840×2160 retiene 99.532.800 bytes de GPU y cero bytes de su copia float CPU, frente a 199.065.600 bytes de ambas copias antes. Eso mide residencia de esa imagen, no todo el entrenamiento.

`FormaV071PhysicalControls.xcresult` aprobó **18 pruebas físicas** de motor Metal, pausa y reanudación; `FormaV071ThermalSimulator.xcresult` aprobó **31 casos** de política térmica, dominio de pausas y control. El respaldo de la sesión real conserva paso 52, factor de resolución 1 y checkpoint de 141.507.128 bytes; su SHA-256 es `5d8e64037c4995b905e40652aa5475e44ba4a71dd8bd37cd0ec6d29aadd0a65d`. El índice y las fotos originales se conservan.

La aceptación de la sala nativa se registra por separado: su primer intento avanzó 54→57, sin aviso de memoria y con huella de proceso aproximada de 1736 MiB, antes de parar por pérdida de primer plano. No se cuenta como aprobación de la ejecución sostenida solicitada. Una repetición con la cámara LiDAR abierta en paralelo se detuvo tras 20 pasos por aviso de memoria; se detectó la interferencia en los logs de ARKit. Después de aislar el host de pruebas para que no abra sensores, `FormaV071RoomIsolated.xcresult` completó **54→134 (80 pasos), factor 1 y 199.868 gaussianas**, sin avisos de memoria. Registró 20,03 s de trabajo y 20,23 s de descanso, con 40,54 s del worker. El SHA-256 del checkpoint original y los bytes de su índice permanecieron iguales. Se registra como ejecución nativa aislada, no como prueba completa de todas las interacciones de la interfaz. La versión final compacta las derivadas SSIM de 15 a 9 float32 por píxel, conservando los 15 campos de estadísticas horizontales y reservando el búfer de forward legacy sólo cuando se usa. Ahorra 199.065.600 bytes con 3840×2160 y 240.869.376 bytes con 4224×2376. Los pases SSIM ahora usan grupos completos de 16×16 también en bordes no divisibles por 16. En cinco tamaños (8453 píxeles, los tres canales), las derivadas y los gradientes del layout compacto coinciden bit a bit con la referencia de stride 5; la pérdida difiere como máximo 5,96e-8 por el orden de reducción atómica. Esta equivalencia valida los layouts con dispatch correcto, no la salida del antiguo borde parcialmente inicializado. iPhone devuelve páginas ya libres del asignador después de las operaciones nativas; no descarta datos vivos.

`FormaV071FinalNativeAcceptance.xcresult` aprobó sus **2 casos físicos**: regresión de entrenamiento/Metal/checkpoint y la sala real. La versión final repitió **54→134, factor 1, 199.868 gaussianas y cero avisos de memoria**, con 18,76 s de trabajo y 19,01 s de descanso (38,03 s del worker). Las 16 muestras registradas de huella de la sala estuvieron entre **1516,3 y 1782,3 MiB**; no son una medición continua de su pico. El checkpoint y el índice del usuario conservaron bytes/hash. El fixture escribe únicamente un checkpoint temporal de aceptación y no publica un modelo ni modifica fotos.

Forma **0.7.1 build 8 Release** quedó instalada y abierta en el iPhone; la firma y versión de host/extensión se verificaron. Se conservaron los cinco directorios de escaneo. Hay dos respaldos previos del entrenamiento: paso 52 y el último paso 54. La aceptación del flujo real por el usuario, después de esta actualización, se registra por separado de las pruebas técnicas. La app Mac permanece en 0.7.0.

Evidencia y respaldo: `build/Research/GaussianPauseFix/`, incluido `delivery-verification.json`. Regresiones nativas: `build/Research/MobileV7/native-cache-regressions.json` y `native-ssim-packing-regressions.json`.

## iPhone 0.7: energía, segundo plano y recuperación

La política móvil alterna trabajo y descanso con objetivo 50 % en estado nominal, 35 % en `fair`, 20 % en `serious` y espera en `critical`. La Mac no recibe esa espera programada. El porcentaje describe tiempo entre checkpoints; no representa un límite de utilización instantánea de CPU/GPU ni una garantía de temperatura. La espera de Gaussian empieza después de drenar las operaciones Metal enviadas por el bloque.

Tres ejecuciones de fixtures con el modelo Core ML real, imágenes sintéticas propias y una concesión real de `BGContinuedProcessingTask` se ejecutaron en el iPhone 18 Pro / iOS 27.0.1:

| Fixture | Inferencias completas | Completadas en segundo plano | Trabajo medido | Descanso medido |
| --- | ---: | ---: | ---: | ---: |
| `FormaV7PhysicalBackgroundConcrete.xcresult` | 120 | 69 | 48,26 s | 49,61 s |
| `FormaV7PhysicalPriorityBackground.xcresult` | 72 | 71 | 34,83 s | 35,82 s |
| Fixture CPU de `FormaV7PhysicalAcceptance.xcresult` | 72 | 72 | 35,18 s | 49,59 s |

Los casos usan CPU-only y verifican pausa confirmada por el worker y reanudación mediante `FormaProcessingActionIntent`. Las observaciones de `UIApplication.applicationState` distinguen segundo plano de primer plano. No son mediciones de batería, temperatura ni una sala completa. El segundo caso exige una transición real a Inicio: un intento anterior terminó sin esa transición y falló la aserción de aceptación manual; la repetición con Inicio sí pasó.

ActivityKit aceptó la actividad personalizada en el dispositivo. Se observó su icono/porcentaje compacto en un fixture de primer plano y el progreso de la tarjeta propia del sistema durante la tarea CPU. La interfaz de sistema de una tarea continuada es independiente del widget de Forma: la aceptación de `Activity.request` no prueba qué actividad decide presentar iOS. Los títulos del sistema se actualizan en cambios de fase o al avanzar cinco puntos porcentuales, conservando un porcentaje real visible cuando iOS prioriza esa tarjeta. El objeto de progreso y la actividad personalizada siguen recibiendo todos los avances reales. Esto no promete ocultar la tarjeta del sistema.

La extensión declara porcentaje y pausa/reanudación en Dynamic Island expandida y pantalla bloqueada. El **15 de octubre de 2026**, después de instalar Forma 0.7.0 build 7 Release, el usuario respondió **«Pausa y reanuda correctamente»** a la prueba física solicitada: iniciar la restauración, salir o bloquear el iPhone y comprobar Pausar/Reanudar desde la actividad. Se registra como **aceptación funcional manual confirmada por el usuario**, separada de XCTest. La respuesta no detalla individualmente qué superficie utilizó ni instrumenta la transición de bloqueo, temperatura o autonomía. Duplicación del iPhone permitió observar la pantalla y usar Inicio desde su menú, pero la herramienta devolvió `noWindowsAvailable` al intentar pulsar el contenido; el agente no observó directamente esos toques ni empleó otro mecanismo para eludir esa limitación. Los tests directos de AppIntent verificaron por separado el enrutamiento y el control cooperativo.

La restauración de texturas solicita CPU continuada antes de iniciar su worker y usa el modo CPU durante toda esa ejecución. Gaussian, que necesita Metal, no convierte una concesión de CPU en permiso GPU: conserva checkpoint, libera el motor y muestra «Abrir Forma» cuando se requiere volver al primer plano. El sistema puede rechazar o terminar tareas; no se añadieron modos ficticios de audio, localización ni permisos GPU ausentes de la firma.

La recuperación de texturas conserva cada atlas completo en un workspace privado. Los nueve tests del motor ejecutan Core ML real y comprueban interrupción/reanudación, equivalencia con una ejecución completa, publicación atómica y rechazo de fuentes, pesos o atlas comprometidos que no coinciden. También cubren un checkpoint nuevo bajo un alias de su carpeta padre y un symlink a una copia byte-exact del atlas completado: el enlace se rechaza sin modificar su destino. Esto detecta el fallo de comparación entre `/var` y `/private/var` encontrado y corregido en el iPhone físico. Un atlas parcial se vuelve a procesar. El fast path de un resultado ya completado pendiente de guardar valida geometría, materiales e inventario; no debe confundirse con una verificación criptográfica de todos sus PNG al reabrir la pantalla.

La pasada final de recuperación aprobó **9/9 en el iPhone físico**, **9/9 en simulador** y **9/9 en el harness Mac**. Los resultados físicos son `FormaV7CheckpointPhysicalRetry.xcresult`; el primer intento de esa repetición se interrumpió tras quedarse Xcode sin iniciar los casos, y la siguiente ejecución terminó normalmente. La suite previa `FormaV7PhysicalAcceptance.xcresult` aprobó 19/20 casos: su único fallo era una aserción nueva dependiente del texto localizado del rechazo de symlink. Se sustituyó por dominio/código estable y se reforzó la prueba con el atlas byte-exact externo antes de repetir los nueve casos. El guardado/reintento/descarte con verificación de originales, el motor Metal con checkpoint/reanudación, los intents y el inventario físico de formatos ya habían aprobado.

Forma **0.7.0, build 7, Release** quedó instalada y abierta en ambos dispositivos. La extensión comparte versión/build, tiene bundle ID propio y la firma se verificó junto con la del host. El Mac contiene ambos ejecutables `arm64`/`x86_64` y sus bytes coinciden con la compilación final. El iPhone conserva los mismos cinco directorios de captura y metadatos de directorio antes/después; esta comprobación no rehízo el hash de todos sus GB. La interfaz Mac volvió a abrir sus cuatro capturas y renderizó la sala texturizada.

El inventario de ARKit del teléfono ofrece un mínimo de **24 FPS**, con formato seleccionado de 3840×2160. El objetivo de **5 FPS** corresponde al trabajo de Forma; esta prueba enumera formatos y verifica selección, no enciende la cámara ni mide temperatura o cadencia realmente presentada.

Resultados, recibos y adjuntos: `build/Research/MobileV7/`, con `delivery-verification.json`. Los escaneos personales no se usaron como entrada de los fixtures.

## Qué se conserva y qué cambia

`LocalAITextureEnhancer` crea otro paquete y nunca modifica su entrada. Sólo restaura mapas difusos PNG sRGB de 8 bits referenciados por `mtllib`/`map_Kd`; conserva los formatos no admitidos y los informa. No procesa las fotografías RGB-D de `fuentes`. Los bytes del OBJ y del MTL, posiciones, normales, UV y dimensiones nativas permanecen iguales. El PNG derivado cambia sus colores interiores; por ello no se espera igualdad de hash entre esa textura y su fuente. El alfa, los gutters y los primeros dos píxeles del borde UV se conservan; los siguientes dos píxeles tienen transición gradual. La salida se publica mediante renombrado después de completarse.

La red produce internamente una imagen 4×. El motor integra bloques 4×4 en el tamaño original y mezcla con intensidad 0,5 en estas pruebas. Esto es restauración de apariencia a resolución nativa: no añade mediciones ni demuestra cuatro veces más detalle capturado. La inspección visual de la pared y de una fotografía de la sala muestra cambios sutiles de ruido/textura; no demuestra recuperación de letras ni de detalles geométricos verdaderos. No se ha realizado aquí una comparación equivalente con Polycam que permita declarar un ganador.

## Modelo verificado

Pesos `realesr-general-x4v3` del proyecto [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN), bajo [BSD-3-Clause](https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE). El paquete convertido procede de [hanxiao/real-esrgan-coreml](https://github.com/hanxiao/real-esrgan-coreml), release `v1.0.0`; no se incorporó su programa Python a la app. Los avisos se incluyen en `Forma/Resources/RealESRGAN-{LICENSE,PROVENANCE}.txt` y en los recursos del Mac.

- [Archivo de distribución](https://github.com/hanxiao/real-esrgan-coreml/releases/download/v1.0.0/RealESRGAN_general_522_fp16.zip): 2.286.475 bytes; SHA-256 `41368af9dcbcc300c0fe0442202acbf98d30dc07c28d49bf656883f7fef3656a`.
- Modelo incluido: `Forma/Resources/RealESRGAN_general_522_fp16.mlpackage`.
- Perfil validado: RGB `[0,1]`, NCHW `[1,3,522,522]` → `[1,3,2088,2088]`, Float16. Las interfaces actuales usan este preset; validar sólo las dimensiones de otro modelo no acredita su normalización o contexto espacial.
- Huella del paquete calculada por el motor sobre nombres ordenados y hashes de archivos: `92132d314cceb71a677fe43a5ccaef2fe6c4c9492177057c21079e397b921aac`.

| Archivo dentro del paquete | SHA-256 |
| --- | --- |
| `Manifest.json` | `ce2e3230b17e6abc20491daa91e50b5755feda60cf7584ca3a90d4dd6b376238` |
| `Data/com.apple.CoreML/model.mlmodel` | `9fb3b66a97f935377f56b6ff3b5668810436c145bd230689fea24d1e3bc5790f` |
| `Data/com.apple.CoreML/weights/weight.bin` | `7a6088b2ee537938f380b9049fae2b85dad57b251d047ab8f5afd256417838ec` |

La huella antigua del primer experimento no era canónica porque enumeraba archivos sin ordenarlos. Esa diferencia no indica un cambio de pesos. El archivo descargado conserva el SHA-256 anterior.

La compilación real del paquete para iOS 18 terminó con código 0:

```sh
xcrun coremlcompiler compile \
  Forma/Resources/RealESRGAN_general_522_fp16.mlpackage \
  build/Research/LocalAI/ios-model-check \
  --platform ios --deployment-target 18.0
```

El `metadata.json` resultante declara spec 9, iOS 18/macOS 15 y las dimensiones anteriores. Su histograma contiene 34 convoluciones y 33 PReLU, además de PixelShuffle, UpsampleNearestNeighbor y suma. La compilación prepara el formato para el destino; no prueba por sí sola inferencia, memoria o velocidad en un iPhone. Apple documenta esa etapa en [MLModel.compileModel(at:)](https://developer.apple.com/documentation/coreml/mlmodel/compilemodel(at:)).

## Contexto independiente por isla UV

La primera implementación protegía las costuras erosionando 40 píxeles. Resultó inadecuada para el atlas de la sala: sólo quedaban 23 píxeles elegibles. Se sustituyó por componentes UV conectados, divididos en núcleos de hasta 442×442 y empaquetados determinísticamente en la entrada 522×522. Cada núcleo recibe halo de 40 píxeles por lado. El relleno propaga únicamente colores con la misma etiqueta de isla; no lee colores de otra isla del atlas. La composición alcanza sólo los texeles originales elegibles.

La prueba sintética usa dos islas contiguas con una separación de cuatro píxeles. La isla izquierda roja es idéntica en ambas entradas; la derecha cambia de verde a azul. Se ejecuta la red real en ambas variantes y se compara la izquierda canal por canal.

| Comprobación | Resultado |
| --- | ---: |
| Islas / parches / predicciones | 2 / 2 / 1 |
| Texeles UV observados opacos | 38.640 |
| Texeles elegibles | 36.448 (94,33 %) |
| Texeles rojos realmente modificados | 16.864 |
| Diferencia máxima de la isla roja al cambiar la vecina | **0** |
| Texeles protegidos comparados exactamente | 21.152 |

La prueba cubre el preset validado y esas dos islas; no certifica automáticamente cualquier arquitectura de red o atlas posible.

## Fotografía y atlas reales

El recorte fotográfico es un centro de 522×522 píxeles de la fotografía `A43EEE64-2889-49B2-9B4F-F8F29FA4725B.jpg`, conservada en el backup de la sala. La herramienta no lo redimensiona: lo decodifica a sRGB PNG y utiliza un cuadrado UV sintético para aislar la restauración fotográfica. No equivale al procesamiento completo de la sala.

En el motor definitivo: 272.484 texeles observados, 268.324 elegibles, 207.700 modificados, cuatro parches en tres predicciones y 4.160 texeles del borde preservados exactamente. Tiempo total del motor **0,259 s**; primera predicción 0,050 s y suma de las dos siguientes 0,054 s. La RMSE RGB frente a la entrada fue 1,531/255: mide cuánto cambió la imagen, no si mejoró. Una fotografía no referenciada dentro de `fuentes` fue copiada byte por byte y no contó como entrada de inferencia.

El fixture del atlas usa `atlas_000000.png` real, de 4096×4090 (16.752.640 texeles), con los 1.379 triángulos reales del material `camera_0`, sus 1.656 vértices y 4.137 UV, reindexados sin modificar coordenadas. Su procedencia está en `build/Research/LocalAI/real-atlas/provenance.json`; no representa toda la sala.

| Métrica del mismo atlas | Primera erosión de 40 px | Motor con contexto por isla |
| --- | ---: | ---: |
| Texeles UV observados | No contabilizado entonces | 513.406 |
| Texeles elegibles | 23 | **429.525 (83,66 % UV)** |
| Texeles modificados | 23 | 379.276 |
| Islas / parches | No contabilizado entonces | 333 / 193 |
| Predicciones | 1 | 25 |
| Tiempo total, ejecución aislada | 1,008 s | 1,088 s |

La ejecución aislada definitiva registró primera predicción 0,043 s y suma de las 24 siguientes 0,297 s. `/usr/bin/time -l` midió **462.585.856 bytes de RSS máximo** y **729.662.448 bytes de peak memory footprint** (aprox. 696 MiB). Archivos: `real-atlas/{report.json,final-time.log,baseline-erosion-report.json}`.

La repetición con la herramienta publicada, mientras se compilaban/probaban otras partes del proyecto, reprodujo exactamente cobertura y número de texeles modificados; tardó 1,549 s. El conjunto completo de regresiones más atlas tardó 3,45 s y alcanzó footprint de 727.270.456 bytes. Los tiempos no son una garantía para todo un modelo, para el primer arranque en frío ni para iPhone.

Las predicciones tienen tamaño fijo y se liberan entre bloques, pero las máscaras, etiquetas, raster y composición requieren memoria proporcional al atlas actual y la geometría. El proceso trabaja secuencialmente por textura; estas cifras no demuestran memoria constante ni que cualquier atlas quepa en cualquier dispositivo. No se añadió una cuota artificial de número de atlas, capturas o resolución.

Se conservaron recortes de comparación en `build/Research/LocalAI/real-atlas/comparison-{original,local-ai}.png`. El derivado permite inspección visual junto al original; una diferencia de píxeles por sí sola no acredita fidelidad superior.

## Orientación, transparencia, pausa y cancelación

La regresión asimétrica observa sólo la mitad superior de la textura y contiene un bloque de 1.600 texeles semitransparentes. El resultado definitivo modifica **101.091 texeles superiores y 0 inferiores**; conserva exactamente todos los canales de los 1.600 semitransparentes. Esto detecta una inversión vertical de la máscara y alteraciones del alfa/premultiplicado.

Las otras comprobaciones ejecutan inferencia real, solicitan pausa/cancelación desde el progreso entre bloques y verifican:

- La pausa se confirma en un checkpoint de un worker, sin publicar la salida; reanudar termina la misma ejecución.
- Cancelar durante el procesamiento no publica y elimina su staging; cancelar estando ya pausado despierta el worker y tampoco publica.
- Los hashes de los archivos originales, OBJ/MTL de la copia y fotografía no referenciada siguen iguales.
- El progreso por bloques es finito, monótono y termina en 1.

Una predicción Core ML síncrona que ya está ejecutándose finaliza antes del siguiente checkpoint. La pausa es cooperativa y no promete interrumpir una operación GPU en mitad de una predicción. Los tests usan semáforos y comprobaciones que permanecen activas con `-O`, sin `assert` eliminables ni esperas artificiales largas.

## Reproducción

`scripts/verify_local_ai.sh` compila `Tools/verify_local_ai.swift` y las dependencias reales de `Forma/Core`, incluida la implementación de guardado/integridad; no contiene sustitutos del motor o del almacenamiento. Requiere Xcode y un Mac compatible con el modelo. El modelo ya debe estar disponible; el script no descarga ni abre apps.

Suite sintética completa en una carpeta nueva:

```sh
scripts/verify_local_ai.sh test \
  build/Research/LocalAI/nueva-validacion \
  Forma/Resources/RealESRGAN_general_522_fp16.mlpackage -
```

Para repetir con datos reales, sustituir `-` por la foto y añadir el paquete OBJ/MTL/atlas opcional. Los resultados finales conservados usan `build/Research/LocalAI/repro-validation-complete`; `verification.json`, `crop-report.json`, `edges-report.json`, `islands-report.json` y `real-package-report.json` contienen los valores anteriores. La salida del proceso está en `repro-validation-complete.log` y su consumo en `repro-validation-complete-time.log`.

Procesar cualquier copia del paquete de modelo con este mismo preset, sin tocar la biblioteca:

```sh
scripts/verify_local_ai.sh run \
  '/ruta/entrada/modelo' '/ruta/nueva/copia-IA' \
  Forma/Resources/RealESRGAN_general_522_fp16.mlpackage 0.5
```

La carpeta de entrada debe contener `modelo.obj` y sus archivos referenciados; la salida debe ser inexistente. El informe se escribe en `copia-IA/ia-local.json`. Este comando procesa todas las texturas referenciadas admitidas: no muestrea ni impone un máximo de capturas o bloques. La ejecución de la sala completa y la comprobación física posterior del iPhone se documentan a continuación.


## Sala completa: ejecución CLI y QA independiente

Este ensayo posterior amplía el alcance de los fixtures anteriores al paquete completo del OBJ LiDAR texturizado `28D5F554-465E-48FC-BEA0-BA9F3414C146`. Tiene **43 materiales, de los cuales 42 referencian PNG**; el restante es neutro. Se procesó una copia mediante la herramienta Swift/Core ML del Mac, sin operaciones sobre la interfaz ni sobre el teléfono. La salida permanece en `build/Comparison/2026-10-15/NewRoom-v0.4/LocalAI-v0.6/NativeFull/modelo`. Después de esta QA se guardó otra copia mediante `ScanStore` de producción en la biblioteca Mac, registro `FCB1E9C6-39DA-45AC-B6E9-94C7A71BCE00`, con el trabajo **Sala · textura IA local** y vínculo a la fuente. No se duplicó el conjunto RGB-D ni se entregó este derivado al iPhone.

| Informe de la ejecución completa | Resultado |
| --- | ---: |
| PNG procesados / omitidos | 42 / 0 |
| Píxeles de las texturas a resolución nativa | 688.198.711 |
| Texeles UV observados / elegibles | 132.278.668 / 116.333.017 |
| Fracción elegible de los texeles UV observados | 87,9454 % |
| Islas / parches aislados | 82.615 / 48.398 |
| Predicciones Core ML | 5.066 |
| Píxeles modificados | 93.669.624 |
| Primera predicción / suma de siguientes | 0,044385 / 78,236680 s |
| Tiempo total registrado por el motor | **122,137509 s** |

Es tiempo del motor en esta ejecución CLI de Mac, no del flujo de interfaz ni del iPhone. La fracción de texeles UV no representa cobertura física de la sala. [Informe original del motor](../build/Comparison/2026-10-15/NewRoom-v0.4/LocalAI-v0.6/NativeFull/modelo/ia-local.json).

Una revisión independiente con Python/Pillow/NumPy, sin ejecutar el motor de IA de nuevo, comparó **todos los píxeles de las 42 imágenes** por franjas de 128 filas y volvió a contar exactamente los 93.669.624 píxeles RGB modificados. Conservan dimensiones nativas y alpha sin una sola discrepancia; los bordes exteriores de dos píxeles de cada PNG también coinciden exactamente en RGBA. OBJ, MTL y `texturizado.json` conservan sus SHA-256. La RMSE RGB global respecto a la entrada es **0,668058/255**, sobre los 688.198.711 texeles, con cambio máximo de canal de 55/255. Estas cifras miden cambio, no calidad superior. [QA independiente completa](../build/Comparison/2026-10-15/NewRoom-v0.4/LocalAI-v0.6/NativeFull/QA/independent-verification.json).

También se verificaron mediante SHA-256 streaming los **2.327 archivos y 2.832.306.840 bytes de la captura Mac original**, incluidas fotografías y calibración, contra su manifiesto de integridad. No hay faltantes, extras, enlaces simbólicos ni cambios de tamaño o hash. El propio manifiesto coincide con la huella guardada en la validación anterior: `04768e33e507a0d03d76ed85ba0e6f1c4ea1df639562b459b420d6d2d03163c2`. [Verificación íntegra de la fuente](../build/Comparison/2026-10-15/NewRoom-v0.4/LocalAI-v0.6/NativeFull/QA/source-integrity-verification.json).

Se generaron **seis vistas propias antes/después** con las mismas cámaras: superior y oblicua de sala completa, más un detalle deliberado de mesa y suelo. Blender 5.2.2 LTS, Cycles CPU, 64 muestras, 1600×1200, sin denoise ni reducción de las imágenes originales, albedo con emisión y opacidad original y caras posteriores ocultas. OBJ/MTL e importación geométrica son idénticos; no hubo alineación, ajuste de escala ni cambio de geometría. Las vistas completas contienen todos los vértices dibujables; el detalle tiene el mismo recorte en ambos casos. Blender omite los 1.925 vértices sin referencias del OBJ: importa 197.458 vértices dibujables y 366.954 triángulos en ambos; los bytes originales conservan todos los vértices.

En las seis imágenes revisadas no se aprecian nuevas manchas extensas, bandas de color ni costuras evidentes a esas posiciones y resoluciones. Los cambios de apariencia son sutiles y se mantienen la fragmentación, los huecos, las caras neutras y las desalineaciones anteriores. No es una revisión perceptual exhaustiva de todos los atlas ni prueba mejor fidelidad, precisión, FPS o superioridad frente a Polycam. [Comparación visual local](../build/Comparison/2026-10-15/NewRoom-v0.4/LocalAI-v0.6/NativeFull/QA/index.html) · [Parámetros y diferencias de renders](../build/Comparison/2026-10-15/NewRoom-v0.4/LocalAI-v0.6/NativeFull/QA/render-comparison.json).

## Integración Xcode e instalación 0.6.0 (build 6)

Las compilaciones Release finales de `Forma` para iPhone y `FormaDesktop` universal terminaron correctamente. Se verificaron sus firmas con `codesign --verify --deep --strict`. La app Mac instalada en `/Applications/FormaDesktop.app` coincide en SHA-256 de ejecutable con el producto final; la versión anterior se conservó en `build/PreviousApps`. `devicectl` confirmó la actualización del mismo bundle `com.robii.forma` en el iPhone, y una lectura posterior comprobó que permanecen los cinco directorios de capturas existentes. Esto comprueba instalación y presencia, no vuelve a validar por hash todos sus GB.

En el simulador iPhone 18 Pro / iOS 27, `build/FormaLocalAIInference.xcresult` registra **dos pruebas aprobadas, cero fallos y cero omisiones**. La prueba de restauración usa el Core ML real incluido en el bundle, verifica cambios efectivos, OBJ/MTL originales, dimensiones, alfa y bordes UV; la otra comprueba cancelación previa sin publicación. El tiempo del caso de inferencia fue 1,099 s y el conjunto de casos 1,130 s, sin incluir preparación de Xcode. `build/FormaLocalAIPreview.xcresult` conserva otra tanda de **nueve pruebas aprobadas**, seis del visor y tres de recuperación/preparación. Son tandas seleccionadas; no se suman a las suites antiguas como casos nuevos únicos.

La revisión posterior de integración confirmó el resultado pendiente propio, revalidación de disponibilidad antes de empezar, decodificación fuera de MainActor, protección contra callbacks tardíos y liberación de actividad al confirmar pausa. La pausa/reanudación/cancelación del motor se ejercitó en Mac como se detalla arriba.

La verificación independiente del derivado publicado comprobó **54/54 archivos, 885.631.354 bytes**, sin faltantes, extras ni enlaces simbólicos y con tamaños/SHA-256 correctos. Sus 46 archivos del paquete de modelo coinciden exactamente con la salida de inferencia; la malla conserva 199.383 vértices y 366.954 caras, y el vínculo a la fuente es correcto. La cola pasó de dos a tres trabajos, mantuvo los anteriores idénticos y añadió una sola entrada completada. Véanse `NativeFull/QA/published-integrity-verification.json` y `delivery-verification.json`. El informe del publicador CLI lleva versión/build `unknown`, porque no es el bundle de la aplicación; la verificación de entrega acredita por separado las apps 0.6.0 build 6 instaladas.

La primera tanda física y la revisión de ventana quedaron inicialmente detenidas por bloqueo del iPhone y de la Mac. Después de que el usuario desbloqueó ambos, se continuó con las comprobaciones siguientes; el resultado incompleto anterior no se cuenta como prueba aprobada.

## Comprobación física tras desbloquear el iPhone

`build/FormaLocalAIPhysicalUnlocked.xcresult` registra **2/2 pruebas aprobadas, cero fallos y cero omisiones** en el iPhone físico `iPhone19,2`, iOS 27.0.1. Se ejecutó el Core ML real compilado e incluido en el bundle. El fixture propio de 160×128 conservó dimensiones, alfa, borde de dos píxeles, OBJ/MTL y bytes originales; cambió 18.240 píxeles interiores, exactamente los que declara el motor. La predicción inicial tardó 0,714528 s y la ejecución del motor 0,787905 s; los dos casos de XCTest sumaron 0,809 s, sin preparación de Xcode. Estos tiempos de un bloque no representan una sala completa, temperatura sostenida ni velocidad de GPU exclusiva.

La huella `d70a0f50130384f8bc3cb4e7e2e790f5ea1b1f43007829cccc1ddbfc0d8b3c9d` corresponde al recurso `.mlmodelc` compilado para iPhone. No debe compararse como si fuera el SHA del paquete fuente `.mlpackage` usado en Mac. El otro caso comprobó cancelación previa sin publicar archivos. No se probó con estos dos casos la pausa mediante interfaz ni el ciclo de segundo plano del teléfono.

Después se reinstaló la app **Release 0.6.0 build 6**, se confirmó que siguen presentes los cinco directorios de capturas y `devicectl` la inició correctamente. La evidencia sanitizada está en `NativeFull/QA/physical-unlocked-verification.json`; la adjunta original de XCTest se conserva en `build/Research/LocalAI/physical-unlocked-attachments/` y no contiene fotografías del usuario.

## Interfaz Mac: pausa, reanudación y guardado completos

Se cerró normalmente la versión anterior y se reabrió `/Applications/FormaDesktop.app`. La copia CLI apareció seleccionada, con **Abrir original** y **Textura original**. La sala OBJ y el USDZ Raw terminaron de cargar y mostraron fotografía nativa en la ventana. La preparación inicial tardó en mostrar el modelo; terminó sin cambiar a textura ligera. No se midió aquí ese tiempo ni el FPS presentado.

Desde **Abrir original** se inició otra restauración, con el modelo ya instalado e intensidad predeterminada **35 %**. Se comprobó pausa inicial y reanudación; una segunda pausa, después de inferencia efectiva, quedó confirmada como **Pausado · no se procesan más bloques**, en `atlas_000004.png`, bloque 151/151 y progreso **0,119047619047619**. Una observación posterior conservó exactamente estado, bloque y progreso. Al reanudar avanzó a `atlas_000005.png`, bloque 1/167 y progreso **0,1191901910464785**. La prueba usa el estado confirmado del worker, no sólo la etiqueta del botón.

El mismo flujo terminó en **Copia con IA guardada**, 42 texturas, progreso 1 y 87,9 % de zona UV observada procesable. Al cerrar la hoja quedó seleccionado un nuevo trabajo **Textura IA · Importada…**, captura `CE91C622-9650-46E8-B582-324AAC656FBC`, enlazada al original. El motor registró 148,459276 s **incluidas las pausas del ensayo**, por lo que no es un benchmark comparable con los 122,14 s sin pausa de la CLI. Registró 72.707.126 píxeles modificados con intensidad 35 %; la copia CLI anterior usaba 50 %.

Las observaciones están en `NativeFull/QA/desktop-gui-unlocked-verification.json`. Esto comprueba los controles del motor y el guardado final de esta ejecución Mac; no ejercita la pausa durante el propio guardado, que utiliza otro control, ni la pausa/segundo plano del iPhone.
