#!/bin/bash
# Rebuild and update the existing Forma installation; never uninstall or launch it.
set -euo pipefail

usage() {
  cat <<'HELP'
Uso: scripts/install_iphone.sh --device UDID [--build-only] [--derived-data RUTA]
     FORMA_DEVICE_ID=UDID scripts/install_iphone.sh

Compila Forma Release optimizada (-O), permite a Xcode actualizar su perfil de
desarrollo e instala sobre com.robii.forma usando el mismo equipo 9X76Y99YGD.
No desinstala, no abre la app y no modifica permisos de privacidad.

Opciones:
  --device UDID        iPhone elegido explícitamente (prima sobre FORMA_DEVICE_ID).
  --build-only         Compilar y verificar la firma; no instalar.
  --derived-data RUTA  Carpeta de compilación (por defecto: build/device-v5).
  -h, --help           Mostrar esta ayuda sin compilar ni acceder al teléfono.

Lista de dispositivos: xcrun devicectl list devices
Conecta y desbloquea el iPhone. Xcode debe tener iniciada la cuenta Apple del
equipo indicado. Ejecutar cuando Forma no esté capturando ni guardando.
HELP
}

device_id="${FORMA_DEVICE_ID:-}"
derived_data="build/device-v5"
build_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --device|--derived-data)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'Falta el valor de %s.\n' "$1" >&2; exit 2; }
      if [ "$1" = --device ]; then device_id="$2"; else derived_data="$2"; fi
      shift 2 ;;
    --build-only) build_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Opción desconocida: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$device_id" ]; then
  printf 'Indica --device UDID o FORMA_DEVICE_ID. No se elige un teléfono automáticamente.\n' >&2
  usage >&2
  exit 2
fi
case "$device_id" in
  *[!a-fA-F0-9-]*|-) printf 'Usa el identificador UDID de xcrun devicectl list devices.\n' >&2; exit 2 ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
case "$derived_data" in /*) ;; *) derived_data="$project_dir/$derived_data" ;; esac
readonly team_id=9X76Y99YGD bundle_id=com.robii.forma
app="$derived_data/Build/Products/Release-iphoneos/Forma.app"
profile_plist=""
trap 'if [ -n "$profile_plist" ]; then rm -f -- "$profile_plist"; fi' EXIT
trap 'status=$?; printf "Se detuvo la actualización. No se solicitó desinstalar Forma. Revisa el error anterior y docs/IPHONE_INSTALLATION.md.\n" >&2; exit "$status"' ERR

command -v xcodebuild >/dev/null
xcrun --find devicectl >/dev/null
[ -d "$project_dir/Forma.xcodeproj" ] || { printf 'Falta Forma.xcodeproj.\n' >&2; exit 1; }
cd -- "$project_dir"
printf 'Compilando Release -O para %s; bundle %s; equipo %s.\n' "$device_id" "$bundle_id" "$team_id"
xcodebuild -project Forma.xcodeproj -scheme Forma -configuration Release \
  -destination "id=$device_id" -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$team_id" \
  SWIFT_OPTIMIZATION_LEVEL=-O build

actual_bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
[ "$actual_bundle" = "$bundle_id" ] || { printf 'Bundle inesperado; no se instala.\n' >&2; exit 1; }
codesign --verify --strict "$app"
actual_team="$(codesign -dv --verbose=4 "$app" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2 }')"
[ "$actual_team" = "$team_id" ] || { printf 'Equipo de firma inesperado; no se instala.\n' >&2; exit 1; }
profile_plist="$(mktemp -t forma-iphone-profile)"
security cms -D -i "$app/embedded.mobileprovision" > "$profile_plist"
profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")"
[ "$profile_team" = "$team_id" ] || { printf 'Perfil de otro equipo; no se instala.\n' >&2; exit 1; }
expiration="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$profile_plist")"
printf 'Firma verificada. Caducidad indicada por el perfil: %s\n' "$expiration"

if [ "$build_only" -eq 1 ]; then
  printf 'Compilación lista; no se instaló: %s\n' "$app"
  exit 0
fi
printf 'Actualizando la instalación existente; no se abrirá la app.\n'
xcrun devicectl device install app --device "$device_id" "$app"
printf 'Instalación terminada. Abre Forma manualmente en el iPhone.\n'
