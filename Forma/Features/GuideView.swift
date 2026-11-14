import SwiftUI

struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Eyebrow(text: "El pequeño manual de captura")
                Text("Cada detalle\nempieza contigo.").font(.system(size: 38, weight: .regular, design: .serif)).foregroundStyle(FormaStyle.cream)
                guide("01", "Espacios · LiDAR + textura", "Camina despacio y rodea las superficies. La app guarda fotos calibradas y profundidad. Con Máxima calidad utiliza el formato 4K compatible y añade fotos HiRes; el contador muestra las dimensiones reales. Las superficies observadas reciben textura fotográfica; las que falten quedan neutras.", "viewfinder")
                guide("02", "Objetos · fotogrametría", "Usa luz suave y constante. Rodea un objeto inmóvil desde varias alturas, con fondo de textura visible. Evita cristal, espejos y superficies brillantes. La reconstrucción local usa el nivel reducido de Apple.", "cube.transparent")
                guide("03", "Habitaciones · RoomPlan", "Recorre paredes, puertas y ventanas. Sigue la guía de Apple para completar el espacio. El resultado es un modelo paramétrico; conserva también sus datos JSON.", "square.split.bottomrightquarter")
                guide("04", "Gaussian · Metal", "Guarda una captura LiDAR con fotos y pulsa Entrenar Gaussian Splatting en su detalle. El entrenamiento optimiza posición, escala, rotación, opacidad y armónicos esféricos contra tus fotografías. Factor 1 conserva toda la resolución. Las iteraciones son editables y puedes continuar desde un checkpoint. Rodea la escena: las vistas faltantes no se inventan.", "sparkles")
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "Calidad antes que promesas")
                    Text("Comprueba lo que importa.").font(.system(size: 24, design: .serif))
                    Text("Mide al menos tres distancias de referencia y compáralas con el modelo en tu programa 3D. Repite el mismo recorrido con Polycam para evaluar error, huecos, tiempo y tamaño de archivo. Forma todavía no tiene una precisión certificada.")
                        .font(.system(size: 13)).foregroundStyle(FormaStyle.muted).lineSpacing(5)
                }.padding(20).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
                Text("Sin cuotas de escaneos ni formatos de pago. El espacio disponible, el calor y la memoria del dispositivo siguen determinando lo que puede procesarse.")
                    .font(.system(size: 12)).foregroundStyle(FormaStyle.muted).lineSpacing(4)
            }.padding(24).padding(.top, 15)
        }.scrollIndicators(.hidden)
    }
    private func guide(_ index: String, _ title: String, _ text: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: symbol).font(.system(size: 27, weight: .ultraLight)).foregroundStyle(FormaStyle.accent)
                Spacer(); Eyebrow(text: index)
            }
            Text(title).font(.system(size: 19, weight: .medium, design: .serif))
            Text(text).font(.system(size: 13)).foregroundStyle(FormaStyle.muted).lineSpacing(5)
        }.padding(22).background(FormaStyle.panel, in: RoundedRectangle(cornerRadius: 20))
    }
}
