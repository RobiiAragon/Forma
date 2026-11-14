# ASO — Forma y Forma Desktop

Revisión editorial: 18 de octubre de 2026; incorporada sin cambiar sus propuestas a la entrega 0.9.5 (22) del 20 de octubre. **Documento de posicionamiento y metadatos propuestos; no es una ficha publicada.** Proyecto: `Forma.xcodeproj`, targets `Forma` (iOS/iPadOS) y `FormaDesktop` (macOS). Se conserva el nombre base, icono y branding aprobados. Disponibilidad del nombre en App Store y revisión de marca: **pendientes**. Los descriptores de título son propuestas, no un cambio de nombre dentro de la app.

## 1. Posicionamiento

**Persona prioritaria:** creador 3D, diseñador o estudiante con un dispositivo compatible que quiere digitalizar un objeto o espacio y conservar archivos utilizables. En Mac, quien ya tiene fuentes de Forma y desea procesarlas e inspeccionarlas localmente.

**Problema:** pasar de una captura a un modelo que se pueda revisar, volver a procesar y exportar, sin depender de cargar las fotografías a un servicio de procesamiento remoto.

**Propuesta:** un flujo local de captura, fuentes conservadas, exploración y exportación; iPhone para adquirir, Mac para continuar el trabajo pesado. Gaussian es una representación adicional de apariencia, no una promesa de geometría métrica. El posicionamiento se apoya en el control del flujo, no en prometer la mejor reconstrucción del mercado.

**Contexto competitivo interno:** Polycam y ScanSpace fueron referencias de flujo, visores y texturizado en la investigación previa. No hay evidencia comparable suficiente para afirmar superioridad de Forma. No se usarán sus nombres en campos de búsqueda, títulos, capturas ni copy público. No se asignan volumen, dificultad o ranking a ninguna palabra sin datos.

**Modelo comercial:** compra única al descargar cada producto según su configuración final, con acceso completo. Sin IAP, StoreKit, suscripciones, anuncios o desbloqueos locales. El usuario decide precio, territorios y publicación. No se promete que comprar una plataforma incluya otra: la distribución conjunta/compra universal aún no está definida.

## 2. Lo que existe y lo que no debe prometerse

| Plataforma/área | Evidencia local | Consecuencia para la ficha |
|---|---|---|
| iOS/iPadOS | `ScanModels`, `LiDARCaptureView`, `ObjectScanView`, `RoomScanView`; mínimo iOS 18, familias iPhone/iPad en el generador | Espacios LiDAR, Objetos y Planos existen, condicionados por soporte nativo. No anunciar captura en cualquier iPhone/iPad. |
| Objetos en iPhone | Reconstrucción Apple; detalle `reduced` disponible en el SDK móvil | No anunciar Raw/Full ni reconstrucción móvil 16K como prestación garantizada. |
| Mac | `DesktopStore`, `DesktopPhotogrammetry`, `DesktopModelViewer`; mínimo macOS 14 | Recibe/importa fuentes RGB-D de Forma; no es captura con la cámara del Mac ni un importador genérico de cualquier conjunto JPEG. |
| Hardware Mac | Worker Gaussian real en `build/GaussianDesktopWorker` es arm64; el ejecutable principal se ha compilado también universal | No afirmar soporte Intel para el flujo completo. Resolver elegibilidad y paquete comercial antes de publicar. |
| Idiomas | Texto propio mayoritariamente escrito en español; no hay catálogos `.xcstrings`, `.strings` o `.lproj` de traducción en fuentes; `knownRegions` por sí solo no traduce | UI actual en español. es-MX es propuesta editorial de ficha; en-US es traducción de metadatos con aviso explícito del idioma actual, no una localización inglesa de la app. |
| Offline | Motores locales y fuentes guardadas; `Mac/LocalAIModelStore` conserva instalación/cache del modelo existente | No se suben capturas para procesar. La restauración opcional en Mac necesita una descarga inicial si falta el modelo. No prometer todo offline desde la primera instalación. |
| Calidad | Revisión `docs/GEOMETRY_QUALITY_20261018.txt`: filtro sintético mejora, sala antigua sin regiones aceptadas | Excluir “paredes perfectas”, “elimina gotelé”, exactitud milimétrica, velocidad/FPS de reconstrucción garantizados, “mejor que Polycam” y límites físicos inexistentes. |
| Build | Funciones base en 0.9.4; revisión de arquitectura/accesibilidad build 21 preparada | Redactar y fotografiar únicamente la versión que finalmente se envíe a revisión; no reutilizar pruebas como assets comerciales. |

## 3. Categoría recomendada

**Principal propuesta para ambas plataformas: Graphics & Design / Gráficos y diseño.** El resultado central es un recurso 3D editable/exportable para un flujo creativo; no una cámara de video ni una herramienta de medición certificada. **Secundaria candidata: Photo & Video / Foto y video**, si la plataforma y configuración lo permiten, por la adquisición y reconstrucción fotográfica. Confirmar opciones y nombres localizados al crear cada ficha; no poner nombres de categorías en keywords. No seleccionar una categoría solo por competencia supuesta. [Definiciones de Apple](https://developer.apple.com/app-store/categories/).

## 4. Metadatos propuestos por plataforma y localización

Los bloques de descripción contienen texto plano para pegar, sin las marcas Markdown. Si se utiliza una ficha multiplataforma, decidir antes qué nombre/subtítulo se comparten y adaptar estos borradores: no cargar títulos incompatibles en un campo común. Los campos en-US están listos como propuesta de ficha **solo con el aviso de UI en español y capturas reales coherentes**; no marcar inglés como idioma de interfaz hasta traducirlo y verificarlo.

### iOS / iPadOS — es-MX
**Título:**

```text
Forma: Escaneo 3D local
```
**Subtítulo:**

```text
LiDAR y fotos sin nube
```
**Keywords:**

```text
fotogrametría,objetos,habitaciones,mallas,texturas,planos,exportar,modelado
```
**Promocional:**

```text
Captura espacios, reconstruye objetos y conserva tus originales. Explora y exporta modelos 3D con procesamiento local en dispositivos compatibles.
```
**Descripción:**

```text
Dale forma a lo real con el iPhone o iPad. Forma reúne captura de espacios con LiDAR, fotogrametría de objetos y planos de habitaciones, con procesamiento local y archivos que puedes conservar.

ELIGE CÓMO CAPTURAR
Espacios combina la malla LiDAR con fotografías para crear modelos con textura. Objetos utiliza la captura y reconstrucción local de Apple. Planos organiza muros, puertas y ventanas con RoomPlan.

EXPLORA Y LLEVA TUS MODELOS CONTIGO
Gira, amplía y alterna entre textura y geometría. Consulta medidas estimadas y exporta OBJ, PLY, STL o USDZ según el tipo de captura. Conserva las fuentes disponibles para volver a procesar sin sustituir el original.

CONTINÚA EN TU MAC
Envía fuentes a Forma Desktop por la red local para procesarlas en tu computadora. Para continuar necesitas Forma Desktop en un Mac compatible. No se necesita una cuenta de Forma ni subir las capturas a un servidor.

OTRA FORMA DE EXPLORAR TUS CAPTURAS
Entrena Gaussian 3D a partir de fotografías y cámaras calibradas guardadas. Puedes elegir resolución e iteraciones y continuar desde checkpoints disponibles. Esta representación visual no certifica medidas.

COMPATIBILIDAD Y RESULTADOS
Requiere iOS/iPadOS 18 o posterior y hardware compatible con el modo elegido. La captura de espacios y habitaciones necesita LiDAR; Objetos requiere compatibilidad con Object Capture y fotogrametría local. Revisa las capacidades en Dispositivo. La iluminación, el recorrido y los recursos del equipo influyen en el resultado. Las medidas son estimaciones. El procesamiento Metal puede requerir mantener Forma en primer plano.

Interfaz actual en español. Compra única al descargar, con acceso completo y sin compras internas, suscripciones ni anuncios. El precio se muestra en la tienda.
```
### iOS / iPadOS — en-US
**Título:**

```text
Forma: Local 3D Scanner
```
**Subtítulo:**

```text
LiDAR & photos, on device
```
**Keywords:**

```text
photogrammetry,objects,rooms,mesh,textures,floorplans,export,gaussian,splatting
```
**Promocional:**

```text
Capture spaces, reconstruct objects and keep your source files. Explore and export 3D models with local processing on supported devices.
```
**Descripción:**

```text
Turn your surroundings into 3D assets you can keep. Forma brings LiDAR space capture, object photogrammetry and room layouts together, with processing on your iPhone or iPad.

CAPTURE FOR YOUR WORKFLOW
Spaces combines a LiDAR mesh with photographs for textured models. Objects uses Apple’s local capture and reconstruction tools. Room layouts organize walls, doors and windows with RoomPlan.

INSPECT, KEEP AND EXPORT
Rotate and zoom into your models, switch between texture and geometry, and inspect estimated measurements. Export OBJ, PLY, STL or USDZ depending on the capture type. Retain available source data and save reprocessed results as separate copies.

KEEP WORKING ON YOUR MAC
Send capture sources over your local network to Forma Desktop for processing on your computer. Continuing on Mac requires Forma Desktop on a compatible Mac. No Forma account or server upload is required.

EXPLORE GAUSSIAN 3D
Train Gaussian representations from saved photographs and calibrated cameras. Choose resolution and iteration settings, and continue from available checkpoints. Gaussian appearance is not certified measurement geometry.

CHECK DEVICE SUPPORT
Requires iOS/iPadOS 18 or later and hardware supported by the selected mode. Space and room capture need LiDAR. Objects needs Object Capture and local photogrammetry support. Check the Device screen before starting. Lighting, camera movement and available resources affect results. Measurements are estimates. Metal processing may require keeping Forma in the foreground.

The current interface is in Spanish. One purchase when downloading gives full access, with no in-app purchases, subscriptions or ads. See the store for the price.
```
### macOS — es-MX
**Título:**

```text
Forma Desktop: 3D local
```
**Subtítulo:**

```text
Fotogrametría en tu Mac
```
**Keywords:**

```text
mallas,texturas,objetos,habitaciones,reconstrucción,gaussianas,exportar,modelado
```
**Promocional:**

```text
Continúa tus capturas de Forma en el Mac. Reconstruye desde las fuentes, revisa textura y geometría, y conserva resultados independientes del original.
```
**Descripción:**

```text
Dale a tus capturas un lugar para seguir trabajando. Forma Desktop recibe fuentes de Forma por la red local o importa carpetas RGB-D compatibles, y las procesa en tu Mac.

RECONSTRUCCIÓN FOTOGRÁFICA LOCAL
Reconstruye a partir de las fotografías de la captura. Elige entre los niveles de detalle disponibles del motor de Apple y ajusta sensibilidad, máscara y orden de imágenes. En el modo personalizado puedes elegir presupuestos de geometría y textura; son solicitudes al motor, no garantías de precisión ni del tamaño final.

REVISA LO QUE HAS CREADO
Explora el modelo, amplía detalles y cambia entre geometría, textura original y textura ligera de visualización. La copia ligera del visor no reduce los archivos de exportación. Abre la carpeta de resultados o comparte el modelo nativo según su formato.

FUENTES Y COPIAS BAJO TU CONTROL
Conserva fotografías, calibración y malla de origen. Los resultados derivados se guardan como copias independientes. Los procesos compatibles ofrecen pausa y cancelación manual; la fotogrametría de Apple tiene su propio comportamiento de interrupción.

GAUSSIAN Y RESTAURACIÓN LOCAL
Entrena Gaussian 3D desde fuentes calibradas y continúa desde checkpoints disponibles. La restauración opcional de texturas utiliza un modelo local: si aún no está instalado, necesita una descarga inicial; después procesa sin conexión.

COMPATIBILIDAD
Requiere macOS 14 o posterior. El flujo completo está orientado a Mac con Apple silicon; el motor Gaussian incluido requiere esa arquitectura. La fotogrametría se habilita donde Apple la admite. Se necesitan fuentes de captura compatibles; la app no escanea escenas con la cámara del Mac. La captura con iPhone requiere Forma para iOS en un dispositivo compatible. Memoria, almacenamiento y fotografías influyen en tiempo y resultado; no se certifica precisión física.

Interfaz actual en español. Compra única al descargar, con acceso completo y sin compras internas, suscripciones ni anuncios. Consulta el precio en la tienda.
```
### macOS — en-US
**Título:**

```text
Forma Desktop: 3D Studio
```
**Subtítulo:**

```text
Photogrammetry on your Mac
```
**Keywords:**

```text
mesh,textures,reconstruction,objects,rooms,gaussian,splatting,export,models
```
**Promocional:**

```text
Bring Forma captures to your Mac. Reconstruct from source photos, inspect texture and geometry, and keep derived results separate from the original.
```
**Descripción:**

```text
Give your captures room to develop. Forma Desktop receives Forma sources over your local network or imports compatible RGB-D folders, then processes them on your Mac.

LOCAL PHOTOGRAMMETRY
Reconstruct from the photographs in a capture. Choose available Apple reconstruction detail levels and adjust sensitivity, masking and image ordering. Custom mode offers geometry and texture budgets. These are requests to the engine, not guarantees of physical accuracy or final output size.

INSPECT YOUR RESULTS
Explore the model, zoom into details and switch between geometry, original textures and lighter display textures. The lighter viewer copy does not reduce exported files. Open the results folder or share the native model, depending on its format.

KEEP THE SOURCES
Preserve source photographs, calibration and mesh data. Derived results are saved as separate copies. Supported processes offer manual pause and cancellation; Apple photogrammetry has its own interruption behavior.

GAUSSIAN AND LOCAL TEXTURE RESTORATION
Train Gaussian 3D from calibrated sources and continue from available checkpoints. Optional texture restoration uses a local model. If it is not installed, an initial download is required; processing then works offline.

COMPATIBILITY
Requires macOS 14 or later. The complete workflow is intended for Apple silicon Macs; the included Gaussian worker requires that architecture. Photogrammetry is available where supported by Apple. Compatible capture sources are required: this app does not scan scenes using your Mac’s camera. iPhone capture requires Forma for iOS on a supported device. Memory, storage and input photos affect processing time and results. Physical accuracy is not certified.

The current interface is in Spanish. One purchase when downloading gives full access, with no in-app purchases, subscriptions or ads. See the store for the price.
```
## 5. Validación automática de los campos

Comprobación simple con Python sobre estos valores: normalización NFC, caracteres Unicode, bytes UTF-8, ausencia de keywords duplicadas o comas con espacios; sin una suite de pruebas ni builds. Keywords cumplen **ambos límites: 100 caracteres y 100 bytes**. El límite técnico de Apple es de bytes y la guía comercial habla de caracteres; se aplica la condición más restrictiva y se valida otra vez al pegar en Connect. [Referencia técnica](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) · [Guía de ficha](https://developer.apple.com/app-store/product-page/).

| Plataforma | Localización | Campo | Caracteres | Bytes UTF-8 | Resultado |
|---|---|---|---:|---:|---|
| iOS / iPadOS | es-MX | Título | 23 | 23 | Cumple |
| iOS / iPadOS | es-MX | Subtítulo | 22 | 22 | Cumple |
| iOS / iPadOS | es-MX | Keywords | 75 | 76 | Cumple |
| iOS / iPadOS | es-MX | Promocional | 146 | 146 | Cumple |
| iOS / iPadOS | es-MX | Descripción | 1761 | 1779 | Cumple |
| iOS / iPadOS | en-US | Título | 23 | 23 | Cumple |
| iOS / iPadOS | en-US | Subtítulo | 25 | 25 | Cumple |
| iOS / iPadOS | en-US | Keywords | 79 | 79 | Cumple |
| iOS / iPadOS | en-US | Promocional | 136 | 136 | Cumple |
| iOS / iPadOS | en-US | Descripción | 1691 | 1693 | Cumple |
| macOS | es-MX | Título | 23 | 23 | Cumple |
| macOS | es-MX | Subtítulo | 23 | 24 | Cumple |
| macOS | es-MX | Keywords | 80 | 81 | Cumple |
| macOS | es-MX | Promocional | 151 | 153 | Cumple |
| macOS | es-MX | Descripción | 2004 | 2038 | Cumple |
| macOS | en-US | Título | 24 | 24 | Cumple |
| macOS | en-US | Subtítulo | 26 | 26 | Cumple |
| macOS | en-US | Keywords | 75 | 75 | Cumple |
| macOS | en-US | Promocional | 148 | 148 | Cumple |
| macOS | en-US | Descripción | 1879 | 1881 | Cumple |

Validación adicional editorial: no se repite Forma/empresa/términos de título y subtítulo en el campo keywords correspondiente; no hay competidores, “app”, precios ni funciones ajenas en keywords. Las palabras son hipótesis de intención, no estimaciones de tráfico. Descripciones <4000 caracteres, promocionales <170 y títulos/subtítulos <30. No repetir el nombre de empresa cuando se defina; revisar entonces cualquier coincidencia nueva.

## 6. Guion de capturas — producción pendiente

**No se han producido capturas comerciales en este encargo.** Son instrucciones de captura y composición. Usar la app funcionando, una versión concreta y resultados guardados reales, con derechos de uso y sin datos personales. No fabricar pantallas inglesas ni reemplazar detalles del modelo mediante retoque/IA. Mantener el icono y la identidad existentes. Un titular en-US sobre UI española debe seguir mostrándola tal cual y coincidir con el aviso de idioma.

Apple permite hasta 10 capturas; se proponen 7 por plataforma. Las **1–3 tienen prioridad** porque pueden mostrarse en búsquedas: primero resultado, luego forma de obtenerlo, luego conservación/exportación. No usar una portada solo con logo. [Presentación del producto](https://developer.apple.com/app-store/product-page/) · [Metadatos precisos, §2.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).

### iOS/iPadOS — siete capturas

| Orden | Pantalla real y beneficio | Titular es-MX | Headline en-US | Prueba visual requerida |
|---:|---|---|---|---|
| **1** | Estudio 3D, modelo texturizado guardado; explorar un resultado propio | Tu captura, en tres dimensiones | Your capture, in three dimensions | Modelo completo con controles del visor visibles. Resultado real elegido tras revisar artefactos; no afirmar calidad universal. |
| **2** | Espacios durante captura; comprender la adquisición | Recorre tu espacio con LiDAR | Walk your space with LiDAR | Escena y malla superpuesta reales en dispositivo con LiDAR, estado de captura visible; no simulador ni representación generada. |
| **3** | Detalle > archivos/exportación; llevarse el trabajo | Conserva y exporta tus modelos | Keep and export your models | Opciones y formatos que existan en esa captura; nombres no personales y original conservado. |
| 4 | Objetos, revisión de una captura terminada; digitalizar un objeto | Dale otra dimensión a tus objetos | Give your objects another dimension | Objeto rígido real reconstruido y estado de resultado; no render externo presentado como captura. |
| 5 | Planos, revisión RoomPlan; organizar una habitación | Revisa la distribución del espacio | Review your room layout | Muros/puertas de la habitación real, sin superponer cotas certificadas; si aparecen medidas, mantener aviso de estimación. |
| 6 | Gaussian 3D, visor de un resultado completado; otra representación | Explora tu captura con Gaussian 3D | Explore your capture in Gaussian 3D | Resultado real entrenado de fuentes conservadas. No usar una pantalla de configuración como prueba de resultado ni prometer malla métrica. |
| 7 | Enviar a Forma Desktop, estado local; continuar en computadora | Sigue trabajando en tu Mac | Keep working on your Mac | Transferencia local realmente conectada o finalizada; Forma Desktop identificada como componente necesario en Mac, sin insinuar compra universal. No inventar un estado de conexión. |

### macOS — siete capturas

| Orden | Pantalla real y beneficio | Titular es-MX | Headline en-US | Prueba visual requerida |
|---:|---|---|---|---|
| **1** | Visor Desktop con modelo guardado; inspección amplia | Tus capturas, en el Mac | Your captures, on your Mac | Ventana real, modelo texturizado, controles de vista visibles; no apariencia más detallada que el archivo exportado. |
| **2** | Reconstrucción fotográfica; decidir cómo procesar | Elige cómo reconstruir | Choose how to reconstruct | Opciones reales Raw/Full/Custom y ajustes disponibles en la versión enviada. Mostrar presupuestos como ajustes, no como prueba de precisión. |
| **3** | Resultado y exportación/Finder del propio modelo; conservar archivos | Conserva fuentes y resultados | Keep sources and results | Ventana real con exportación y resultado identificado; evitar información personal del Finder y mostrar la app como protagonista. |
| 4 | Recepción local desde iPhone; flujo entre equipos | Del iPhone a tu red local | From iPhone to your local network | Estado real de recepción/completado. No mostrar claves de emparejamiento de una sesión activa ni anunciar USB sin validarlo para la distribución. |
| 5 | Visor de geometría; separar superficie de textura | Revisa también la geometría | Inspect the geometry, too | Misma captura y encuadre al cambiar de material; no un antes/después que sugiera ruido eliminado. |
| 6 | Gaussian Desktop; explorar representación entrenada | Otra vista de tus capturas | Another view of your captures | Resultado completado en Mac Apple silicon, controles reales y sin promesas de tiempo, memoria o precisión. |
| 7 | Restauración local, copia terminada; conservar el original | Restaura una copia de la textura | Restore a copy of the texture | Mismo encuadre, sin retocar exportaciones. Solo producirla si una copia real muestra un beneficio defendible; si no, sustituir por panel de proceso con pausa manual y titular “Controla el procesamiento” / “Control processing”. |

**Preparación de assets:** seleccionar la familia de iPhone/iPad que exija Connect en el envío y verificar sus resoluciones vigentes; no deducirlas del modelo del simulador. Para Mac, propuesta 2560×1600 (16:10), tamaño admitido actualmente. No escalar ni recortar una captura que haga ilegibles o falsee controles. Producir versiones por dispositivo/idioma; confirmar requisitos de iPad porque el target incluye esa familia. [Especificaciones oficiales](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

## 7. Checklist previo a la ficha

- [ ] Confirmar disponibilidad de Forma / Forma Desktop, marcas y denominación del desarrollador. No se hizo búsqueda legal ni reserva.
- [ ] Decidir fichas separadas o estrategia multiplataforma, compra universal o no; fijar precio/territorios por el usuario. No usar precios ni “gratis” en las imágenes/títulos.
- [ ] Confirmar elegibilidad de dispositivos en el paquete comercial: iOS exige soporte real por modo y `Config/Forma-Info.plist` no demuestra un filtro comercial de LiDAR. La UI de incompatibilidad no sustituye una ficha clara antes de comprar.
- [ ] Resolver el ejecutable Mac universal con worker Gaussian arm64: no ofrecer el flujo completo a Intel sin soporte validado; alinear requisitos, empaquetado y ficha. No es una tarea de implementación de este ASO.
- [ ] Validar captura, RoomPlan, Gaussian, exportación y transferencia en los equipos que se anuncien, y distinguir iPhone de iPad. Los builds y pruebas sintéticas previas no certifican calidad física.
- [ ] Revisar interfaz en español para México; no afirmar una traducción inglesa completa. Si se decide traducir, localizar UI, permisos, errores, ayuda y accesibilidad antes de anunciar inglés. La ficha localizada no localiza el binario. [Localización de información](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information/).
- [ ] Producir las siete capturas reales por plataforma y variantes es-MX/en-US; ningún storyboard es un asset terminado. Guardar origen, build, dispositivo, idioma, permiso de uso y encuadre por imagen.
- [ ] Verificar derivados del icono aprobado (incluida entrega Mac); no se necesita un rediseño. Preview de video opcional, no bloqueante ni producido.
- [ ] Disponer de URL real de soporte, contacto y política de privacidad; completar formularios de privacidad, clasificación por edades, derechos, licencias del motor/modelo y requisitos de exportación. No marcar “sin datos” solo por usar procesamiento local sin revisar todos los flujos.
- [ ] Revisar permisos de red local/cámara y comportamiento offline, incluida la descarga inicial opcional del modelo de textura en Mac. No prometer ausencia absoluta de internet en instalación inicial.
- [ ] Confirmar copy frente al build final y recalcular caracteres/UTF-8 después de cualquier edición. Pegar y validar límites en Connect, sin asumir aprobación automática.

## 8. Medición e iteración orgánica después del lanzamiento

No hay métricas de lanzamiento, posiciones ni estimaciones de búsquedas disponibles. Las siguientes son hipótesis; no resultados. Usar las métricas disponibles de App Store Connect sin añadir SDK de analítica ni compras de herramientas/anuncios. Separar plataforma, territorio e idioma cuando el panel lo permita y anotar versión, precio y cambios editoriales.

| Señal | Pregunta / interpretación | Acción posible |
|---|---|---|
| Impresiones y fuente App Store Search | ¿Aparece la ficha en búsquedas relevantes? No todas las consultas o desgloses estarán disponibles. | Revisar relevancia del título/subtítulo/keywords, sin inventar una posición o demanda. |
| Visitas a ficha desde búsqueda, cuando el desglose exista | ¿El resultado invita a abrir? Calcular visitas/impresiones solo con población, fuente y periodo compatibles; no todas las descargas pasan por una visita. | Cambiar una sola hipótesis visual de las primeras capturas; conservar nombre/icono aprobados. |
| Descargas iniciales y conversión mostrada por Connect | ¿La promesa y compatibilidad están claras? En compra pagada el precio también influye; no atribuir todo a keywords. | Investigar una caída tras un cambio y verificar requisitos/idioma/copy antes de repetirlo. |
| Relación descargas/visitas, si se calcula internamente | Es un ratio propio, no necesariamente la definición de conversión de Apple. Indicar denominador y no mezclar con el panel. | Comparar periodos equivalentes; evitar conclusiones con muestras pequeñas. |

**Secuencia propuesta:**

1. Antes del lanzamiento: guardar este borrador y los campos/imagenes realmente publicados como línea base V1; fecha de salida y precio decididos por el usuario.
2. Primeros 14 días: recoger datos orgánicos sin cambios diarios; revisar errores de metadatos/compatibilidad de inmediato. No existe un objetivo numérico inventado.
3. Primera revisión editorial: **14 días después del lanzamiento efectivo**, no una automatización creada. Si el volumen es insuficiente, ampliar observación hasta 28 días y no declarar ganador.
4. Experimento A (iOS): resultado 3D primero frente a captura LiDAR primero. Hipótesis: un resultado concreto explica mejor la utilidad. Mantener los otros assets, copy y precio iguales; usar Product Page Optimization si es elegible/disponible, o una comparación temporal claramente no causal.
5. Experimento B (Mac): fuentes conservadas frente a controles de reconstrucción como segunda captura. Hipótesis: reducir incertidumbre de flujo aumenta interés en una herramienta local. No variar varios mensajes a la vez.
6. Tras una versión nueva elegible: evaluar una alternativa de subtítulo centrada en caso de uso, recalculando límites y registrando el cambio. Ajustar keywords únicamente por intención relevante y señales disponibles, no por supuestos volúmenes de terceros.
7. Segunda revisión: 28 días después de publicar la variante o al reunir evidencia suficiente; registrar decisión, datos, periodo y factores de confusión. No prometer rankings, ventas o visibilidad garantizada.

Este documento no publica nada, no cambia cuentas/precios/certificados y no autoriza anuncios, contacto a usuarios o nuevas funciones.
