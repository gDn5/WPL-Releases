#!/usr/bin/env bash
set -euo pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ] && command -v tput >/dev/null 2>&1; then
    BOLD="$(tput bold 2>/dev/null || true)"; DIM="$(tput dim 2>/dev/null || true)"; RESET="$(tput sgr0 2>/dev/null || true)"
    RED="$(tput setaf 1 2>/dev/null || true)"; GREEN="$(tput setaf 2 2>/dev/null || true)"
    YELLOW="$(tput setaf 3 2>/dev/null || true)"; CYAN="$(tput setaf 6 2>/dev/null || true)"
else
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
fi

banner() { printf '\n%s%s⚔ %s%s\n\n' "$BOLD" "$CYAN" "$1" "$RESET"; }
step()   { printf '%s▸%s %s\n' "$CYAN" "$RESET" "$1"; }
ok()     { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn()   { printf '%s⚠%s %s\n' "$YELLOW" "$RESET" "$1"; }
err()    { printf '%s✗%s %s\n' "$RED" "$RESET" "$1" >&2; }

REPO="gDn5/WPL-Releases"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO}/main/install-native-linux.sh"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
INSTALL_DIR="$HOME/Applications"
APPIMAGE_PATH="$INSTALL_DIR/WowPatagoniaLauncher.AppImage"
LEGACY_DIR="$HOME/WowPatagoniaLauncher"

if [ "${1:-}" = "--uninstall" ]; then
    banner "Desinstalando el WoW Patagonia Launcher"
    if [ -x "$APPIMAGE_PATH" ]; then
        "$APPIMAGE_PATH" --remove-desktop-entry >/dev/null 2>&1 || true
    fi
    rm -f "$APPIMAGE_PATH" \
        "$DATA_HOME/applications/wowpatagonia-launcher.desktop" \
        "$DATA_HOME/icons/wowpatagonia-launcher.png"
    ok "Listo."
    printf '%sQuedaron sin tocar tus datos: %s (prefijo de Wine, logs) y%s\n' "$DIM" "$DATA_HOME/WowLauncher" "$RESET"
    printf '%s%s (configuracion). Borralos a mano si tambien queres eso.%s\n' "$DIM" "${XDG_CONFIG_HOME:-$HOME/.config}/WowLauncher" "$RESET"
    exit 0
fi

banner "Instalador del WoW Patagonia Launcher para Linux"

install_deps() {
    step "Instalando dependencias (VLC, xdotool, ydotool, wine)..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y vlc-libs vlc-plugins-all xdotool ydotool wine fuse-libs
    elif command -v apt >/dev/null 2>&1; then
        FUSE_PKG="libfuse2"
        apt-cache show libfuse2t64 >/dev/null 2>&1 && FUSE_PKG="libfuse2t64"
        sudo apt install -y vlc vlc-plugin-base libvlc5 xdotool ydotool wine "$FUSE_PKG"
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm vlc xdotool ydotool wine fuse2
    else
        err "No reconozco tu gestor de paquetes. Instala manualmente: vlc (paquete completo, no solo la libreria), xdotool, ydotool, wine y libfuse2."
        exit 1
    fi
}

step "Revisando dependencias..."
missing=()
command -v xdotool >/dev/null 2>&1 || missing+=("xdotool")
command -v ydotool >/dev/null 2>&1 || missing+=("ydotool")
command -v wine >/dev/null 2>&1 || missing+=("wine")
ldconfig -p 2>/dev/null | grep -q "libvlc\.so" || missing+=("vlc-libs")
(find /usr/lib* -ipath "*/vlc/plugins/*avcodec*" 2>/dev/null || true) | grep -q . || missing+=("vlc-plugins")
ldconfig -p 2>/dev/null | grep -q "libfuse\.so\.2" || missing+=("libfuse2")

if [ ${#missing[@]} -gt 0 ]; then
    warn "Faltan: ${missing[*]}"
    install_deps
    ok "Dependencias instaladas."
else
    ok "Todas las dependencias ya estan instaladas."
fi

step "Configurando ydotool (para el login automatico sin el dialogo de Wayland)..."

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
ok "ydotool configurado."

if [ "$NEEDS_RELOGIN" -eq 1 ]; then
    printf '\n%s%s⚠ IMPORTANTE:%s%s se te agrego al grupo '\''input'\'' recien ahora - tenes que CERRAR SESION Y VOLVER\n' "$BOLD" "$YELLOW" "$RESET" "$YELLOW"
    printf '%sA ENTRAR (no alcanza con reabrir la terminal) para que el login automatico del launcher\n' "$YELLOW"
    printf 'funcione. El resto de la instalacion sigue igual mientras tanto.%s\n' "$RESET"
fi

step "Buscando la ultima version del launcher para Linux..."
RELEASES_JSON="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=30")" || {
    err "No se pudo consultar GitHub (sin conexion o limite de consultas). Volve a intentar en un rato."
    exit 1
}
ASSET_URL="$(printf '%s' "$RELEASES_JSON" | grep -oE 'https://[^"]+/releases/download/linux-[^/"]+/[^/"]+\.AppImage' | head -1 || true)"
if [ -z "$ASSET_URL" ]; then
    err "Todavia no hay una version del launcher para Linux publicada."
    exit 1
fi

step "Descargando el launcher..."
mkdir -p "$INSTALL_DIR"
TMP_FILE="$(mktemp "$INSTALL_DIR/.launcher.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT
curl -fL --progress-bar -o "$TMP_FILE" "$ASSET_URL"
chmod +x "$TMP_FILE"
mv -f "$TMP_FILE" "$APPIMAGE_PATH"
trap - EXIT
ok "Launcher descargado."

step "Agregando el launcher al menu de aplicaciones..."
if "$APPIMAGE_PATH" --install-desktop-entry; then
    ok "Entrada de menu creada."
else
    if APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGE_PATH" --install-desktop-entry; then
        ok "Entrada de menu creada."
    else
        warn "No se pudo crear la entrada del menu. El launcher igual se abre con: $APPIMAGE_PATH"
    fi
fi

if [ -x "$LEGACY_DIR/WowLauncher" ]; then
    warn "Tenes una instalacion anterior en $LEGACY_DIR. Esa version no se actualiza sola;"
    printf '  podes borrar esa carpeta cuando quieras (tus datos y el juego no estan ahi).\n'
fi

banner "Listo"
printf 'Buscalo como %s"WoW Patagonia Launcher"%s en el menu de aplicaciones, o abrilo con:\n' "$BOLD" "$RESET"
printf '  %s%s%s\n\n' "$CYAN" "$APPIMAGE_PATH" "$RESET"
printf '%sSe actualiza solo desde adentro del launcher. Para quitarlo:%s\n' "$DIM" "$RESET"
printf '  %scurl -sL %s | bash -s -- --uninstall%s\n' "$DIM" "$SCRIPT_URL" "$RESET"
