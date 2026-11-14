# Gaussian: A/B de inicialización fotográfica, preparado y congelado

Estado: **preparación CPU completa; ningún entrenamiento ni evaluador nativo ejecutado**. Este trabajo queda congelado mientras se prioriza una mejora visible de la fotogrametría. No hay cola automática ni orden pendiente para el worker real.

El plan está en `build/Research/GaussianColorSeedAB/pilot-3000-horizon30000-v092/plan.json`. Contiene dos datasets independientes, copiados mediante clones APFS cuando están disponibles y con inodos distintos. Todos sus archivos coinciden con las fuentes originales salvo las columnas RGB de `points3D.txt` del brazo fotográfico. Se conservan los 199,868 puntos y las 566 cámaras/fotos, posiciones, K, orden y campos ajenos a RGB. El seed completo asignó color observado a 90,492 puntos; el resto permanece gris. [Preparación y límites del seed](../build/Research/GaussianColorSeed/README.md).

## Variable y calendario predeclarados

El brazo A comienza en gris 128 y el B utiliza la semilla fotográfica completa. Ambos comienzan desde cero, sin cargar checkpoint. Se usan el mismo archivo nativo, shader, imágenes, normalización, defaults y overrides de `forma_gaussian_create`: resolución 1, sin pirámide, SH3, horizonte de LR 30,000 y refinamiento disponible hasta 30,000. La única diferencia de entrada prevista es RGB.

El piloto propuesto observa pasos **0, 1,000 y 3,000** por brazo. Ese punto final permite una comparación temprana con SH3 activo y aproximadamente 5.3 ciclos nominales sobre 566 observaciones; no demuestra convergencia. `--steps` permite cambiar el punto de observación al preparar **otro** plan, hasta su horizonte predeclarado. No modifica límites del producto ni reduce puntos/fotos/resolución. El harness separa este corte del horizonte; configurar el worker de producción a 3,000 cambiaría LR/refinamiento y sería otro experimento.

El código nativo congelado usa seed 42 para quaternions y barajado de cámaras; los splits usan el paso como seed. Las cámaras entran por nombre de archivo, no por fecha, y el vector se vuelve a barajar al agotar cada ciclo. Se verificó por inspección de las fuentes identificadas en el manifest. El harness futuro guardará la secuencia esperada de ese mismo algoritmo/libc++; no se presenta como una traza instrumentada ya observada dentro del Trainer.

## Medición y controles

Se predeclaran las fotos cronológicas 0/283/565 por sus nombres e IDs exactos (`C5E81472…`, `D57CBC28…`, `AF41061B…`); el harness resuelve sus índices nativos por filename. En cada etapa guardará checkpoint, PLY SH3 completo, imágenes de las tres vistas y L1/RMSE/PSNR/SSIM a resolución nativa. Validará los 18 tensores, segundos momentos Adam no negativos y todos los valores exportados. La comparación inicial exige parámetros, optimizador y LR idénticos salvo el tensor DC de color.

**No hay vistas realmente reservadas en este piloto.** Entrenan las 566 y el seed ya consideró sus imágenes. Activar `evalMode` sobre esa semilla no eliminaría la fuga de información. Una prueba reservada válida requeriría un experimento separado y un seed recalculado sólo desde las fotos de entrenamiento. Las métricas actuales propuestas serán descriptivas de vistas observadas; no acreditarán superioridad frente a Polycam. Un único par tampoco da significancia estadística, y el orden gris→RGB deja caché/temperatura como posibles factores en el tiempo medido.

## Runtime y aislamiento

Se congelaron helper, shader, archivo estático, manifest, fuentes/headers y harness compilado desde el runtime 0.9.2 actual. Archivo nativo SHA256: `6dd1170d8a3c1146bc079e4b475fd320cc321e7a8f949bb7e0147aa92b2902c3`; shader: `794a2af3f3ab86bad25bfe2163c4b00fd47e0bfb87143deb8e534a025ba4a532`; fingerprint de fuentes: `b258e8e03964b8b45a9b3e2b49aef6b911f1b91608848307bf37fadd5b8c4962`. La preparación sólo compiló/enlazó; no inició ese binario ni creó un modelo Metal.

`Tools/prepare_gaussian_color_seed_ab.py` ofrece `--dry-run`, `--prepare`, `--check-ready` y ejecución futura explícita `--run`. Preparar con CPU no agenda ejecución. La ejecución y cada etapa nativa rechazan workers/evaluadores reconocidos activos; no esperan, envían órdenes, pausan, cancelan ni reanudan trabajos ajenos. Una detección durante el experimento detiene únicamente el experimento propio. Esta observación de procesos no es una reserva atómica del GPU a nivel de sistema; deben evitarse nuevos lanzamientos externos durante un ensayo futuro.

La guarda real rechazó el PID 51835 sin iniciar ningún proceso nativo. Las regresiones CPU aprobaron rechazo, copias independientes, comparación inicial de tensores/rechazo de una modificación geométrica y ausencia de carga de checkpoint. Evidencias: `build/Research/GaussianColorSeedAB/self-test.log`, `active-worker-guard.log`, `prepare.log` y los SHA dentro del plan. Los datos originales y ambos datasets preparados se volvieron a verificar íntegros. No se modificó el exportador COLMAP ni el producto.

Cuando se retome este trabajo y no haya workers activos, debe invocarse la **copia congelada del script** dentro del directorio del plan; un script distinto es rechazado. No se ha invocado `--run`. Quedan pendientes la ejecución nativa, validación de las etapas y cualquier conclusión visual. El siguiente objetivo activo es la mejora visible del resultado fotogramétrico, no ampliar este A/B.
