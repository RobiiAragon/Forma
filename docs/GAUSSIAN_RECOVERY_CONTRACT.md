# Recuperación de Gaussian Splatting

`Core/GaussianRecovery.swift` no ejecuta el motor. Persiste metadatos bajo Documents/FormaTraining/<UUID>/session.json y resuelve el checkpoint como entrenamiento.ckpt en esa misma carpeta.

- `GaussianRecovery.create(datasetURL:iterations:downscale:) throws -> (session: GaussianRecoverySession, workspaceURL: URL)` crea una carpeta única y sus metadatos. No copia ni borra el dataset original.
- `GaussianRecovery.update(session:workspaceURL:step:state:) throws -> GaussianRecoverySession` escribe metadatos atómicamente después de confirmar un checkpoint válido. `state` es opcional y vale `checkpointed`. Devuelve el registro actualizado; se puede ignorar el resultado.
- `GaussianRecovery.sessions() -> [GaussianRecoverySession]` lista sesiones con un checkpoint regular y no vacío, ordenadas por `updatedAt` descendente. No valida todavía los tensores del checkpoint: esa comprobación corresponde al motor al reanudar. No borra metadatos ilegibles.
- `GaussianRecovery.remove(_ record:) throws` elimina únicamente la carpeta de la sesión. Usar después de confirmar descarte, o después del commit exitoso de todos los resultados y del checkpoint en la biblioteca. Nunca borra el dataset de origen.

`GaussianRecoverySession` es Codable, Sendable e Identifiable. Propiedades persistidas: `id`, `datasetPath`, `targetIterations`, `downscale`, `createdAt`, `step`, `updatedAt`, `state`. Propiedades derivadas: `datasetURL`, `workspaceURL`, `checkpointURL`.

Si el dataset está dentro de Documents, `datasetPath` se guarda relativo a Documents para tolerar cambios del identificador del contenedor después de reinstalar/restaurar. Fuentes externas conservan una ruta absoluta; quien las importe debe garantizar su disponibilidad antes de entrenar.

El servicio debe terminar/checkpointar y destruir el handle Metal antes de permitir borrar o volver a escribir su carpeta. No marcar un checkpoint como recuperable hasta finalizar su escritura atómica. La API de recuperación no elimina archivos temporales de un motor que siga trabajando.
