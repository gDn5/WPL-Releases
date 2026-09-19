#!/usr/bin/env bash
# Instala WoW Patagonia Launcher para Linux: las dependencias del sistema (vlc, xdotool, ydotool, wine),
# el launcher en formato AppImage, y lo agrega al menu de aplicaciones. Wine solo se usa despues, adentro
# del propio launcher, para lanzar el WoW.
#
# Uso:      curl -sL https://raw.githubusercontent.com/gDn5/WPL-Releases/main/install-native-linux.sh | bash
# Quitar:   curl -sL https://raw.githubusercontent.com/gDn5/WPL-Releases/main/install-native-linux.sh | bash -s -- --uninstall
set -euo pipefail

REPO="gDn5/WPL-Releases"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/main/install-native-linux.sh"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
INSTALL_DIR="$HOME/Applications"
APPIMAGE_PATH="$INSTALL_DIR/WowPatagoniaLauncher.AppImage"
LEGACY_DIR="$HOME/WowPatagoniaLauncher"

# ---------------------------------------------------------------------------------------
# Desinstalar: saca el launcher y su acceso directo. NO toca el juego, la configuracion ni el
# prefijo de Wine (son datos del jugador), ni los paquetes/reglas de sistema que se instalaron.
# ---------------------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    echo "Desinstalando el launcher..."
    if [ -x "$APPIMAGE_PATH" ]; then
        "$APPIMAGE_PATH" --remove-desktop-entry >/dev/null 2>&1 || true
    fi
    rm -f "$APPIMAGE_PATH" \
        "$DATA_HOME/applications/wowpatagonia-launcher.desktop" \
        "$DATA_HOME/icons/wowpatagonia-launcher.png"
    echo "Listo. Quedaron sin tocar tus datos: $DATA_HOME/WowLauncher (prefijo de Wine, logs) y"
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/WowLauncher (configuracion). Borralos a mano si tambien queres eso."
    exit 0
fi

echo "== Instalador del WoW Patagonia Launcher para Linux =="

install_deps() {
    echo "Instalando dependencias (vlc + plugins, xdotool, ydotool, wine)..."
    if command -v dnf >/dev/null 2>&1; then
        # vlc-libs por si solo NO alcanza: es unicamente libvlc.so/libvlccore.so, sin ningun
        # plugin de decodificacion (confirmado contra el .spec real de Fedora - vlc-plugins-base
        # es un subpaquete separado que vlc-libs no arrastra como dependencia). Sin el, libvlc
        # carga bien pero no hay nada que decodifique audio/video - silencio total, sin error.
        # vlc-plugins-base tampoco alcanza del todo: el video de fondo es H.264 (mp4), y ese
        # decoder especificamente vive en vlc-plugin-ffmpeg (otro subpaquete mas, separado de
        # base por licenciamiento de patentes - confirmado: la musica sonaba con solo
        # plugins-base instalado, pero el video seguia sin funcionar). vlc-plugins-all instala
        # todos los subpaquetes de una vez y evita seguir adivinando cual falta.
        # fuse-libs: el AppImage lo necesita para montarse (sin el no abre).
        sudo dnf install -y vlc-libs vlc-plugins-all xdotool ydotool wine fuse-libs
    elif command -v apt >/dev/null 2>&1; then
        # Debian/Ubuntu no separan tan finamente como Fedora, pero por las dudas se suma el
        # paquete "vlc" completo tambien, en vez de asumir que vlc-plugin-base alcanza.
        # libfuse2: el AppImage lo necesita para montarse y Ubuntu 22.04+ ya no lo trae de fabrica
        # (en 24.04 el paquete se llama libfuse2t64).
        FUSE_PKG="libfuse2"
        apt-cache show libfuse2t64 >/dev/null 2>&1 && FUSE_PKG="libfuse2t64"
        sudo apt install -y vlc vlc-plugin-base libvlc5 xdotool ydotool wine "$FUSE_PKG"
    elif command -v pacman >/dev/null 2>&1; then
        # A diferencia de Fedora/Debian, Arch no separa un paquete de "solo plugins" - libvlc por
        # si solo (confirmado contra su propio depends: solo dbus/glibc/libgcc, sin plugins) no
        # alcanza; hace falta el paquete "vlc" completo, que es el que trae los plugins reales
        # (incluido el decoder H.264, ya compilado adentro del mismo paquete en Arch).
        sudo pacman -S --needed --noconfirm vlc xdotool ydotool wine fuse2
    else
        echo "No reconozco tu gestor de paquetes. Instala manualmente: vlc (paquete completo, no solo la libreria), xdotool, ydotool, wine y libfuse2."
        exit 1
    fi
}

missing=()
command -v xdotool >/dev/null 2>&1 || missing+=("xdotool")
command -v ydotool >/dev/null 2>&1 || missing+=("ydotool")
command -v wine >/dev/null 2>&1 || missing+=("wine")
# No hay un binario "vlc-libs" en si - se chequea buscando la libreria compartida real.
ldconfig -p 2>/dev/null | grep -q "libvlc\.so" || missing+=("vlc-libs")
# La libreria puede estar presente sin sus plugins, y con SOLO los plugins basicos sin el
# decoder de video (ver comentario en install_deps - confirmado con un caso real: sonaba la
# musica pero no habia video, con vlc-plugins-base instalado y vlc-plugins-all/vlc-plugin-ffmpeg
# faltando). Se busca el plugin de avcodec especificamente (el que decodifica el H.264 del video
# de fondo), no solo "algun" archivo en la carpeta de plugins - asi una instalacion parcial
# vieja tambien se detecta como incompleta en vez de leerse como "ya esta todo instalado".
find /usr/lib* -ipath "*/vlc/plugins/*avcodec*" 2>/dev/null | grep -q . || missing+=("vlc-plugins")
# El AppImage se monta con FUSE 2.
ldconfig -p 2>/dev/null | grep -q "libfuse\.so\.2" || missing+=("libfuse2")

if [ ${#missing[@]} -gt 0 ]; then
    echo "Faltan: ${missing[*]}"
    install_deps
else
    echo "Todas las dependencias ya estan instaladas."
fi

# ydotool necesita permiso sobre /dev/uinput y un daemon (ydotoold) corriendo - el paquete de
# ydotool por si solo no alcanza en todas las distros (Fedora, por ejemplo, no trae la regla udev
# que si trae Arch). Se configura una vez de forma idempotente: regla udev propia (grupo "input"
# sobre /dev/uinput), el usuario agregado a ese grupo, y un servicio de usuario propio para
# ydotoold - no se depende del unit que cada distro empaqueta (Fedora lo hace a nivel sistema
# corriendo como root con el socket 0600 solo-root por default, Arch a nivel usuario; en vez de
# pelear con esa diferencia, se define un unit propio que siempre corre como el usuario actual).
echo "Configurando ydotool (para el login automatico sin el dialogo de Wayland)..."

UDEV_RULE_PATH="/etc/udev/rules.d/90-wowpatagonia-uinput.rules"
if [ ! -f "$UDEV_RULE_PATH" ]; then
    echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' | sudo tee "$UDEV_RULE_PATH" >/dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger --name-match=uinput 2>/dev/null || true
fi

NEEDS_RELOGIN=0
if ! id -nG "$USER" | grep -qw input; then
    sudo usermod -aG input "$USER"
    NEEDS_RELOGIN=1
fi

YDOTOOL_BIN="$(command -v ydotoold || true)"
if [ -n "$YDOTOOL_BIN" ]; then
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/ydotool.service" <<EOF
[Unit]
Description=ydotoold (WoW Patagonia Launcher)

[Service]
ExecStart=$YDOTOOL_BIN
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable ydotool

    if [ "$NEEDS_RELOGIN" -eq 0 ]; then
        systemctl --user restart ydotool
    fi
fi

if [ "$NEEDS_RELOGIN" -eq 1 ]; then
    echo ""
    echo "IMPORTANTE: se te agrego al grupo 'input' recien ahora - tenes que CERRAR SESION Y VOLVER"
    echo "A ENTRAR (no alcanza con reabrir la terminal) para que el login automatico del launcher"
    echo "funcione. El resto de la instalacion sigue igual mientras tanto."
fi

echo "Buscando la ultima version del launcher para Linux..."
RELEASES_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=30")" || {
    echo "No se pudo consultar GitHub (sin conexion o limite de consultas). Volve a intentar en un rato."
    exit 1
}
# El repo de releases tambien guarda las versiones de Windows (tags como "1.0.7"): las de Linux llevan
# el prefijo "linux-". GitHub devuelve los releases del mas nuevo al mas viejo; se toma el primero.
ASSET_URL="$(printf '%s' "$RELEASES_JSON" | grep -oE 'https://[^"]+/releases/download/linux-[^/"]+/[^/"]+\.AppImage' | head -1 || true)"
if [ -z "$ASSET_URL" ]; then
    echo "Todavia no hay una version del launcher para Linux publicada."
    exit 1
fi

echo "Descargando el launcher..."
mkdir -p "$INSTALL_DIR"
TMP_FILE="$(mktemp "$INSTALL_DIR/.launcher.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT
curl -fL --progress-bar -o "$TMP_FILE" "$ASSET_URL"
chmod +x "$TMP_FILE"
# Se reemplaza recien al terminar de bajar, asi un corte a la mitad no deja un launcher roto (y si ya
# estaba abierto, sigue andando: mv cambia el archivo, no el que esta corriendo).
mv -f "$TMP_FILE" "$APPIMAGE_PATH"
trap - EXIT

echo "Agregando el launcher al menu de aplicaciones..."
if ! "$APPIMAGE_PATH" --install-desktop-entry; then
    # Si FUSE todavia no esta disponible en esta sesion, el AppImage puede correr extrayendose solo.
    APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE_PATH" --install-desktop-entry \
        || echo "No se pudo crear la entrada del menu. El launcher igual se abre con: $APPIMAGE_PATH"
fi

if [ -x "$LEGACY_DIR/WowLauncher" ]; then
    echo ""
    echo "Nota: tenes una instalacion anterior en $LEGACY_DIR. Esa version no se actualiza sola;"
    echo "podes borrar esa carpeta cuando quieras (tus datos y el juego no estan ahi)."
fi

echo ""
echo "== Listo =="
echo "Buscalo como \"WoW Patagonia Launcher\" en el menu de aplicaciones, o abrilo con:"
echo "  $APPIMAGE_PATH"
# Con "curl | bash" $0 vale "bash", asi que el comando para quitarlo se arma con la URL, no con $0.
echo "Se actualiza solo desde adentro del launcher. Para quitarlo:"
echo "  curl -sL $SCRIPT_URL | bash -s -- --uninstall"
