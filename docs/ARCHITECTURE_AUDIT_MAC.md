# Auditoría de arquitectura Mac y continuidad híbrida

Fecha: 15 de octubre de 2026. Auditoría del código local; este documento describe el estado observado y trabajo propuesto, no funciones ya entregadas. No modifica las fuentes de producto ni la biblioteca del usuario. La reparación del motor nativo Gaussian y su validación se registran aparte.

Las secciones 1–6 registran el estado encontrado antes de las implementaciones ampliadas de esta sesión. La sección 7 separa lo que se ha implementado después y su verificación.

## Conclusión

Forma Desktop ya recibe fuentes RGB-D cifradas, procesa mallas y texturas localmente, conserva originales, reconstruye fotografías Full/Raw con Apple y restaura texturas con Core ML. La brecha principal para trabajo largo es la **continuidad del trabajo**: la cola conserva las fuentes, pero los controladores de procesamiento no constituyen todavía un registro durable y uniforme de sesiones recuperables.

El híbrido actual consiste en capturar en iPhone y enviar al terminar. No es descarga de cálculo durante la captura, sincronización de una sesión viva, control remoto de un trabajo Mac ni retorno automático del resultado al iPhone. La app Mac tampoco integra entrenamiento Gaussian. Estos puntos deben distinguirse antes de ofrecer continuidad entre dispositivos.

La intención es trabajar sin cuentas, cuotas de capturas, compras o suscripciones. Los presupuestos de caché descartable, validaciones de integridad, capacidad de disco y restricciones reales del sistema son cuestiones técnicas diferentes de una cuota comercial. No se consigue más detalle medido aumentando el objetivo de FPS del visor ni interpolando profundidad.

## 1. Capacidades presentes y puntos de extensión

| Área | Implementación comprobada en código | Límite o hueco concreto |
| --- | --- | --- |
| Biblioteca y exportación | `Forma/Core/ScanStore.swift`, `PendingScanRecovery.swift`: guardado en staging, inventario y publicación de biblioteca; recuperación de guardados completos pendientes. | Esa recuperación no representa el estado intermedio de cada algoritmo. `CaptureResult` y `pendingCapture` viven en memoria hasta el guardado. |
| Cola Mac | `Mac/DesktopStore.swift`, `DesktopJob`, `enqueue`, `next`, `persist`: `jobs.json`, fuentes inmutables en `Incoming`, un trabajo activo, control cooperativo. | Un estado de texto no identifica etapa, checkpoint, configuración ni causa de suspensión. `init` transforma estados activos a «Interrumpido» y no llama `next`; `resume` reinicia el proceso desde fuentes. |
| Flujo LiDAR Mac | `DesktopStore.next` copia una versión de trabajo y llama al mismo `LiDARProcessingPipeline.process` utilizado por el teléfono. | `Work/<job>-<UUID>` cambia en cada intento. No hay manifiesto de etapa comprometida para saltar trabajo ya terminado tras cerrar el proceso. |
| Texturas IA Mac | `Mac/DesktopLocalAI.swift`: Real-ESRGAN/Core ML nativo, misma geometría/UV/resolución, pausa manual por `ProcessingControl`, copia derivada, guardado pendiente. | El workspace es `Work/LocalAI-<UUID>`. La llamada a `LocalAITextureEnhancer.run` no pasa `checkpointDirectory`, aunque el motor ya soporta esa recuperación. Un error o cancelación elimina el trabajo salvo el caso de resultado listo pendiente de guardar. |
| Fotogrametría Mac | `Mac/DesktopPhotogrammetry.swift`: `PhotogrammetrySession`, Full/Raw, sensibilidad alta, sin máscara de objeto; imágenes del manifiesto mediante `DesktopPhotogrammetryInput`. | La interrupción cancela el motor Apple. Conserva checkpoints ofrecidos al siguiente intento, pero no certifica reanudar exactamente el mismo punto ni impide la reducción automática decidida por Apple. |
| Visor Mac | `DesktopModelViewer`, `DesktopCameraPolicy`, `ImportedMeshBatching`: proyección y clipping adaptativos, originales o copias ligeras para pantalla, reducción de grupos importados. | 30/60/120 son objetivos de presentación. No cambian la captura ni acreditan FPS presentados o fidelidad superior. |
| Gaussian en Mac | Los lectores/visores pueden conservar representaciones existentes donde sus rutas de importación lo permitan. | `scripts/generate_project.py` no enlaza el target Mac a Msplat ni incluye `GaussianTrainerService`; `DesktopContentView` no tiene una ruta de entrenamiento. No existe «continuar este Gaussian en Mac» implementado. |
| Actividad Mac | `DesktopStore.updateActivity`: `ProcessInfo.beginActivity` con `.userInitiated` y `.idleSystemSleepDisabled`. | Reduce App Nap/sueño automático durante trabajo; no constituye un servicio persistente después de terminar la app ni permite evitar el sueño explícito o apagado del sistema. |

### Persistencia que hoy se pierde

1. `DesktopStore.persist()` se llama al recibir/reencolar y al salir del worker, pero `update` no persiste por transición. Si se termina el proceso durante una etapa, `jobs.json` puede conservar el estado previo «En cola», aunque había trabajo activo.
2. El arranque conserva resultados y fuentes, pero no reconstituye `Task`, `ProcessingControl`, controladores IA/fotogrametría ni un checkpoint del pipeline LiDAR. El botón de reanudación actual representa reinicio desde fuentes para esa ruta.
3. `DesktopStore.localAIController(for:)` y `photogrammetryController(for:)` construyen un controlador para una presentación de la UI. No hay registro central de sesiones con identidad estable independiente de la hoja/ventana.
4. Los guardados `.pending` de `ScanStore` pueden recuperarse si ya contienen un paquete válido. Esto protege resultados terminados, pero no sustituye recuperación del cálculo de atlas o reconstrucción interrumpida.

## 2. Transporte híbrido existente

El archivo compartido real es `Forma/Core/HybridTransfer.swift`; el generador de proyecto lo compila también en Mac. No hay otro módulo denominado `SharedHybridTransfer`.

### Lo que funciona

- Descubrimiento Bonjour `_forma-rgbd._tcp`; Wi-Fi es la elección inicial en `CaptureSetupView`.
- Emparejamiento efímero con clave de sesión de 128 bits, challenge/HMAC, derivación HKDF y bloques AES-GCM autenticados con dirección/contador.
- Transferencia de un archivo por vez en bloques de 1 MiB, backpressure TCP, SHA-256 de cada archivo y publicación del directorio recibido al terminar. No carga varios GB en un único `Data` ni crea un ZIP completo para enviarlo.
- Rechazo de rutas inválidas, enlaces simbólicos y archivos duplicados; exige manifiesto y malla original.
- USB por `iproxy`/usbmux como transporte alternativo local. `DesktopStore.receiveUSB` y `HybridTransferReceiver.connectUSB` ya reutilizan el mismo protocolo.
- Las fuentes del iPhone sobreviven a error/cancelación de la transferencia. Una confirmación de recepción perdida no oculta el directorio ya comprometido en Mac.

Hay evidencia física previa de ambos transportes en `build/Validation/HybridHardwarePhysicalFinal/hardware-report.json`: dos fixtures de 8.388.641 bytes recibidos y comprometidos con hashes exactos. La observación de la ruta Wi-Fi utiliza un probe independiente al mismo endpoint de Bonjour; el informe no afirma instrumentar directamente la conexión del payload. No es una prueba de reconexión, transferencia de sala completa o continuación después de cerrar apps.

### Lo que falta para continuidad

| Hueco | Evidencia en función | Cambio necesario |
| --- | --- | --- |
| Reintento idempotente | `sendStream` crea un `UUID` nuevo dentro de cada envío. | Identidad estable de sesión/captura y versión del conjunto de fuentes, enviada por el cliente. Un ACK perdido debe recuperar el mismo trabajo, no crear otro. |
| Reanudación tras corte | `receive` borra el staging por `defer` cuando falla la conexión; el protocolo no intercambia offsets/inventario. | Manifiesto de bloques/archivos comprometidos y handshake de reanudación. Mantener staging incompleto identificado, sin publicarlo como captura lista. |
| Progreso remoto | Tras `verified`, la conexión termina; `Header.kind` sólo gestiona job/file/done. | Mensajes versionados de estado, revisión, etapa, progreso y comandos idempotentes ligados al trabajo. La UI iPhone no debe inventar progreso de Mac. |
| Volver con el modelo | `HybridDeliveryView` informa que el resultado queda en biblioteca Mac. | Descarga de derivado verificado a un staging de biblioteca iPhone, con `sourceScanID`, revisión del origen e integridad. Evitar reemplazar la captura original. |
| Sesión viva | `HybridCapturePreparation` conserva fuentes y difiere el texturizado; se envían después de guardar. | Publicación incremental de archivos ya comprometidos por `RGBDRecording`, con una instantánea inmutable por revisión. La falta de red no debe frenar ni borrar adquisición local. |
| Emparejamiento entre aperturas | La clave cambia cada `HybridTransferReceiver.start`. | Emparejamiento persistente optativo entre equipos autorizados, claves en Keychain y revocación visible. Mantener la sesión efímera actual como alternativa. |

`HybridDeliveryView.onDisappear` cancela el envío y no registra una tarea durable. Deshabilitar el reposo de pantalla durante la transferencia mantiene el caso de primer plano, pero no acredita ejecución después de suspensión de iOS. La continuación de un trabajo Mac ya recibido puede ser independiente del teléfono; la continuidad de la cámara o de un socket del teléfono requiere tratar las autorizaciones y suspensión reales del sistema, sin fingir un permiso de segundo plano.

## 3. Contrato propuesto para trabajos persistentes

Implementar un registro compartido de **descripción de trabajo**, conservando ejecutores específicos por plataforma. Los tipos propuestos no existen todavía:

```text
ProcessingJob
  schemaVersion, jobID, sourceScanID, sourceRevision, engineVersion
  operation: lidarRefinement | textureRestoration | photogrammetry | gaussianTraining
  settingsFingerprint, sourceManifestFingerprint
  state: queued | running | manualPaused | systemSuspended | needsInput | saving | completed | failed
  stage, revision, progress { completedUnits, totalUnits, unit }
  workspaceRelativePath, checkpointRelativePath, resultScanID
  lastCommittedStage, lastError, warningCounters, updatedAt
```

Condiciones del contrato:

1. `jobID`, parámetros, inventario de fuentes y workspace son estables. Un nuevo intento de la misma operación no cambia silenciosamente parámetros ni resolución.
2. Persistir cada transición de estado y compromiso de etapa de forma atómica. Las actualizaciones de UI pueden agruparse; la transición running→manualPaused y un checkpoint confirmado no deben quedar sólo en memoria.
3. Diferenciar **pausa manual**, **suspensión impuesta por el sistema**, **error de E/S**, **error del motor** y **advertencia informativa**. Una advertencia de memoria o temperatura no debe convertirse en un comando de pausa propio. La reanudación automática de una suspensión del sistema nunca revive una pausa manual o cancelación.
4. La unidad de recuperación depende del motor: atlas completo para IA, artefacto de etapa para LiDAR, checkpoint nativo para Gaussian y checkpoints que Apple realmente acepte en fotogrametría. No presentar un reinicio de Apple como reanudación exacta.
5. Arranque: enumerar registro y workspaces; validar fingerprints y checkpoints; reconstruir ejecutores de tareas que se pueden continuar. Conservar pausas manuales. Si falta un recurso, mantener `needsInput` y permitir resolverlo sin borrar el avance.
6. Guardado: enlazar el resultado publicado y el trabajo de manera idempotente. Si el proceso termina entre publicar `ScanRecord` y actualizar el registro, el siguiente arranque encuentra esa publicación por `jobID` y no fabrica una segunda copia.
7. Pausar o cancelar conserva las fuentes. Distinguir detener un trabajo recuperable de descartar explícitamente sus archivos temporales.
8. Cambiar de Wi-Fi a USB modifica transporte, no `jobID`, parámetros, fuentes ni estado del motor.

Para Mac, el primer paso es un coordinador propiedad de `FormaDesktopApp`/`DesktopStore`, independiente de la ventana. No hace falta instalar un daemon para continuar al minimizar o cerrar una ventana mientras el proceso siga abierto. Para terminar explícitamente la app se necesita checkpoint y recuperación al siguiente arranque; trabajar después de que el proceso termine requeriría otro ejecutor, no sólo otro `Task`.

## 4. Prioridades con resultado verificable

### P0 — Continuidad Mac usando motores que ya existen

1. Dar a `DesktopLocalAI` workspace estable y metadata de configuración, pasar `checkpointDirectory` al motor y reutilizar su validación de fuentes/pesos/atlas. Hay una implementación móvil y nueve tests del motor para tomar como contrato; no duplicar el algoritmo.
2. Registrar trabajos IA/LiDAR/fotogrametría fuera de sus hojas de UI. Persistir transiciones, recuperar cola al abrir y conservar pausa manual.
3. Recuperar resultado terminado pendiente de guardar con identidad estable, sin repetir inferencia ni duplicar entradas.
4. Hacer visible el estado real de la cola y qué etapa se conserva. Mantener actividad Mac mientras hay trabajo, liberándola en pausa/fin, y probar minimizar, cerrar ventana, terminar/reabrir app y sueño/despertar.

### P1 — Transferencia recuperable y resultados de ida y vuelta

1. Versionar protocolo y descriptor de trabajo. Añadir `jobID` externo estable, hash del manifiesto, ACK por compromiso y consulta de estado.
2. Reanudar archivos o bloques verificados después de desconexión, conservando staging privado. No volver a transmitir varios GB ya confirmados.
3. Implementar recepción idempotente del modelo derivado en iPhone y asociación a su captura original. Mostrar el progreso remoto real aunque el teléfono deje de ser el ejecutor.
4. Transferir archivos de captura comprometidos incrementalmente. Mantener adquisición local desacoplada de ancho de banda; Wi-Fi por defecto, USB alternativo, sin adquisición simultánea de la misma cámara por otra sesión.

### P2 — Mejor reconstrucción, después de estabilidad e integridad

1. Integrar un ejecutor Gaussian nativo Mac con la misma representación/checkpoint y configuración explícita. Hoy faltan target nativo macOS, recursos Metal versionados, controlador Mac, registro de trabajo y pruebas reales. No reutilizar el controlador UIKit del teléfono directamente.
2. Aprovechar profundidad y poses originales para refinamiento geométrico medido: fusión RGB-D y corrección de deriva con observaciones conservadas, comparando contra la malla ARKit. No confundir restauración fotográfica con recuperación de geometría.
3. Evaluar texturizado multivista con reproyección, oclusión, selección por nitidez y compensación de exposición usando los motores de atlas y armonización existentes. Medir cobertura, costuras y error de reproyección antes de afirmar más realismo.
4. Mantener geometría y apariencia diferenciadas: una IA de profundidad normalizada no aporta escala métrica por sí sola; un modelo generativo puede inventar detalles. Conservar derivado y original para comparar.

## 5. Sensores: estado local e instrumentación pendiente

Este apartado se apoya en consultas y archivos locales existentes, sin repetir como hechos nuevas especificaciones comerciales no verificadas.

| Dato/capacidad | Uso real observado en código | Mejora instrumental necesaria |
| --- | --- | --- |
| LiDAR/malla | `LiDARCaptureController.resume`: `.mesh`, consulta `supportsSceneReconstruction`. | Registrar capacidad por dispositivo y cobertura por superficie; contrastar con referencias físicas. |
| Profundidad y confianza | `.sceneDepth`; `RGBDRecordingFrame` conserva depth float32 en metros, confianza uint8 y dimensiones nativas. | Informe por frame de porcentajes de confianza, valores no finitos y reproyección; separar precisión de confianza del sensor. |
| Imagen, pose y calibración | El registro contiene RGB, timestamp, `cameraToWorld`, intrínsecos reescalados a imagen guardada y exposición. HiRes usa el frame devuelto por la captura. | Guardar identificador de formato/lente y un inventario verificable de campos; detectar cambios de calibración durante la sesión. |
| Cadencia | `CapturePacingPolicy`: vista, evaluación automática y flujo guardado hasta 5 FPS; formato ARKit mínimo real. | No confundir callbacks, frecuencia solicitada, escritura y presentación. Las cuatro deben medirse y mostrarse por separado cuando sean relevantes. |
| HiRes | Selección automática por pose, intervalo, exposición y detalle de luminancia, más disparo manual. | Registrar tasa real de rechazo y motivo, blur/movimiento, cobertura nueva y resolución real por foto, sin cuota de imágenes. |
| Cámara avanzada | Se conservan exposición y offset; la ruta LiDAR no configura apertura, ISO, enfoque o balance de blancos explícitos. | Inventario runtime de controles por formato y pruebas A/B antes de cambiar exposición/enfoque. No abrir una segunda `AVCaptureSession` que compita con ARKit. |
| IMU, GPS, barómetro y TrueDepth | El inspector actual no inventaría estas capacidades; las poses ARKit ya incorporan el seguimiento de su sesión. No hay captura explícita sincronizada de estas señales en `RGBDFrameRecord`. | Añadir sólo señales con uso y calibración concretos. TrueDepth sería otro modo de captura; GPS/barómetro no sustituyen escala local. |
| GPU/Neural Engine | Core ML/Metal locales; capacidades interrogadas por cada motor donde corresponde. | Registrar modelo, compute units solicitadas, compilación del recurso y dispositivo efectivo cuando sea observable. No afirmar que todo algoritmo usa Neural Engine. |

Evidencia existente: `build/Research/MobileV7/physical-acceptance/C3FD0455-10C3-4477-9936-7CF7B41F4D82.json` enumera formatos del dispositivo y selecciona 24 FPS, 3840×2160 entre los formatos disponibles. Declara expresamente que esa prueba no encendió la cámara ni midió energía, FPS presentados o completitud del escaneo. `DeviceInspectorView` consulta soporte de malla, sceneDepth, ObjectCapture/Photogrammetry y RoomPlan, RAM física, espacio y estado térmico, pero muestra aún una etiqueta estática «versión 0.4» y no expone el inventario completo de formatos/sensores.

Inconsistencia de UI concreta: `CaptureSetupView` todavía dice «Vista del celular hasta 15 fps», mientras `CapturePacingPolicy.phonePreviewFPS` vale 5. Debe derivar el texto del valor de producción.

## 6. Pruebas de aceptación necesarias

Los tests compartidos actuales verifican controles cooperativos, integridad, motor de IA, datasets y transporte. Las suites Xcode declaradas se alojan en la app iOS; los controladores `Mac/DesktopStore`, `DesktopLocalAI` y `DesktopPhotogrammetry` no tienen un target XCTest Mac dedicado en el generador. Hay herramientas Mac como `verify_hybrid_transfer.swift`, `verify_photogrammetry_input.swift`, `verify_local_ai.swift` y verificadores de cámara/importación. No se deben convertir esas pruebas de componentes en una afirmación de continuidad de la aplicación Mac.

| Prioridad | Caso | Criterio de aprobación |
| --- | --- | --- |
| P0 | IA: terminar proceso después de comprometer atlas 1 y reabrir | Atlas 1 no vuelve a inferirse; fuentes/UV/modelo exactos; se continúa con la misma configuración. |
| P0 | Pausa manual, terminar/reabrir Mac | Sigue pausado; ni arranque, red, advertencias o retorno de ventana lo reactivan. |
| P0 | Resultado publicado, proceso termina antes de actualizar `jobs.json` | Una sola entrada de biblioteca y trabajo enlazado; hashes completos. |
| P0 | Mac minimizada/ventana cerrada con proceso vivo | El worker sigue; la UI al abrir refleja la misma revisión y progreso real. |
| P0 | Sueño/despertar o proceso terminado por sistema | Recurso del motor cerrado/recuperado correctamente; continúa desde checkpoint validado o declara reinicio real del motor. |
| P1 | Corte Wi-Fi a mitad de archivo, reconexión USB | Mismo `jobID`; conserva bloques comprometidos, verifica bytes finales y no duplica biblioteca. |
| P1 | ACK final perdido y reenvío | Mac devuelve trabajo existente, sin nuevo directorio/cola ni cómputo duplicado. |
| P1 | Resultado Mac vuelve al iPhone y se corta antes de publicar | El original sigue intacto; sólo se publica una copia completa y verificada. |
| P1 | Un peer anuncia estado viejo o comando duplicado | Revisión monótona, comando idempotente y propiedad de sesión comprobada. |
| P2 | Captura incremental con red lenta | Ningún frame original comprometido se pierde; no crece una cola ilimitada de `ARFrame`; no se bloquea la cámara por el receptor. |
| P2 | Mismos datos, iPhone y Mac, misma versión de motor | Configuración, cobertura, resolución y resultados trazables; diferencias cuantificadas. |
| P2 | Comparación de calidad con Polycam | Misma escena inmóvil, cobertura y luz; registro espacial y vistas equivalentes, tiempo, huecos, detalle observado, costuras y fluidez medidos. |

«100 veces mejor» es una aspiración del usuario, no una métrica actualmente demostrada. Para hacerla evaluable hay que elegir qué mejora: tiempo, área correctamente reconstruida, error geométrico, cobertura de textura o latencia del visor. No se puede afirmar ese factor a partir de más triángulos, dimensiones de atlas o FPS objetivo. La siguiente entrega material con más valor inmediato es recuperación durable de IA en Mac y transferencia reanudable, conservando después una comparación visual y geométrica reproducible.

## 7. Implementación posterior a la auditoría

`Mac/DesktopLocalAIRecovery.swift` incorpora un índice durable por captura de origen, schema 1, con UUID de trabajo, intensidad, estado, progreso y resultado. Su workspace estable es `Work/LocalAI-<sourceScanUUID>`. Conserva estados `running`, `manualPaused`, `stopped`, `saving`, `savePending`, `failed` y `completed`. La interrupción conserva archivos; sólo un guardado final confirmado retira el workspace propio.

`DesktopLocalAI` ya utiliza `checkpointDirectory` del motor compartido. Las fuentes y los pesos se vinculan mediante inventario y hashes. El resultado final pendiente tiene un manifiesto de integridad completo y sólo se reutiliza si también conserva OBJ/MTL originales. Un resultado sin compromiso de integridad se aparta sin borrarlo y se reconstruye, en lugar de publicarlo sin autenticación. Los errores de fuente/configuración/integridad se conservan y notifican al Store; no se reintentan automáticamente en bucle.

`DesktopStore` conserva los controladores fuera de sus hojas, espera la recuperación de guardados de biblioteca, reanuda IA que estaba ejecutándose y mantiene las pausas manuales. El auxiliar `trabajo-ia.json` acompaña cada derivado y permite enlazar una publicación cuyo `jobs.json` no llegó a actualizarse. Se distingue el UUID de trabajo del UUID que realmente asigna `ScanStore` al resultado.

El harness aislado `Tools/verify_desktop_ai_recovery.swift` usa imágenes sintéticas y una copia temporal de los pesos locales; no abre ni termina la app del usuario. La ejecución final aprobó con Core ML real: interrupción después del atlas 1, pausa manual conservada, reanudación automática por `DesktopStore` desde atlas 2 con exactamente dos predicciones totales, guardado real de biblioteca, hashes originales intactos y reparación idempotente del intervalo entre publicación e índice. También aprobó rechazo de pesos cambiados, fuente cambiada, salida alterada y symlink de metadata sin borrar el avance ni seguir el enlace. Son siete escenarios del harness, más su línea final de aprobación; no una suite XCTest ni una prueba de calidad fotográfica de una sala. Logs y recibo: `build/Research/DesktopAIRecovery/`.

El registro y la cola de `DesktopStore` incluyen también la fábrica `gaussianController(for:)` para el nuevo ejecutor Mac desarrollado en paralelo. Reconecta Gaussian antes de iniciar IA recuperada y excluye trabajos pesados distintos mientras hay uno reservado; la puerta del propio Gaussian permite reanudar su helper pausado. La implementación y pruebas del helper, entrenamiento, visor y publicación Gaussian se registran por separado. Esto todavía no convierte el transporte híbrido en una transferencia incremental/reanudable ni prueba un factor de mejora frente a Polycam.
