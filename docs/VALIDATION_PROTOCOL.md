# Protocolo reproducible: Forma frente a Polycam

Estado: protocolo propuesto el 14 de octubre de 2026; el ensayo controlado sigue pendiente. La sección final documenta una inspección de dos exportaciones existentes, que no cumple las condiciones de ese ensayo. Compilar, abrir el simulador o generar una demostración no valida la calidad del escáner físico.

## Preparación

Usar el mismo iPhone, versión de iOS, iluminación, objeto y recorrido. Registrar versiones de ambas apps, modo, ajustes, duración de captura y si el procesamiento se ejecuta localmente o en un servidor. Anotar qué funciones/exportaciones permite el plan de Polycam utilizado; si no están disponibles, marcar la métrica como «no evaluable» sin contratar nada ni eludir restricciones.

Hacer tres repeticiones por app y caso, alternando qué app se usa primero. Permitir que el teléfono vuelva a un estado térmico semejante entre intentos. Mantener el mismo intervalo de carga inicial y no cargar durante cada ensayo. Fijar el presupuesto de tiempo/recorrido antes de empezar; no dar vueltas adicionales solo a una app hasta que el resultado parezca mejor.

Preparar un objeto rígido con textura, otro mate con poco detalle, una habitación con mobiliario y una habitación con paredes poco texturadas. Añadir un caso brillante/negro/transparente para documentar cómo falla cada ruta. Marcar tres distancias accesibles en cada caso y medirlas con una regla o calibre disponible. Registrar instrumento y repetición de la medida: esas distancias no constituyen una referencia de toda la superficie.

## Comprobación previa en el teléfono

1. Denegar cámara: la app informa del problema y permite volver a Ajustes. Autorizarla y volver a intentar.
2. Entrar/salir de cada modalidad: la cámara se activa solo en la captura y la sesión se detiene o pausa al salir. En Objetos, probar segundo plano y continuar; el proceso pesado no debe asumirse activo indefinidamente fuera de la app.
3. Probar luz insuficiente y movimiento rápido: registrar instrucciones del sistema y recuperación del seguimiento.
4. Capturar un objeto completo, reconstruirlo localmente y guardar USDZ con originales. Abrir el archivo fuera de Forma; verificar orientación, escala y texturas.
5. Capturar una habitación con LiDAR y otra con RoomPlan; guardar, reiniciar la app y volver a abrir/exportar.
6. Cancelar una captura/proceso y comprobar que no aparece un modelo exitoso vacío. Interrumpir un guardado de forma controlada en una prueba de desarrollo: la biblioteca debe permitir reintentar sin perder fuentes.
7. Probar sesión larga hasta observar comportamiento térmico real. No calentar artificialmente el teléfono; registrar las pausas y el acceso a las fotografías ya capturadas.

Las pruebas de poco espacio y memoria se hacen con condiciones controladas y archivos de prueba propios. No llenar el dispositivo del usuario hasta comprometer sus otros datos.

## Formulario por intento

Copiar este bloque para cada captura. Adjuntar exportación y capturas de pantalla con el mismo identificador.

| Campo | Registro |
| --- | --- |
| Identificador / fecha / responsable | |
| App / versión / plan | |
| iPhone / iOS / espacio libre inicial | |
| Caso / modo / ajustes | |
| Luz / recorrido / distancia aproximada | |
| Batería inicial → final | |
| Estado térmico inicial → final / pausas | |
| Captura / procesamiento / guardado, en segundos | |
| Número de fotos / fuentes conservadas | |
| Formatos / tamaño exportado / apertura externa | |
| Fallos / recuperación / intervención necesaria | |

Registrar el estado térmico que Forma puede observar con `ProcessInfo`. Para comparar temperatura entre apps usar el mismo método externo si existe. No comparar una etiqueta interna de Forma con una sensación subjetiva durante Polycam. El porcentaje de batería es una aproximación, no una medición de energía en vatios-hora.

| Distancia | Referencia (mm) | Modelo (mm) | Error absoluto (mm) | Error relativo (%) |
| --- | ---: | ---: | ---: | ---: |
| A | | | | |
| B | | | | |
| C | | | | |

`Error absoluto = abs(modelo − referencia)`; `error relativo = 100 × error absoluto / referencia`. Evitar referencias demasiado pequeñas respecto a la resolución del instrumento.

| Región acordada antes de capturar | Completa / agujeros | Detalle conservado | Textura y uniones visibles |
| --- | --- | --- | --- |
| Frente / pared principal | | | |
| Lateral / esquina | | | |
| Reverso / zona oculta | | | |
| Base / suelo | | | |

Usar las mismas cámaras y encuadres en las capturas del visor. Contar triángulos sirve para describir el archivo; más triángulos no demuestra mejor geometría. Si no hay una referencia de superficie fiable, describir agujeros, bordes y medidas concretas; no declarar un error global milimétrico.

## Decisión después de tres repeticiones

Comparar mediana y rango de errores/tiempos, junto con el número de capturas que producen un archivo válido. Registrar también los fallos. Una mejora solo se considera demostrada para el caso, modalidad y configuración probados. Separar fidelidad geométrica, apariencia, usabilidad y costo de acceso/exportación.

Antes de cambiar un algoritmo, escribir qué métrica pretende mejorar y qué regresión sería inaceptable. Por ejemplo: «reducir agujeros en el reverso del objeto manteniendo el error de las tres distancias y el tiempo total dentro del rango acordado». Elegir el criterio antes de ver los resultados y conservar las fuentes para repetir el proceso sin volver a capturar.

## Iteraciones locales para mejorar calidad

| Etapa | Trabajo concreto | Criterio de salida |
| --- | --- | --- |
| 1. Integridad y adquisición | Corregir errores observados de permisos, interrupciones, guardado y exportación; manifiesto de ajustes y archivos originales | Capturas repetidas generan archivos reabribles y fallos recuperables; ninguna demostración se presenta como medición real |
| 2. Guía de captura | Retroalimentación real de movimiento/luz/distancia; sugerir distintas alturas; visualizar regiones observadas sin inventar cobertura total | Menos regiones ausentes y menos fallos con igual presupuesto de captura |
| 3. Cámara nativa | Evaluar fotos de alta resolución, exposición, enfoque, balance y apertura iOS 27 mediante soporte del formato; comparar configuraciones | Mejora medible de nitidez/textura sin más deriva ni pérdidas de seguimiento |
| 4. Edición | Recorte por volumen, eliminación de componentes aislados, orientación y selección precisa para medir; conservar original | Edición/exportación reversible sin alterar escala y sin crear geometría que se confunda con medición |
| 5. RGB-D | Conservar profundidad/confianza/pose/intrínsecos y RGB sincronizado; validar reproyección; experimentar con fusión incremental propia en Metal | Menos agujeros o mejor error frente a referencia que la malla ARKit, en el mismo conjunto de datos |
| 6. Texturizado | Seleccionar fotos por nitidez/ángulo, descartar oclusiones y proyectarlas con calibración; crear UV/atlas y suavizar uniones | Más detalle y menos costuras en regiones acordadas, sin proyectar color a superficies ocultas |
| 7. Escala y duración | Almacenamiento incremental, presupuestos de memoria y refinamiento por regiones; RoomPlan para varias habitaciones según soporte | Sesiones más largas sin pérdida silenciosa de datos ni crecimiento ilimitado en RAM |
| 8. Refinamiento opcional en Mac | Consumir originales y checkpoints con herramientas/APIs locales; comparar niveles de detalle admitidos por macOS | Ganancia de calidad medida y exportación portable, sin introducir dependencia obligatoria de servidor |

Estas etapas usan el hardware y herramientas locales disponibles; no requieren contratar nube ni añadir cuotas comerciales a la app. Requieren desarrollo y validación. La API de fotogrametría en iOS tiene límites de hardware y nivel `.reduced`, aunque se conserven más imágenes. Un motor propio o proceso en Mac puede explorar otras opciones; no se considera implementado por mencionarlo en la hoja de ruta.

Los fundamentos y enlaces primarios de Apple están en [HARDWARE_AND_ARCHITECTURE.md](HARDWARE_AND_ARCHITECTURE.md): [Object Capture](https://developer.apple.com/documentation/realitykit/objectcapturesession), [PhotogrammetrySession](https://developer.apple.com/documentation/realitykit/photogrammetrysession), [profundidad de escena](https://developer.apple.com/documentation/arkit/ardepthdata), [RoomPlan](https://developer.apple.com/documentation/roomplan) y [captura LiDAR con AVFoundation](https://developer.apple.com/documentation/avfoundation/capturing-depth-using-the-lidar-camera).

## Inspección de los archivos aportados, 15 de octubre de 2026

El usuario identificó ambos archivos como capturas de la misma sala y pidió comparar primero esos archivos. El SHA-256 del OBJ aportado coincide exactamente con el de la captura LiDAR real conservada en Forma, sin usar la demostración de la biblioteca. El ZIP de Polycam contiene un único GLB.

| Dato del archivo | Forma, OBJ anterior | Polycam, GLB |
| --- | ---: | ---: |
| Triángulos | 306.113 | 65.477 |
| Vértices en la fuente | 168.280 | 38.801 |
| Vértices usados por las caras | 166.528 | 38.801 |
| Coordenadas UV | No | Sí |
| Fotografías de textura | Ninguna | Dos atlas JPEG: 4.096 × 4.096 y 4.096 × 544 |
| Tamaño del modelo sin ZIP | 12.243.042 bytes | 3.008.972 bytes |

Los renders nuevos muestran apariencia fotográfica reconocible en Polycam y superficies más continuas en su región capturada, aunque también hay texturas estiradas y zonas ausentes. Forma abarca una región mayor y su malla aparece fragmentada; el OBJ carece de color y fotografías. El número superior de triángulos no demuestra más detalle real. La suma del área de los triángulos no se interpreta como área de suelo.

La herramienta `Tools/compare_model_exports.py` conserva las fuentes y genera pares con igual cámara, escala y descarte de caras traseras. Los pases de albedo usan el color original sin iluminación metálica y los pases de inspección usan el mismo material gris. Los ocho renders nuevos verifican que todos los vértices caben en el encuadre. Los doce renders iniciales se conservan como diagnósticos con encuadre inválido y no sustentan estas conclusiones.

La alineación rígida sigue sin verificar y tiene varias soluciones de orientación semejantes. No se midió error físico, precisión dimensional, FPS del iPhone ni tiempo de Polycam. Tampoco se controlaron recorrido, luz, ajustes o cobertura. El informe JSON y las imágenes privadas permanecen en `build/Comparison/2026-10-15/Report`, excluido de Git.

El OBJ corresponde a una captura previa al registro de fotos de Forma y no permite evaluar el nuevo texturizado de 0.3. Las pruebas de código verifican selección de fotos, oclusiones y continuidad; falta validar su apariencia con una captura que conserve esas fuentes. La versión 0.3 instalada abrió la sala real y el estudio en el iPhone: mostró tiempos de lectura y primer cuadro, dejó la cadencia en `—` durante reposo y conservó el modelo al recentrar. Esa comprobación de interfaz no sustituye una medición de fluidez en movimiento.
