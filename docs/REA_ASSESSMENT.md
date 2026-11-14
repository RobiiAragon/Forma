# Evaluación de REA para Forma

Evaluado el 15 de octubre de 2026 a petición del usuario. Fuente: [morluto/rea](https://github.com/morluto/rea), commit `35e17a717229c1905828c0a0664a1825a985cf28`. Herramienta ejecutada: paquete oficial npm `rea-agents@6.5.0`, licencia MIT, con Node.js 22.23.3 ya disponible en el Mac.

## Utilidad comprobada

REA es una herramienta de inspección e ingeniería inversa, no un motor de fotogrametría, texturizado ni Gaussian Splatting. Se utilizó inicialmente su CLI para inspeccionar estáticamente el paquete de Forma compilado y las rutas de carga de sus bibliotecas, sin ejecutar el binario iOS en el Mac. La investigación de Polycam disponible públicamente se documenta por separado en [POLYCAM_WEB_ANALYSIS.md](POLYCAM_WEB_ANALYSIS.md) y [POLYCAM_WASM_ANALYSIS.md](POLYCAM_WASM_ANALYSIS.md); el resultado de buscar su paquete nativo figura más abajo. No se añadió REA como dependencia a la aplicación ni se contrataron herramientas comerciales.

En la primera auditoría se instalaron los archivos de la CLI en `build/Research/rea-cli`, con scripts de instalación y dependencias opcionales desactivados. En ese momento no se ejecutó `setup`, no se modificó la configuración MCP del usuario y no se instaló Hopper, IDA ni Ghidra. La copia de investigación del repositorio y las evidencias quedan bajo `build/Research`, excluido de Git y del paquete iOS. La preparación posterior de Ghidra se documenta abajo.

La inspección de `Info.plist` confirmó que la compilación 0.3.0 incorpora `UIFileSharingEnabled=true`, `LSSupportsOpeningDocumentsInPlace=true`, iOS mínimo 18 y el permiso de cadencia de pantalla `CADisableMinimumFrameDurationOnPhone=true`. La clave de compartir archivos se había detectado ausente en el artefacto 0.2 mediante `plutil`, a pesar del ajuste del generador de proyecto; se corrigió usando `Config/Forma-Info.plist` como entrada explícita. REA confirmó la corrección, no descubrió por sí solo ese fallo.

El análisis de carga arm64 resolvió la biblioteca interna `Forma.debug.dylib`. Las referencias a bibliotecas de Apple fuera del paquete se informan como indeterminadas: este análisis no evalúa el caché dyld del teléfono ni demuestra disponibilidad, carga observada o ausencia de esas bibliotecas. La compilación y las pruebas físicas aportan evidencia distinta de la inspección estática.

No se obtuvo un binario nativo de Polycam para REA. La comparación de la sala utiliza exclusivamente los archivos de modelos exportados y proporcionados por el usuario: OBJ de Forma y GLB de Polycam. REA no proporciona los algoritmos internos de Polycam ni permite deducirlos a partir de esos modelos.

## Viabilidad de investigar Polycam con REA

Sí puede servir para ingeniería inversa del programa. La [guía de investigación nativa](https://github.com/morluto/rea/blob/6fcfc5b5e0c063300cd5278dd8bad5b1ab1374f6/docs/native-investigation.md) describe inventario de funciones, ensamblador, pseudocódigo y referencias mediante Ghidra, Hopper o IDA. La [guía de aplicaciones Apple](https://github.com/morluto/rea/blob/6fcfc5b5e0c063300cd5278dd8bad5b1ab1374f6/docs/apple-application-analysis.md) permite inventariar un IPA y localizar sus ejecutables, recursos y bibliotecas. Ese inventario no prueba llamadas observadas ni recupera por sí mismo el funcionamiento de una característica.

La comprobación local inicial del 15 de octubre con `rea providers --format json`, usando el paquete 6.5.0, devolvió el siguiente estado **antes de instalar Ghidra y el JDK posterior**. Es un diagnóstico histórico; la sección «Proveedor nativo instalado y probado» registra el estado operativo posterior:

| Componente | Resultado observado |
| --- | --- |
| Inspección estática de paquetes y utilidades nativas de macOS | Disponible |
| Ghidra | No configurado; faltan la instalación seleccionada, `analyzeHeadless` y el descompilador para macOS arm64 |
| Java | Oracle 1.8.0_503, únicamente runtime; no satisface el JDK completo requerido por el proveedor |
| Hopper | Ausente el ejecutable `/Applications/Hopper Disassembler.app/Contents/MacOS/hopper` |
| IDA | Sin registro de proveedor configurado |

La búsqueda acotada en Descargas no encontró archivos `.ipa` o `.app` en su primer nivel, ni nombres que contuvieran Polycam en sus dos primeros niveles. Esto no demuestra que no exista una copia en otro lugar del Mac. Los archivos de la sala disponibles son modelos exportados, no el ejecutable de la aplicación.

Con un paquete disponible, primero se puede inventariar su contenido e inspeccionar su plist y ejecutable. Con Ghidra instalado y configurado conforme a su [guía de instalación](https://github.com/morluto/rea/blob/6fcfc5b5e0c063300cd5278dd8bad5b1ab1374f6/docs/installation.md#ghidra), los pasos posteriores documentados son:

```sh
rea inspect-artifact /ruta/Polycam.ipa --format json
rea inspect /ruta/al/ejecutable/Polycam --provider ghidra --format json
rea search /ruta/al/ejecutable/Polycam --pattern=texture --kind procedures --provider ghidra --format json
rea function /ruta/al/ejecutable/Polycam --procedure=NOMBRE_O_DIRECCION --provider ghidra --format json
rea decompile /ruta/al/ejecutable/Polycam --procedure=NOMBRE_O_DIRECCION --provider ghidra --format json
```

Los nombres y direcciones se eligen del inventario real; buscar `texture` es un ejemplo y un resultado vacío no descarta esa función. Tener un IPA no garantiza pseudocódigo útil, recuperación del código fuente original ni acceso a un algoritmo que se ejecute en un servidor. En esta sesión no se ha descompilado un ejecutable nativo iOS de Polycam ni trazado su proceso en el teléfono; el análisis de su JavaScript y WebAssembly público se documenta por separado en los informes enlazados al comienzo. La CLI se ha usado efectivamente sobre Forma como comprobación inicial. Entonces faltaban el artefacto nativo de Polycam y preparar un proveedor; el segundo requisito se resolvió posteriormente como se documenta a continuación.

## Proveedor nativo instalado y probado

El 15 de octubre el usuario autorizó descargar las herramientas necesarias. Se descargaron los archivos oficiales de [Ghidra 12.1.4](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.1.4_build) y [Eclipse Temurin JDK 25.0.4.1+1 para macOS arm64](https://github.com/adoptium/temurin25-binaries/releases/tag/jdk-25.0.4.1%2B1), y se comprobaron los SHA-256 publicados por sus respectivos proyectos antes de extraerlos:

| Archivo oficial | Bytes | SHA-256 |
| --- | ---: | --- |
| `ghidra_12.1.4_PUBLIC_20260921.zip` | 569.649.598 | `ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db` |
| `OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.4.1_1.tar.gz` | 136.355.078 | `61979887f7506a24a57439ff99adb8b3a7fc89977d9cfe3b8984f58a981b7b9d` |

Se instalaron en `build/Research/ghidra_12.1.4_PUBLIC` y `build/Research/jdk-25.0.4.1+1`. El descompilador macOS arm64 se compiló desde el código incluido en la distribución, usando Xcode y la receta documentada por REA: `make -j4 ghidra_opt ARCH_TYPE='-arch arm64' OSDIR=mac_arm_64`. El ejecutable generado tiene SHA-256 `7434284fc5a6b46b3cb27ef2e8d3c4ea7f801ac1f0cca30e95eb27732c0c62f0` y `file` lo identifica como Mach-O arm64. No se requirieron permisos de administrador, ajustes de seguridad, cambios globales de Java/PATH ni registro MCP.

El script `scripts/setup_rea_native.sh` reproduce descargas, comprobaciones y compilación, y selecciona `GHIDRA_INSTALL_DIR`, `JAVA_HOME` y el proveedor únicamente para el comando invocado. Por ejemplo:

```sh
scripts/setup_rea_native.sh --install-only
scripts/setup_rea_native.sh providers --format json
scripts/setup_rea_native.sh inspect build/device/Build/Products/Debug-iphoneos/Forma.app/Forma --provider ghidra --format json
scripts/setup_rea_native.sh decompile build/device/Build/Products/Debug-iphoneos/Forma.app/Forma --procedure=0x100004000 --provider ghidra --format json
```

`providers` informó Ghidra disponible y todas las comprobaciones específicas del proveedor correctas. El diagnóstico global `doctor` conserva código de salida 1 porque también evalúa otros motores y registros MCP que no se han instalado; no representa un fallo de Ghidra ni obliga a instalarlos.

Los dos comandos de análisis anteriores terminaron con código 0. Ghidra importó el Mach-O arm64 de Forma, identificó 140 procedimientos y 19 segmentos, y devolvió pseudocódigo de `entry` en `0x100004000`. El binario examinado tiene SHA-256 `6bfdc9282fb588c5c648cd96b8038278f8d2e972131d196628217b9e8bc656d7`. Esta prueba comprueba la cadena REA → Ghidra → descompilador nativo. En una compilación Debug este ejecutable contiene el arranque de Xcode y carga `Forma.debug.dylib`; la prueba no supone una auditoría de todo el código de Forma. El pseudocódigo conserva advertencias explícitas sobre saltos indirectos sin resolver y no es el código fuente original.

Las evidencias permanecen en `build/Research/rea-native-installation.json`, `rea-native-providers.json`, `rea-native-doctor.json`, `rea-forma-native-overview.json` y `rea-forma-native-decompile.json`; las respuestas vinculan resultado y hash del sujeto. Con esta instalación el proveedor ya está operativo. Sigue faltando un artefacto nativo de Polycam para analizar su ejecutable; el OBJ y el GLB aportados no lo contienen.

## Búsqueda pública del paquete nativo de Polycam

El 15 de octubre se buscaron descargas públicas sin iniciar sesión, comprar ni instalar aplicaciones. El [catálogo oficial de Apple](https://itunes.apple.com/lookup?bundleId=ai.polycam.polycam) confirmó `ai.polycam.polycam`, identificador `1532482376` y versión `7.0.6`; su respuesta no proporcionó un paquete IPA. Las consultas guardadas de Archive.org y de metadatos de repositorios GitHub no localizaron una copia nativa verificable. Estas búsquedas acotadas no demuestran que no exista en otra fuente.

La [ficha correcta de PGYER](https://www.pgyer.com/ipa/ipa/ai.polycam.polycam) anuncia Polycam Inc. y versión `3.5.23`, pero el enlace público «Download IPA» devuelve 622 bytes de HTML, título `Opening App Store`, que redirigen a la ficha de Apple: no devuelve un ZIP ni un ejecutable. La otra ficha `CS.PolyMoCam` pertenece a otra aplicación. Los catálogos que sólo remiten al App Store y los anuncios de versiones modificadas para eludir pagos no aportaron un original verificable y no se descargaron como binarios.

No se obtuvo un IPA ni se pudo comprobar `cryptid`, firma, bibliotecas o pseudocódigo nativo de Polycam. No se accedió a cuentas, datos personales ni al dispositivo para esta búsqueda; tampoco se retiró cifrado ni se ejecutaron instaladores. Las respuestas de Apple, Archive.org y GitHub, las dos páginas PGYER y su respuesta de descarga se conservan bajo `build/Research/polycam-native-discovery`, con resumen en `findings.json`. La investigación posterior de una alternativa con código público se documenta en [SCANNER_ALTERNATIVE_ANALYSIS.md](SCANNER_ALTERNATIVE_ANALYSIS.md).

## Repetición de la auditoría

Requiere una versión de Node admitida por REA. Los comandos usados, desde la raíz del proyecto, equivalen a:

```sh
npm install --prefix build/Research/rea-cli --ignore-scripts --omit=optional --no-audit --no-fund rea-agents@6.5.0
node build/Research/rea-cli/node_modules/rea-agents/scripts/rea.mjs inspect-plist build/device/Build/Products/Debug-iphoneos/Forma.app --format json
node build/Research/rea-cli/node_modules/rea-agents/scripts/rea.mjs trace-dylib-resolution build/device/Build/Products/Debug-iphoneos/Forma.app --architecture arm64 --format json
```

Ejecutar después de completar la compilación, con el artefacto inmóvil. Las salidas finales se conservan como `build/Research/rea-forma-plist.json` y `build/Research/rea-forma-dylibs.json`; incluyen sujeto, hash, operación y limitaciones. No constituyen una comparación de calidad 3D ni una certificación del programa.

## Decisión

Usar REA como herramienta local auxiliar de auditoría. Mantener las mejoras de Forma basadas en sus datos RGB-D, algoritmos propios, motor abierto incluido y mediciones reproducibles. Las conclusiones sobre calidad visual entre aplicaciones deben venir de los modelos y de nuevas pruebas controladas, no de las capacidades anunciadas por una herramienta de análisis.
