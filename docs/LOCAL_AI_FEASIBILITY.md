# IA local en Forma: inventario y viabilidad

Revisión del 15 de octubre de 2026. **Hay generadores 3D instalados en el Mac, pero sus pesos no constituyen un motor nativo para Forma.** La primera integración con valor directo para capturas reales es restaurar fotografías y comprobar su coherencia entre vistas; la generación 3D completa necesita otro trabajo de ingeniería. Esta investigación no ejecutó modelos, scripts internos de Comfy ni descargas de pesos, y no modificó código de Forma.

## Lo instalado

Comfy Desktop está fuera de Pinokio. El código reside en `~/ComfyUI-Installs/Comfy/ComfyUI` y los pesos en `~/ComfyUI-Shared/models`. El código declara **0.38.2**, HEAD `daeb5e53681e2b10a3f0727d9ec5bc90784bee10`; el manifiesto base 0.34 es anterior. Los registros identifican Python 3.13.12, PyTorch 2.12.1 y dispositivo **MPS**. Sólo hay ejemplos en `custom_nodes`: los nodos de TRELLIS/Pixal están en el core.

Se leyeron cabeceras Safetensors y tamaños, sin cargar tensores. Los límites del último tensor coinciden con el tamaño de cada archivo. El inventario suma **10 archivos y 31,335,756,152 bytes**; eso es almacenamiento, no una medición de RAM necesaria.

| Archivo bajo `models/` | Bytes | Tipos almacenados / función |
| --- | ---: | --- |
| `diffusion_models/pixal3d_int8_convrot.safetensors` | 5,584,555,824 | I8/U8/BF16/F32; generador 3D |
| `diffusion_models/trellis_2_int8_convrot.safetensors` | 5,253,048,192 | I8/U8/BF16/F32; generador 3D |
| `vae/trellis_2_shape_vae_bf16.safetensors` | 1,095,844,024 | BF16; decodificador geométrico |
| `vae/trellis_2_texture_vae_bf16.safetensors` | 948,461,364 | BF16; decodificador de apariencia |
| `clip_vision/dino_v3_L_naf_fp32.safetensors` | 1,215,214,176 | F32; condicionamiento visual |
| `geometry_estimation/moge_2_vitl_normal_fp16.safetensors` | 661,859,924 | F16; geometría monocular/normales |
| `background_removal/birefnet.safetensors` | 444,473,596 | F16/I64; máscara de fondo |
| `diffusion_models/flux-2-klein-4b.safetensors` | 7,751,105,712 | BF16; generación de imagen |
| `text_encoders/qwen_3_4b.safetensors` | 8,044,982,048 | BF16; codificador de texto |
| `vae/flux2-vae.safetensors` | 336,211,292 | F32/I64; decodificador de imagen |

Los cuatro workflows guardados incluyen texto→imagen, imagen→3D, texto→3D y Pixal3D. Texto→3D genera primero una imagen con FLUX/Qwen. El flujo imagen→3D referencia una etapa de 1024 y textura de 2048; no son límites universales del modelo ni una prueba de calidad. No hay pesos dedicados en `upscale_models` o `latent_upscale_models`, ni Hunyuan/Tripo o paquetes Core ML/ONNX en las raíces revisadas. Los artefactos nuevos de restauración en `build/Research/LocalAI` pertenecen a otra implementación y no se cuentan como pesos preexistentes de Comfy.

[Inventario detallado, sin prompts, imágenes personales ni credenciales](../build/Research/LocalAI/comfy-installed-inventory.json) · [Fuentes primarias consultadas](../build/Research/LocalAI/primary-sources.json).

## Licencias comprobadas y procedencia pendiente

El `LICENSE` del **código Comfy instalado es GPLv3**. Las licencias de sus pesos son distintas: las tarjetas de [Pixal3D convertido](https://huggingface.co/Comfy-Org/Pixal3D), [TRELLIS convertido](https://huggingface.co/Comfy-Org/TRELLIS.2) y [TRELLIS.2-4B original](https://huggingface.co/microsoft/TRELLIS.2-4B) declaran MIT. [Tencent publica MIT para Pixal3D](https://huggingface.co/TencentARC/Pixal3D/blob/main/LICENSE) y su [NOTICE](https://github.com/TencentARC/Pixal3D/blob/master/NOTICE) conserva términos separados para terceros.

El encoder instalado es **DINOv3 + NAF**: [Meta identifica DINOv3 con su licencia propia y acceso condicionado](https://huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m), cuyo [texto](https://huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m/blob/main/LICENSE.md) difiere de MIT; el [código NAF declara Apache-2.0](https://github.com/valeoai/NAF/blob/main/LICENSE). El NOTICE de Pixal menciona DINOv2: no basta para certificar la cadena de ese encoder combinado. La [tarjeta original de Tencent](https://huggingface.co/TencentARC/Pixal3D/raw/main/README.md) también contiene `extra_gated_eu_disallowed: true`; se registra como metadato de acceso, sin inferir una prohibición universal para los pesos derivados.

[MoGe2](https://huggingface.co/Ruicheng/moge-2-vitl) y [BiRefNet](https://huggingface.co/ZhengPeng7/BiRefNet) declaran MIT; [FLUX.2 Klein **4B**](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B) y [Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B) declaran Apache-2.0. No se extiende esta identificación a otras variantes. Faltan tarjetas/licencias junto a los archivos locales y no se comparó su SHA completo con el origen: la correspondencia de nombres y URLs del workflow no certifica por sí sola la identidad exacta ni la redistribución de toda la cadena.

## Independencia de Comfy y coste técnico

La ruta Mac observada usa **Torch/MPS con adaptaciones locales**, no Core ML. Por ejemplo, `comfy/ldm/trellis2/flexgemm.py:7` y `:28` hacen búsquedas enteras de voxeles en CPU para evitar pérdida de precisión en MPS; las características permanecen en MPS. El proceso incluye estructura dispersa, forma, textura, muestreo, extracción de malla y baking. Los encabezados INT8 contienen también BF16, F32 y datos auxiliares: no son una red Core ML intercambiable.

La referencia oficial [TRELLIS](https://github.com/microsoft/TRELLIS.2#installation) se declara probada en Linux con NVIDIA, al menos 24 GB y CUDA. [Pixal3D](https://github.com/TencentARC/Pixal3D/blob/master/README.md) añade dependencias CUDA y especifica pesos **multivista separados**; los archivos locales inventariados son los de una vista. Estos requisitos de la implementación original no prueban que MPS sea imposible: explican por qué los parches Mac son trabajo adicional. Tampoco permiten extrapolar velocidad o memoria al iPhone.

Un motor final puede ser independiente de Comfy, pero debe implementar sus operaciones y etapas, convertir y comprobar los pesos y conservar los avisos correspondientes. La [conversión oficial de PyTorch a Core ML](https://apple.github.io/coremltools/docs-guides/source/convert-pytorch-workflow.html) parte de un grafo ejecutable y entradas definidas; copiar o renombrar Safetensors no crea ese grafo. No se hizo aquí conversión ni inferencia 3D autónoma.

## Prioridad propuesta para Forma

1. **Restauración fotográfica nativa Core ML**, como derivado opcional que conserva originales, resolución de referencia y procedencia. Ya integrada en iPhone y Mac en Forma 0.6; [implementación](LOCAL_AI.md) y [pruebas reales](LOCAL_AI_VALIDATION.md). La nitidez aparente no certifica detalle real.
2. **Coherencia entre varias fotos** usando calibración, profundidad y visibilidad existentes; rechazar cambios que empeoren reproyección en observaciones reservadas. Mantener la malla y los datos medidos, y validar los derivados antes del atlas. Esto ofrece una comprobación concreta sobre capturas reales.
3. **Generación 3D creativa** como función posterior, con motor autónomo Mac y licencia/procedencia verificadas. Los detalles inferidos deben poder distinguirse de los observados. No se presenta el generador como reparación métrica automática de una sala ni se promete ejecución equivalente en el iPhone.

Pinokio no proporcionó `pterm` por PATH ni rutas derivadas de configuración; el plano local rechazó conexión y el alternativo agotó tiempo. Eso motivó este inventario de archivos de sólo lectura, sin lanzar runtimes. No demuestra que Pinokio esté desinstalado.

## IA para geometría en iPhone y Mac: siguiente motor, aún sin integrar

La restauración actual sólo cambia texturas. `MeshContinuity` realiza uniones geométricas conservadoras mediante reglas; no es un modelo neuronal que reconstruya superficies. Para añadir un refinador compartido entre ambas apps hay candidatos distintos de los generadores creativos de Comfy:

| Candidato verificado en fuentes oficiales | Encaje | Trabajo pendiente |
| --- | --- | --- |
| [Depth Anything V2 Small Core ML de Apple](https://huggingface.co/apple/coreml-depth-anything-v2-small) | Apache-2.0, 24,8 M parámetros, FP16 de 49,8 MB y variante paletizada de 19 MB. Apple publica pruebas en iPhone y Mac. | Su salida es profundidad relativa. Alinear con LiDAR y validar refinamiento multivista; el modelo por sí solo no modifica una malla. No se ha ejecutado en Forma. |
| [PromptDA Small](https://huggingface.co/depth-anything/prompt-depth-anything-vits/blob/main/README.md) | Apache-2.0, 25,1 M parámetros; recibe RGB y profundidad métrica LiDAR. | La [implementación oficial](https://github.com/DepthAnything/PromptDA) usa PyTorch/CUDA. Falta conversión Core ML y prueba de equivalencia, incluida normalización con `torch.quantile`. No se atribuyen a Small los resultados principales de Large. |
| [MoGe-2 Small Normal](https://huggingface.co/Ruicheng/moge-2-vits-normal) | MIT, 35 M parámetros; estima puntos, profundidad, normales y máscara. Es distinto del archivo Large instalado en Comfy. | El [exportador ONNX oficial](https://github.com/microsoft/MoGe/blob/main/docs/onnx.md) cubre `forward`; focal, desplazamiento y reproyección necesitan postproceso. No hay inferencia Core ML propia verificada. |

La primera ruta nativa verificable sería usar el Core ML oficial como prior y mantener las mediciones LiDAR como ancla: conservar la transformación entre rasters, ajustar contra profundidad de alta confianza y reservar observaciones para validar. Se podrían proponer correcciones sólo a vértices existentes, aceptarlas cuando varias vistas reduzcan el error reservado y mantener el original donde falte soporte. Después habría que volver a proyectar las fotografías sobre la malla derivada. La salida monocular no aporta una confianza métrica calibrada; debe estimarse fiabilidad a partir de residuos y acuerdo entre vistas.

Rellenar huecos o producir una superficie más densa necesita además fusión volumétrica/TSDF y extracción de malla, hoy ausentes. Los datos actuales sí conservan profundidad Float32 en metros, confianza UInt8 0–2, intrínsecos, pose y timestamp por fotograma. Las imágenes de alta resolución sin profundidad deben usar su propia pose y no heredar profundidad de otro instante.

Esta segunda revisión fue de viabilidad: no descargó pesos geométricos, convirtió modelos, ejecutó inferencia geométrica ni añadió botones que anuncien una función inexistente. Los tiempos publicados por proveedores no son mediciones de Forma ni garantía para estos dispositivos.
