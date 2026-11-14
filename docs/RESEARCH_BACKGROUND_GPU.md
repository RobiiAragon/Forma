# GPU y procesamiento continuo en segundo plano

Investigación del 15 de octubre de 2026. Entorno observado: Xcode 27.0, SDK iOS 27.0; iPhone físico `iPhone19,2`, iOS 27.0.1. Esta revisión lee documentación, SDK y catálogo de capacidades; no constituye una prueba de ejecución GPU en segundo plano.

## Resultado para Forma

`BGContinuedProcessingTask` sí permite que un trabajo iniciado por la persona continúe al salir de la app. Sin embargo, **el permiso CPU existente de Forma no autoriza Metal en segundo plano**. Para Gaussian hay tres requisitos separados: concesión real de tarea, `BGTaskScheduler.supportedResources.contains(.gpu)` y firma/perfil que autoricen `com.apple.developer.background-tasks.continued-processing.gpu=true`. [Recurso GPU](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/resources/gpu), [recursos requeridos](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/requiredresources).

El catálogo incluido con Xcode 27 marca `BACKGROUND_GPU_ACCESS` únicamente para `APPLE_DEVELOPER_PROGRAM` y `APPLE_DEVELOPER_ENTERPRISE_PROGRAM`; **no incluye `XCODE_FREE_PROGRAM`**. Esto impide considerar esa capacidad disponible con el Personal Team actual. No se intentó alterar el perfil ni añadir un entitlement no autorizado. La clave correcta contiene `background-tasks`, con guion; `backgroundtasks` sería otra clave.

En cambio, el mismo catálogo sí incluye `XCODE_FREE_PROGRAM` en `INCREASED_MEMORY_LIMIT`. La autorización de mayor memoria y la autorización GPU en segundo plano son capacidades distintas; obtener la primera no concede la segunda.

## API y configuración comprobadas

| Elemento | Evidencia de SDK instalado | Uso correcto |
| --- | --- | --- |
| `BGContinuedProcessingTask`, request, `Resources.gpu`, `supportedResources` | `API_AVAILABLE(ios(26.0))` en los tres headers de BackgroundTasks | Condicionar por disponibilidad para el mínimo iOS 18 de Forma. No hay equivalente macOS en estas clases. |
| `requiredResources` por defecto | Valor cero: CPU y red | Adecuado para procesamiento CPU; no inferir permiso GPU por el hecho de que una tarea haya empezado. |
| `requiredResources = .gpu` | El header exige entitlement y advierte de rechazo de la solicitud si falta | Consultar soporte del dispositivo y validar la firma; no ejecutar Metal hasta tener concesión. |
| Solicitud | Se crea en primer plano; `earliestBeginDate` se ignora | Asociarla a una acción concreta de la persona. Identificador con prefijo del bundle y sufijo único. |
| Estrategia `.fail` / `.queue` | Fallo inmediato bajo condiciones inadecuadas / cola | La cola evita tratar una espera del sistema como un error definitivo. No elimina decisiones del planificador. |
| Registro | Excepción de registro posterior al arranque para continued tasks | Registrar una sola vez cada identificador. El SDK advierte que el registro duplicado termina la app. |
| Progreso | `BGContinuedProcessingTask` adopta `NSProgressReporting` | Comunicar unidades reales, título/subtítulo y finalización; no avanzar un porcentaje ficticio para evitar expiración. |
| Envío iOS 27 | Método asíncrono `submitTaskRequest`; `submit(_:)` anterior queda deprecado en iOS 27 | Recoger también errores asíncronos. Forma ya distingue iOS 27 del envío iOS 26. |

La configuración de Forma contiene `UIBackgroundModes = [processing]` y `BGTaskSchedulerPermittedIdentifiers = [com.robii.forma.processing.*]`. El coordinador actual registra y envía identificadores completos del mismo prefijo. Estas claves ayudan a admitir la tarea; no sustituyen la firma GPU. Los headers describen `notPermitted` para modo/identificador incorrectos, recursos no disponibles o denegación de lanzamientos por la persona. [BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler), [API de solicitud](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest).

## Qué puede interrumpir iOS

Apple presenta estas tareas como trabajo de minutos o más iniciado en primer plano. La concesión no equivale a ejecución ilimitada. El sistema puede encolar por falta de recursos; la persona puede cancelar desde su interfaz; cerrar la app desde el selector cancela el trabajo sin notificación de cancelación a la app. Los trabajos con poco progreso tienen mayor prioridad para terminarse cuando faltan recursos. La app debe conservar checkpoints y comunicar la causa real. [Guía oficial de procesamiento prolongado](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/).

El SDK precisa: “backgrounded workloads are not guaranteed runtime.” También permite expirar trabajos aparentemente estancados y obliga a atender `expirationHandler` y llamar `setTaskCompleted(success:)`. Por tanto, quitar pausas que decide Forma por un contador de avisos o por un umbral propio **sí es un cambio de producto**; quitar la revocación del permiso de iOS **no es una facultad de la app**. [Expiración](https://developer.apple.com/documentation/backgroundtasks/bgtask/expirationhandler), [finalización](https://developer.apple.com/documentation/backgroundtasks/bgtask/settaskcompleted(success:)).

No se encontró un tiempo fijo garantizado para una continued task ni una promesa de GPU disponible durante todo el bloqueo de pantalla. La implementación debe atender la concesión vigente y su expiración, en vez de usar un temporizador artificial que prometa una duración universal. La prueba CPU previa de Forma en segundo plano acredita CPU; no acredita Gaussian/Metal ni ejecución indefinida.

## Neural Engine: no confundir documentación futura con el SDK instalado

La web de Apple ya describe en beta `com.apple.developer.background-tasks.continued-processing.inference`, para acceso al Neural Engine desde segundo plano, incluso fuera de continued tasks. Esa página se identifica como información preliminar. No aparece dicho entitlement en el catálogo de capacidades local de Xcode 27 consultado, y el enum de recursos de su SDK solo declara `.gpu` y el valor por defecto. No hay evidencia suficiente para activarlo con este Personal Team ni para tratarlo como un recurso disponible del SDK instalado. [Background Inference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference).

La textura local de Forma usa su ruta CPU para la concesión actual. Gaussian de Msplat usa Metal: migrarlo al Neural Engine no consiste en cambiar una bandera de Core ML. Requeriría un motor distinto y validación numérica/calidad separadas.

## Ruta práctica sin pago para este proyecto

1. iPhone en primer plano: eliminar cuotas y pausas internas no requeridas; responder a avisos liberando cachés reemplazables, preservar resolución/fuentes y mantener checkpoints.
2. Trabajo CPU en segundo plano: solicitar la continued task, continuar mientras exista concesión y recuperar el trabajo tras una revocación.
3. Gaussian pesado: permitir continuar localmente en Mac con los mismos datos/checkpoint y publicar progreso al teléfono. macOS no depende de este entitlement de iOS. Evitar que reposo, cierre de app o desconexión se interpreten como ejecución garantizada.
4. Si cambia la firma autorizada en el futuro: comprobar `.gpu` en el dispositivo y ejecutar una prueba real foreground→background→bloqueo→expiración antes de anunciar soporte GPU de fondo.

## Fuentes locales auditadas

- `/Applications/Xcode.app/Contents/SharedFrameworks/DVTPortal.framework/Versions/A/Resources/DVTPortalCachedPortalCapabilities.json`: entradas `BACKGROUND_GPU_ACCESS`, `INCREASED_MEMORY_LIMIT` y `EXTENDED_VIRTUAL_ADDRESSING`.
- `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/BackgroundTasks.framework/Headers/BGTaskRequest.h`.
- Mismo directorio: `BGTask.h` y `BGTaskScheduler.h`.
- Proyecto: `Config/Forma-Info.plist`, `Forma/Core/ProcessingActivityCoordinator.swift`, `Tests/LocalAITextureTests.swift`.

Pendiente de prueba física específica: valor de `supportedResources` en el iPhone conectado y ejecución GPU con una firma que realmente la autorice. El modelo comercial del teléfono, por sí solo, no resuelve ninguno de esos dos requisitos.
