# 📸 Forma - Estudio 3D Local
*Una aplicación para la captura, procesamiento y análisis de entornos y objetos mediante fotogrametría (LiDAR/RGB-D) y Gaussian Splatting, todo realizado de forma local.*

**Forma es una aplicación nativa para iOS/iPadOS y macOS. Su principal característica es que todo el procesamiento se realiza en el dispositivo local sin depender de servicios en la nube, suscripciones o cuotas comerciales.**

---

## ✨ Características Principales
*   **Reconstrucción Híbrida:** Combina datos de LiDAR/ARKit (Malla) con fotografías multivista para crear modelos 3D.
*   **Gaussian Splatting:** Permite entrenar y visualizar nubes de Gaussianas 3D de alta calidad (basado en el motor `msplat`).
*   **Procesamiento Local:** Desde la captura hasta la exportación de mallas (PLY) y modelos USDZ, el trabajo se mantiene íntegramente en el dispositivo.
*   **Gestión de Estado:** Implementa pausas, reanudaciones y *checkpoints* automáticos para manejar trabajos largos sin interrupción.

---

## 🚀 Primeros Pasos (Getting Started)
**Requisitos Mínimos:**
*   Xcode 27 o posterior.
*   iOS 18+ y hardware compatible para la captura nativa (LiDAR, ARKit).
*   Node/Python 3.x y CMake 3.21+ para la configuración de dependencias del motor.

**Instalación y Compilación:**
1.  Abra `Forma.xcodeproj` en Xcode.
2.  Seleccione el esquema **Forma** y el destino deseado (ej: iPhone 18 Pro).
3.  Si hay faltantes de dependencias del motor, ejecute primero:
    ```sh
    bash scripts/build_msplat.sh
    python3 scripts/generate_project.py
    ```
4.  Pulsar "Run" en Xcode.

> **Nota:** La aplicación usa la firma de desarrollo local; asegúrese de que su cuenta esté configurada en Xcode > Signing & Capabilities.

---

## ⚙️ Flujo de Trabajo (Workflow)
**1. Captura:**
*   **Espacios/Salas:** Utilice el modo LiDAR para crear una malla inicial y adjuntar fotografías con poses calibradas.
*   **Objetos:** Use Object Capture para escanear objetos, generando un USDZ texturizado.
*   **Gaussian 3D:** Inicie el entrenamiento del Gaussian Splatting a partir de una captura calibrada. Es posible editar los pasos y el factor de reducción en la app.

**2. Procesamiento:**
*   El motor optimiza las fotografías y fusiona la geometría de forma conservadora. La corrección opcional de planos reduce ruido solo en regiones que pasan comprobaciones conservadoras; conserva bordes y fuentes. La captura puede activar la asistencia nativa de planos de ARKit. No se añade detalle por subdivisión.

**3. Exportación:**
*   La aplicación permite exportar la malla final en formatos como **PLY** (geometría optimizada) o el modelo completo **USDZ**.

---

## 🔬 Notas Técnicas (Para Desarrolladores)
*   **Motor Nativo:** El motor de reconstrucción utiliza una adaptación local de `msplat-ios` (`Vendor/Msplat`).
*   **Limitaciones:** Los resultados no garantizan exactitud milimétrica certificada. Las áreas sin observación, superficies reflectantes o el movimiento constante pueden producir artefactos.
*   **Documentación Detallada:** Los análisis exhaustivos de pruebas, comparaciones y auditorías arquitectónicas se encuentran en el directorio [docs/](docs/). Consulte `docs/VALIDATION_PROTOCOL.md` para conocer los criterios de verificación detallados.
*   **Archivos del Proyecto:** Mantenemos múltiples targets en Xcode (`Mac`, `FormaLiveActivity`) para soportar diferentes plataformas.

---
**iPhone actualizado:** 0.9.5 (build 22), instalación y lanzamiento físicos verificados. **Mac:** última entrega instalada build 20; candidato 0.9.5 compilado, sin actualizar en esta sesión. Controles por motor, corrección opcional de planos y vista de geometría sin mapas de relieve.

[Auditoría y evidencia de calidad, 18 de octubre](docs/GEOMETRY_QUALITY_20261018.txt).

Mapa de módulos y extensión: [MODULE_MAP.txt](docs/MODULE_MAP.txt). La distribución prevista es pago único al descargar de App Store, sin compras internas; precio y publicación quedan pendientes de configuración por el usuario.

[Revisión acotada de arquitectura e interfaz](docs/HIG_ARCHITECTURE_REVIEW_20261018.txt).

[ASO y propuestas de ficha App Store](ASO.md) · es-MX/en-US, iPhone/iPad y Mac; metadatos propuestos, pendientes de publicación.

Revisión de rendimiento **0.9.5 (22)** instalada en iPhone; las mediciones de etapas siguen siendo de Mac. [Mediciones, corrección y límites](PERFORMANCE.md).
