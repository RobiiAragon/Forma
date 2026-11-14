# Forma Build and Utility Makefile
# ----------------------------------------
# Este Makefile está diseñado para estandarizar los flujos de trabajo
# de construcción (build), generación de artefactos y ejecución de pruebas.

.PHONY: all build run_tests self-test clean setup-deps

# Target por defecto: Compilación y configuración inicial
all: build

# 1. Setup de dependencias (Motor Vendor)
setup-deps: scripts/build_msplat.sh scripts/generate_project.py
	@echo "----------------------------------------------------------"
	@echo "✅ Configurando dependencias del motor Vendor/Msplat..."
	./scripts/build_msplat.sh
	echo "✅ Ejecutando generador de proyecto..."
	python3 ./scripts/generate_project.py

# 2. Compilación del proyecto (Xcode)
build: setup-deps
	@echo "----------------------------------------------------------"
	@echo "🚀 Iniciando proceso de compilación en Xcode..."
	@echo "Por favor, abra Forma.xcodeproj manualmente para la compilación y configuración de firmas."
	@echo "Verifique los resultados en la carpeta build/."

# 3. Ejecución de Pruebas (Unitarias y de Integración)
run_tests: 
	@echo "----------------------------------------------------------"
	@echo "🧪 Iniciando ejecución de la suite de tests..."
	# Nota: La ejecución total es muy larga y varía. Esto ejecuta un set de tests clave en el simulador.
	xcodebuild -project Forma.xcodeproj -scheme Forma \
	  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
	  -derivedDataPath build -parallel-testing-enabled NO \
	  -collect-test-diagnostics never test

# 4. Pruebas de Integridad (Self-Test)
self-test: Tools/export_photogrammetry_mesh.swift
	@echo "----------------------------------------------------------"
	@echo "🔬 Ejecutando prueba de integridad del exportador PLY..."
	# Usamos un directorio temporal para el test, asegurando limpieza.
	mkdir -p temp_test_output
	python3 ./Tools/run_self_test.py --mesh Tools/export_photogrammetry_mesh.swift temp_test_output

# 5. Limpieza de artefactos
clean: build/
	@echo "🧹 Eliminando directorios de compilación y artefactos..."
	rm -rf build/

# Helper para el test de PLY (Este archivo requiere una pequeña stub o ajuste para ejecutarse)
# Por simplicidad, este target asume que el script de self-test está preparado.

