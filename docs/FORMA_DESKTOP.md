# Forma Desktop 0.6

Aplicación nativa macOS, procesamiento local y almacenamiento propiedad del usuario. Sin servicios de pago, suscripciones, cuota de fotos, resolución impuesta por licencia ni límite de capturas. RAM, almacenamiento, GPU y capacidades del motor de Apple siguen siendo recursos físicos reales.

La versión 0.6 incorpora [restauración de textura con IA local](LOCAL_AI.md), el visor integrado para USDZ Raw y [correcciones de importación, zoom y uso de texturas](DESKTOP_VIEWER_QA.md). La IA usa Real-ESRGAN con Core ML, guarda otra captura y conserva la de origen. Este modelo requiere macOS 15 o posterior; el resto de la app conserva macOS 14 como mínimo.

## Compilar y abrir

```sh
FORMA_DEVELOPMENT_TEAM=9X76Y99YGD python3 scripts/generate_project.py
xcodebuild -project Forma.xcodeproj -scheme FormaDesktop -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/mac build
open build/mac/Build/Products/Release/FormaDesktop.app
```

Usar Release para comparar tiempos: compila Swift con `-O`. El target iOS y sus tests se conservan. macOS mínimo 14; la compatibilidad de reconstrucción fotográfica se comprueba con `PhotogrammetrySession.isSupported`.

## iPhone → Mac

1. Mac: activar **Recibir desde iPhone**. Se genera una clave aleatoria de sesión de 128 bits, copiable como 32 caracteres hexadecimales. El usuario decide cuándo abrir/cerrar la recepción.
2. iPhone: elegir **Híbrido**, el Mac descubierto y pegar su clave. Wi-Fi es la opción inicial. La captura conserva primero su dataset RGB-D y su malla originales en el teléfono; posteriormente envía esos archivos al Mac.
3. Mac: solo publica y encola un paquete después de recibir y verificar todos los archivos. Procesa una copia de trabajo, conserva las fuentes recibidas y guarda otro resultado con exportaciones nativas.

USB-C usa exactamente el mismo protocolo autenticado/cifrado. Requiere un iPhone emparejado con este Mac y `iproxy` gratuito de `libusbmuxd` (`brew install libusbmuxd`). Seleccionar USB en el iPhone para que espere al Mac; en Mac pulsar **Conectar por USB-C**. Forma Desktop ejecuta `iproxy -l -s 127.0.0.1 49232:49231` y conecta solo a localhost. En instalaciones con varios dispositivos la selección explícita de UDID aún no está expuesta en la UI. Wi-Fi no necesita este helper.

La conexión usa reto aleatorio, HMAC-SHA256 por rol, clave derivada por HKDF y registros AES-GCM con secuencia autenticada. Los archivos viajan por bloques de 1 MiB con contrapresión; esa granularidad no limita el tamaño del dataset. Cada archivo incluye SHA-256 y longitud. Rutas inseguras, duplicadas o enlaces simbólicos se rechazan. Una conexión cancelada o inválida elimina su staging y no publica un trabajo parcial. La confirmación al emisor ocurre después del commit del paquete completo. La versión actual transfiere después de capturar; no transmite directamente el sensor en tiempo real ni devuelve automáticamente el modelo terminado al teléfono.

## Importar y procesar

**Importar carpeta** acepta un paquete de Forma con `fuentes/dataset.json` y una malla original, la carpeta `fuentes` con su malla original, o un paquete recibido con `dataset/dataset.json` y `malla-original.json`. Importa una copia a Application Support; no modifica la carpeta elegida. La cola y las fuentes viven en `~/Library/Application Support/FormaDesktop`.

El pipeline compartido trabaja fuera del hilo principal. Pausar solicita un checkpoint y solo muestra **Pausado** cuando el worker lo reconoce. Reanudar conserva el trabajo en memoria. Durante el guardado, los botones operan sobre el control real de copia, hashing y ZIP64 del `ScanStore`; cancelarlo conserva el resultado y las fuentes para reintentar. La actividad del sistema impide suspensión durante trabajo activo y se libera al confirmar una pausa. Cerrar la aplicación interrumpe la memoria de trabajo: los trabajos sin terminar se pueden reiniciar desde las fuentes; no se presenta como continuación exacta tras relanzar.

## Visor y exportación

El visor abre inicialmente la geometría nativa con caras traseras ocultas. **Textura adaptativa** crea una copia exclusivamente visual, con presupuesto derivado de la memoria GPU, miniaturas procesadas una imagen a la vez y los mismos OBJ/MTL/UV. **Textura original** es explícita y comprueba recursos antes de cargar. Esta protección de memoria del visor no cambia los modelos, fotos, atlas ni exportaciones nativas. Las texturas del visor son unlit para evitar alterar su color con luces artificiales.

El objetivo 30/60/120 FPS del visor se ajusta a la pantalla detectada. **Render observado** se calcula con callbacks de SceneKit durante interacción; muestra `— · reposo` cuando no hay interacción reciente. Ese valor no es la cadencia de captura de ARKit ni indica resolución, precisión o detalle geométrico.

## Reconstrucción fotográfica opcional

La opción Mac Full/Raw crea un resultado independiente con el motor local de Apple, sensibilidad alta, máscara de objeto desactivada y, desde macOS 15, sin recorte por caja de objeto. Prepara exclusivamente los frames calibrados del manifiesto, ordenados por timestamp e ID y con nombres numerados para `sampleOrdering.sequential`. No enumera indiscriminadamente `images`: ignora archivos ajenos al manifiesto. Usa clones APFS con inodos independientes o copias por bloques sin cambiar los bytes originales. El mapa `input-order.json` permite auditar el orden.

Interrumpir esta operación cancela la sesión de Apple; no finge pausa cooperativa. Conserva fuentes y checkpoints disponibles y los ofrece al reintentar, sin prometer qué trabajo reutilizará Apple. Las fotos omitidas y la reducción automática que informe el motor se muestran. Forma no impone una cuota; el motor de Apple puede aplicar sus propias restricciones. Un resultado fotográfico no tiene escala métrica validada contra LiDAR, no fusiona automáticamente la malla LiDAR y no demuestra por sí mismo mayor precisión. Su USDZ se abre por decisión del usuario mediante Finder/Quick Look para evitar cargar recursos grandes automáticamente.

## Verificación ejecutada

- Release macOS arm64: `BUILD SUCCEEDED`, registro `/tmp/forma-desktop-release.log`.
- `Tools/verify_hybrid_transfer.swift`: cinco comprobaciones correctas: transmisión 8 MiB+33 bytes y malla exactos; rechazo de clave incorrecta; cancelación durante archivo y limpieza; dirección Mac-listener/teléfono-client; fuentes inalteradas. Son pruebas TCP loopback reales del protocolo en ambas direcciones, no validación física de radio Wi-Fi, Bonjour o usbmux.
- `Tools/verify_photogrammetry_input.swift`: cuatro comprobaciones correctas: solo frames del manifiesto y orden temporal a pesar de UUID inversos; bytes exactos e independencia al escribir en una copia; cancelación conserva input anterior y elimina staging; rechazo de frame simbólico/externo. No ejecuta ni evalúa la calidad del motor de reconstrucción.

### Transporte en el iPhone físico y esta Mac

El 15 de octubre de 2026, `HybridPhysicalTransportTests.testOptInPhysicalWiFiThenUSBWithLocalFixture` terminó con **1 test correcto, 0 fallos y 0 omitidos, en 10.952 segundos**, en el iPhone físico con iOS 27.0.1. El harness Mac terminó con código 0. Se enviaron **8,388,641 bytes de fixture por cada transporte**, una malla pequeña y metadatos de prueba, sin enviar ninguna captura real. Ambos paquetes quedaron publicados después de verificar su integridad; el teléfono confirmó `WIFI_ACK`, `USB_ACK` y `ORIGINALS_UNCHANGED`.

- **Bonjour/Wi-Fi:** el descubrimiento exigió interfaz `.wifi`; el endpoint usado por `HybridTransfer.send` quedó ligado explícitamente a **en0**. Una conexión probe al mismo endpoint informó `NWPath.usesInterfaceType(.wifi) == true`. La observación de NWPath pertenece a esa probe: el API compartido encapsula la conexión del payload y no expone su NWPath al test. Esta distinción queda guardada en la evidencia.
- **USB-C:** el Mac usó `iproxy -l -s 127.0.0.1 -u UDID 49432:49431`, limitado al dispositivo USB local elegido. El iPhone esperó en el puerto de prueba y el Mac recibió por el protocolo real de `HybridTransfer`.
- SHA-256 del archivo fixture, idéntico en ambos paquetes: `00c1d69d332330b4f38979ad1d7fb8da77b9d0ab971289a03923b6477486cc7a`.
- SHA-256 de la malla fuente, malla nativa recibida y su representación canónica, idéntico en ambos caminos: `1687e9b844404d5dffecf5bbc78c4d3d8fcff6f00971f8fcfe84a7cc0f1b51db`.

Evidencias: `build/Validation/HybridHardwarePhysicalFinal/hardware-report.json`, `build/Validation/HybridHardwarePhysicalFinal/HardwareFixture.xcresult`, `/tmp/forma-hardware-physical-tests.log` y `/tmp/forma-hardware-physical-harness.log`. Sesión: `65BC2ED0-0CA3-4CA1-8337-D918E1FC517D`. El informe público excluye la clave de emparejamiento.

Esta validación demuestra el transporte del fixture entre ambos equipos y la conservación de sus bytes. **El envío completo de la sala mediante Híbrido y el recorrido de la UI siguen pendientes de validación.** Tampoco mide calidad de reconstrucción ni velocidad de un dataset de varios GB.

### Repetir la prueba física de forma explícita

El caso se omite por defecto. Para habilitarlo, el harness genera una clave efímera y un `xctestrun` privado con las variables de opt-in; limita la ejecución al único método físico. Si no encuentra su servicio Wi-Fi Bonjour dentro de 30 segundos, el caso se omite sin enviar archivos. La probe tiene plazo de 10 segundos y cada transporte de 90 segundos, con cancelación de las conexiones. La carpeta de salida debe ser nueva en cada sesión.

Primero compilar el bundle de tests sin ejecutarlo, usando el UDID elegido de `xcrun devicectl list devices`:

```sh
export FORMA_QA_DEVICE="PEGA_AQUI_EL_UDID"
umask 077
xcodebuild -project Forma.xcodeproj -scheme Forma -configuration Debug \
  -destination "id=$FORMA_QA_DEVICE" -derivedDataPath build/device-hardware-qa \
  -only-testing:FormaTests/HybridPhysicalTransportTests \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  SWIFT_OPTIMIZATION_LEVEL=-O ENABLE_TESTABILITY=YES build-for-testing
```

Iniciar el harness local y mantenerlo abierto:

```sh
umask 077
Tools/verify_hybrid_hardware.sh --device "$FORMA_QA_DEVICE" \
  --xctestrun build/device-hardware-qa/Build/Products/Forma_iphoneos27.0-arm64.xctestrun \
  --output build/Validation/HybridHardwareNuevaSesion
```

Esperar `HARDWARE_QA_READY` y ejecutar en otra terminal el comando `xcodebuild test-without-building` que imprime el harness. Ese comando apunta al `HardwareFixture.xctestrun` derivado y al dispositivo elegido. Mantener el iPhone desbloqueado y atender manualmente el permiso de Red local si aparece. El harness no instala ni inicia apps por sí mismo; Xcode ejecuta el host de pruebas con biblioteca aislada. No publicar `session-private.json` ni el `xctestrun` derivado: contienen la clave efímera y se guardan con permisos `0600`. Los fixtures y los logs deben permanecer en la carpeta privada de la sesión.

La comparación de calidad con Polycam y los tiempos de la sala real se deben medir usando los mismos originales. Compilar o completar las pruebas de transporte no demuestra superioridad visual.
