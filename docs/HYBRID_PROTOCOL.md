# Forma: protocolo local híbrido 0.9.1

La recepción de Mac ofrece transferencia de fuentes, consulta de estado, comandos y descarga de derivados sobre el mismo canal emparejado. Wi-Fi usa una conexión TCP a la recepción Bonjour. USB conserva la dirección lógica cliente/servidor: iPhone escucha y Mac conecta a través del reenvío USB. No se expone HTTP ni un endpoint sin emparejar.

Cada conexión negocia un reto de 32 bytes y autentica ambas direcciones con HMAC-SHA256 de la clave efímera de emparejamiento. HKDF deriva la clave AES-GCM; mensajes cifrados usan dirección y contador secuencial como AAD. Cada archivo se transmite en bloques de hasta 1 MiB con backpressure. El tamaño del modelo no determina una reserva `Data` del modelo completo.

## Intención remota

`RemoteJobStatus` agrega `controlRevision` y `supportedCommands` opcionales, compatibles con el estado 0.9. El cliente habilita comandos sólo a partir de capacidades y revisión recibidas. `RemoteJobCommand` contiene UUID de petición, UUID de trabajo, acción `pause/resume/cancel/export` y revisión esperada. `command-query` / `command-response` versión 1 llevan el comando y `RemoteCommandReply`.

El transporte comprueba los UUID y el estado de la respuesta. La idempotencia durable y la comparación de revisión pertenecen al proveedor de Store: éste prepara el recibo antes del efecto y conserva resultados por UUID. Si un proceso muere entre preparar y confirmar, el proveedor debe responder `uncertain` y evitar aplicar el mismo efecto otra vez. Una respuesta `accepted` confirma el despacho, no la finalización del worker. Reutilizar UUID con contenido distinto se rechaza.

## Descarga verificada

`ResultProvider(jobID)` devuelve `ResultSource(descriptor,directory)` sólo dentro del servidor. Su directorio contiene derivados publicados, por ejemplo `modelo/` y `malla.json`; se excluyen dataset RGB-D, checkpoints y fotos originales. Las rutas absolutas del servidor nunca forman parte del descriptor.

`ResultDescriptor` identifica jobID/resultID y guarda nombre, modo, duración, nota, estadísticas y rutas relativas opcionales de modelo, paquete, malla y Gaussian. La ruta Gaussian es relativa al paquete, como en ScanStore. Las demás son relativas al directorio final descargado. El transporte genera `resultado.json` canónico, con claves JSON ordenadas, y enumera sólo el paquete y archivos referenciados.

`result-query` versión 2 solicita el trabajo. El servidor responde un `result-manifest` y entradas `manifest-file`; la identidad es SHA-256 del inventario canónico ordenado, incluyendo el descriptor. Un UUID derivado del digest nombra el bundle; siempre se comprueba también el digest completo. El cliente puede fijar `expectedManifestSHA256` para rechazar una publicación distinta.

El cliente conserva `.result-resume-UUID` con `.result-transfer.json`. Para cada archivo propone offset y SHA-256 del prefijo local. El servidor calcula el mismo prefijo y elige `append-file` o `restart-file`; los archivos correctos completos no repiten sus bytes. Un parcial corrupto reinicia sólo ese archivo. Cada archivo final se verifica con SHA-256 antes de reconocerlo.

Después de `done`, se revalida el inventario, descriptor y todos los archivos, y una operación de cambio de nombre publica `Result-UUID` de forma atómica. Un ACK perdido no elimina ese commit: la siguiente consulta verifica el bundle y responde `committed` sin enviar el modelo otra vez. Ninguna interrupción elimina el parcial ni altera las fuentes del servidor.

`loadDownloadedResult(from:)` permite recuperar el bundle sin red y `verifyDownloadedResult(_:)` vuelve a comprobar su identidad antes de importar. Ambas rechazan enlaces simbólicos, traversal, NUL, rutas reservadas, archivos ajenos al inventario, contenido SHA distinto y descriptor no canónico. No hay cuota de archivos, modelos, iteraciones o bytes; errores reales de sistema/almacenamiento se conservan como errores recuperables.

## Evidencia reproducible

- `Tools/verify_hybrid_processing.sh`: autenticación, configuración SHA, estado TCP/USB y validación del ABI.
- `Tools/verify_hybrid_resume.sh`: carga v1/v2, desconexión, prefijo corrupto, ACK perdido y fuentes intactas.
- `Tools/verify_hybrid_results.sh`: comandos con revisión y respuesta perdida, descarga interrumpida, reanudación, retry cero bytes, cambio de manifiesto, symlinks/traversal, recuperación offline, tamper y USB inverso.

Estos harness usan TCP real, directorios temporales aislados y los servicios de producción. No prueban el puente USB físico ni implican haber comparado la calidad visual con Polycam.
