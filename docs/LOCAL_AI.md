# IA local de Forma

Forma incorpora restauración opcional de texturas con **Real-ESRGAN general_x4v3** mediante Core ML. La inferencia ocurre en la CPU/GPU del dispositivo, sin Comfy, Python, cuentas, servidores ni coste por procesamiento. El resultado es otra captura enlazada a la original.

## Uso

- **Mac:** seleccionar una captura OBJ o USDZ texturizada y pulsar **Restaurar textura con IA local…**. La primera vez se descarga el modelo gratuito de 2,3 MB y se verifica su SHA-256; después se puede procesar sin internet.
- **iPhone:** en la ficha de una captura OBJ o USDZ texturizada, abrir **Restaurar textura con IA**. El modelo va incluido en la app y no necesita descarga. Para una sala grande también se ofrece el flujo de procesamiento en Mac cuando se conservan fuentes RGB-D.
- Ajustar intensidad y crear una copia. Pausar solicita una parada cooperativa que se confirma al alcanzar un punto seguro. El guardado tiene sus propios controles y un resultado pendiente puede reintentarse. El original se conserva.

La opción restaura **apariencia a resolución nativa**. El modelo calcula una salida 4× que se integra de nuevo en el tamaño original; no se anuncia como cuatro veces más detalle medido. No cambia vértices, normales, UV, materiales ni calibración, y no rellena geometría faltante. Puede suavizar o inferir detalles: la comparación con el original sigue siendo necesaria.

## Energía y segundo plano en iPhone

La restauración de texturas del iPhone aplica un ciclo cooperativo de actividad/descanso: objetivo del 50 % en estado térmico normal, 35 % con temperatura moderada y 20 % en estado serio. En estado crítico espera enfriamiento. Es tiempo de trabajo entre bloques frente a descanso, no un porcentaje fijo de uso de CPU/GPU ni una garantía de temperatura. Una predicción o kernel ya iniciado termina antes del siguiente punto seguro. La Mac conserva su ejecución sin este descanso programado.

En iOS 26 o posterior, la restauración solicita una tarea continuada de **CPU** y empieza el trabajo después de recibir la concesión real de iOS. Usa Core ML CPU-only durante toda esa sesión para continuar al salir de Forma, sujeto a las decisiones del sistema. Sin concesión, se pausa al salir o bloquear; en iOS 18 también se conserva ese comportamiento. Una Live Activity no concede por sí misma tiempo de ejecución. La [validación](LOCAL_AI_VALIDATION.md) distingue inferencia en segundo plano, bloqueo y presentación visual.

La actividad personalizada ofrece porcentaje y estado en Dynamic Island y la pantalla bloqueada. En la vista expandida permite **Pausar** y, con autorización de ejecución continua, **Reanudar**. Si necesita primer plano, muestra **Abrir Forma**. Los controles usan `LiveActivityIntent` y enlaces locales, sin servidor ni notificaciones push. iOS decide qué actividad presenta y puede priorizar su propia tarjeta de tarea continuada; esa tarjeta del sistema es independiente de la de Forma. El usuario confirmó manualmente el 15 de octubre de 2026 que la pausa y la reanudación funcionan correctamente en el iPhone con Forma 0.7.

Desde 0.7.2, Gaussian usa ejecución continua: no agrega esperas térmicas ni pausas por avisos de memoria, independientemente de cuántos reciba. Conserva resolución y población de gaussianas. La pausa manual sigue disponible. Guarda checkpoint cada 30 segundos al terminar un paso, sin pasar a estado de pausa ni liberar el motor. Mantiene la pantalla encendida durante el trabajo. Su motor Metal conserva el requisito de primer plano con la firma actual: si iOS suspende su ejecución, guarda y libera GPU y al volver a Forma continúa automáticamente; una pausa manual o cancelación nunca se reanuda por volver al primer plano. El sistema conserva su control de recursos y puede terminar la app. El control de progreso no concede permiso GPU por sí mismo.

Espacios LiDAR solicita previsualización, refresco de malla visual y evaluación/guardado automático a 5 FPS. ARKit sigue ejecutando el sensor al formato real de menor cadencia disponible; no se anuncia un modo físico de 5 FPS si el hardware/API no lo ofrece. Las fotos nativas y HiRes conservan su resolución.

## Recuperación del trabajo en iPhone

El avance de la restauración se conserva en almacenamiento local **entre atlas completos**. Al volver a la ficha del mismo escaneo, **Reanudar trabajo con IA** reutiliza las texturas terminadas tras validar fuentes, modelo, configuración e integridad. El atlas que quedó a medias vuelve a procesarse desde su original: no hay recuperación por bloque individual de inferencia.

La intensidad se mantiene al recuperar. **Reiniciar desde el original** descarta sólo ese trabajo pendiente para comenzar otra configuración; no elimina el escaneo. Si el resultado ya terminó y falla el guardado, se puede reintentar sin repetir la inferencia. iOS puede interrumpir la ejecución aunque la actividad siga visible.

## Texturas y costuras

La entrada utiliza los mapas `map_Kd` referenciados por el OBJ/MTL o los PNG difusos internos referenciados por los materiales y UV del USDZ. No se recorren ni procesan las fotografías de la carpeta `fuentes`. Los formatos sin un perfil admitido se conservan y aparecen en el informe. El perfil validado es PNG sRGB de 8 bits con alfa opaco en la zona procesada.

El soporte USDZ está en Forma 0.9.3 build 19, instalada en Mac y preparada para iPhone. ModelIO lee UV y materiales; el empaquetador sustituye sólo los PNG difusos de una copia y conserva byte a byte las capas USD y los demás recursos. Compilan las apps macOS e iOS. Dos pruebas de integración con Core ML real validan inferencia, cancelación/reanudación y conservación de geometría/UV, márgenes, alfa y originales: `build/Research/USDZModelRestoration/verification.json`. Después pasaron 23 pruebas de simulador con el recurso Core ML incluido en la app: `build/FormaV093USDZSimulator-Retry.xcresult`. La prueba usa una escena sintética pequeña y no demuestra rendimiento ni mejora visual de la sala completa. El recorte real de un atlas Raw sólo mostró un suavizado leve: `build/Research/RawTextureROI-20261015/README.md`.

Cada isla UV se identifica antes de la inferencia. El contexto de la red se prepara con colores de esa misma isla; las islas se empaquetan en bloques independientes con margen de 40 píxeles. La composición conserva los márgenes originales y suaviza la transición dentro de la región válida. El tamaño fijo de entrada de la red es un bloque de trabajo, no una cuota de tamaño del atlas ni de número de capturas.

`ia-local.json` y el informe auxiliar registran modelo, texturas procesadas/omitidas, zonas elegibles, píxeles cambiados, bloques y tiempos; el registro de captura conserva también la intensidad. Estas cantidades miden trabajo realizado, no una puntuación de calidad ni precisión geométrica.

## Modelo y procedencia

- Pesos originales y licencia **BSD-3-Clause**: [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN), variante `realesr-general-x4v3`.
- Conversión Core ML: [hanxiao/real-esrgan-coreml](https://github.com/hanxiao/real-esrgan-coreml), release `v1.0.0`, `RealESRGAN_general_522_fp16.zip`.
- SHA-256 del archivo descargado: `41368af9dcbcc300c0fe0442202acbf98d30dc07c28d49bf656883f7fef3656a`.
- Entrada RGB NCHW `[1,3,522,522]`, valores `[0,1]`; salida `[1,3,2088,2088]`. Core ML spec 9: iOS 18 / macOS 15 o posteriores para este modelo. La app Mac base conserva su compatibilidad anterior; el motor comunica un error si el modelo no es compatible con ese sistema.
- Los avisos de licencia y procedencia se incluyen en los recursos de ambas apps. El modelo del iPhone se compila para iOS; no se reutiliza un binario compilado para Mac.

Los modelos TRELLIS2/Pixal3D encontrados en Comfy son generadores distintos, con varias dependencias y etapas. No se han integrado ni se afirma compatibilidad con Core ML por estar almacenados en Safetensors. Véase [inventario y viabilidad](LOCAL_AI_FEASIBILITY.md).

## Visor y evaluación

Forma conserva las mejoras del visor 0.6: consolidación de grupos de dibujo del OBJ, emisión neutra para las fotografías, zoom óptico y apertura de USDZ Raw dentro de Forma Desktop. La adaptación de texturas es exclusiva de la pantalla; los modelos exportados siguen siendo nativos. Véase [validación del visor](DESKTOP_VIEWER_QA.md).

El modelo neuronal integrado restaura texturas. Gaussian optimiza otra representación fotométrica; no se ha integrado un modelo neuronal que limpie o complete la malla. El material real de la sala sigue mostrando zonas sin observar, bordes rotos y errores de reconstrucción. La restauración fotográfica no demuestra superioridad frente a Polycam ni corrige por sí sola esos problemas de geometría.
