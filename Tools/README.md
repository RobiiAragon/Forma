# Reconstrucción opcional en Mac

`FormaReconstruct.swift` procesa las fotografías originales capturadas con Forma mediante `PhotogrammetrySession` de Apple. Todo ocurre localmente, sin servidor, cuenta, dependencias de terceros ni cuotas de la herramienta. Requiere un Mac compatible con esa API, macOS 13 o posterior y Xcode para compilar. El propio programa comprueba el soporte del Mac antes de iniciar una reconstrucción.

En la raíz de este proyecto:

```sh
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macos13.0" -framework RealityKit Tools/FormaReconstruct.swift -o Tools/forma-reconstruct
Tools/forma-reconstruct --help
```

Guarda un objeto en Forma y comparte el ZIP de fotografías originales que conserva la biblioteca. Transfiérelo al Mac y descomprímelo con Finder. Usa como entrada la carpeta que contiene las fotografías; conserva sus nombres, archivos auxiliares y estructura. No uses el USDZ generado en el iPhone como entrada.

```sh
Tools/forma-reconstruct "/ruta/a/Originales" "/ruta/a/Objeto-full.usdz" --detail full
```

Los niveles admitidos son `reduced`, `medium`, `full` y `raw`; el predeterminado es `reduced`. macOS admite niveles que la API de iOS no expone más allá de `.reduced`. Solicitar mayor detalle puede aprovechar mejor un conjunto de fotos, pero también requiere más recursos y no garantiza una reconstrucción mejor. Las fotos borrosas, zonas no observadas o superficies difíciles siguen limitando el resultado. El motor puede omitir o reducir imágenes según los recursos del Mac; se informa en la terminal y las originales se conservan.

Apple destina `raw` a edición posterior en software 3D; no es un modelo ligero adecuado para una escena AR en el iPhone. Consulta los [niveles de detalle documentados por Apple](https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail).

La salida debe ser un archivo `.usdz` fuera de la carpeta de originales y su carpeta de destino debe existir. Un destino existente se rechaza, a menos que se añada `--overwrite` explícitamente:

```sh
Tools/forma-reconstruct "/ruta/a/Originales" "/ruta/a/Objeto-full.usdz" --detail full --overwrite
```

La reconstrucción se escribe primero en un directorio temporal junto al destino. El modelo anterior solo se reemplaza al completar el proceso; ante un fallo o Control-C se conservan las fotografías y no se publica un resultado incompleto. La herramienta muestra progreso y errores reales. Después de terminar, abre el USDZ y compara su escala, geometría y texturas; consulta el [protocolo de validación](../docs/VALIDATION_PROTOCOL.md).

La verificación inicial de esta herramienta incluye compilación, `--help` y ejecución sin argumentos. No demuestra la calidad de un conjunto de imágenes ni sustituye una reconstrucción de prueba autorizada.

Referencia primaria: [PhotogrammetrySession de Apple](https://developer.apple.com/documentation/realitykit/photogrammetrysession). Los niveles y su disponibilidad se contrastaron además con la interfaz del SDK macOS 27 instalado.
