#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "\nERRO na linha %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SOURCE="$REPO_DIR/config"
CONFIG_TARGET="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_TARGET="${XDG_STATE_HOME:-$HOME/.local/state}"
PACKAGE_FILE="$REPO_DIR/system/packages-explicit.txt"
NOCTALIA_SETTINGS_SRC="$REPO_DIR/private-local/noctalia-settings.toml"
NOCTALIA_SETTINGS_DST="$STATE_TARGET/noctalia/settings.toml"
BACKUP_ROOT="$STATE_TARGET/cachyos-dotfiles/backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

# Arquivos que não devem ser restaurados para ~/.config
EXCLUDES=('*.bak' '*.orig' '*~' '.DS_Store')

INSTALL_PACKAGES=false
DRY_RUN=false
ASSUME_YES=false
BACKED_UP=false

usage() {
    cat <<USAGE
Uso: ./install.sh [opções]

  -n, --dry-run           Mostra o que seria feito, sem alterar nada
  -p, --install-packages  Instala pacotes dos repositórios oficiais
  -y, --yes               Não pede confirmação ao instalar pacotes
  -h, --help              Mostra esta ajuda
USAGE
}

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\nERRO: %s\n' "$*" >&2; exit 1; }

# Executa o comando ou apenas o exibe no modo --dry-run.
run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '  [dry-run] %q' "$1"; shift
        if (($# > 0)); then printf ' %q' "$@"; fi
        printf '\n'
    else
        "$@"
    fi
}

while (($# > 0)); do
    case "$1" in
        -p|--install-packages) INSTALL_PACKAGES=true ;;
        -n|--dry-run)          DRY_RUN=true ;;
        -y|--yes)              ASSUME_YES=true ;;
        -h|--help)             usage; exit 0 ;;
        *) usage >&2; die "Argumento desconhecido: $1" ;;
    esac
    shift
done

# --- Validações ---------------------------------------------------------
((EUID != 0)) || die "Não execute como root; o script usa sudo quando necessário."
[[ -d "$CONFIG_SOURCE" ]] || die "Diretório config/ não encontrado em $REPO_DIR."
command -v rsync >/dev/null || die "rsync não encontrado (sudo pacman -S rsync)."

if [[ "$INSTALL_PACKAGES" == true ]]; then
    command -v pacman >/dev/null || die "pacman não encontrado."
    command -v sudo   >/dev/null || die "sudo não encontrado."
    [[ -f "$PACKAGE_FILE" ]]     || die "Lista de pacotes não encontrada: $PACKAGE_FILE"
fi

# --- Funções ------------------------------------------------------------
backup_item() {
    local target="$1" subdir="$2"
    run mkdir -p -- "$BACKUP_DIR/$subdir"
    # -L: se for symlink, guarda o conteúdo real e não só o link.
    run cp -aL -- "$target" "$BACKUP_DIR/$subdir/"
    BACKED_UP=true
}

sync_dir() {
    local src="$1" dst="$2" args=(-a) pattern
    for pattern in "${EXCLUDES[@]}"; do
        args+=(--exclude="$pattern")
    done
    run rsync "${args[@]}" -- "$src/" "$dst/"
}

# --- Restauração das configurações --------------------------------------
if [[ "$DRY_RUN" == true ]]; then log "SIMULAÇÃO: nenhuma alteração será feita."; fi
log "Repositório: $REPO_DIR"
log "Destino:     $CONFIG_TARGET"
log "Backup:      $BACKUP_DIR"

run mkdir -p -- "$CONFIG_TARGET"

while IFS= read -r -d '' source_item; do
    name="${source_item##*/}"
    target="$CONFIG_TARGET/$name"

    if [[ -e "$target" || -L "$target" ]]; then
        log "Backup de $target"
        backup_item "$target" "config"

        # Se o destino for um symlink, remove-o para não escrever através dele
        # (por exemplo, de volta para dentro do próprio repositório).
        if [[ -L "$target" ]]; then
            run rm -- "$target"
        fi
    fi

    log "Restaurando $target"
    if [[ -d "$source_item" ]]; then
        run mkdir -p -- "$target"
        sync_dir "$source_item" "$target"
    else
        run cp -a -- "$source_item" "$target"
    fi
done < <(find "$CONFIG_SOURCE" -mindepth 1 -maxdepth 1 \
              ! -name '*.bak' ! -name '*.orig' ! -name '*~' -print0 | sort -z)

# --- Configurações locais do Noctalia (private-local/) -------------------
if [[ -f "$NOCTALIA_SETTINGS_SRC" ]]; then
    log "Restaurando $NOCTALIA_SETTINGS_DST"
    if [[ -e "$NOCTALIA_SETTINGS_DST" || -L "$NOCTALIA_SETTINGS_DST" ]]; then
        backup_item "$NOCTALIA_SETTINGS_DST" "state/noctalia"
    fi
    run mkdir -p -- "${NOCTALIA_SETTINGS_DST%/*}"
    run cp -a -- "$NOCTALIA_SETTINGS_SRC" "$NOCTALIA_SETTINGS_DST"
else
    log "Sem private-local/noctalia-settings.toml; configurações locais do Noctalia ignoradas."
fi

# --- Pacotes ------------------------------------------------------------
if [[ "$INSTALL_PACKAGES" == true ]]; then
    log "Verificando pacotes oficiais disponíveis."

    # Ignora comentários, espaços, CRLF e linhas vazias.
    wanted="$(sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' \
                  -e 's/[[:space:]]*$//' "$PACKAGE_FILE" | awk 'NF' | sort -u)"

    # Uma única consulta ao pacman em vez de uma por pacote.
    in_repos="$(pacman -Slq | sort -u)"
    installed="$(pacman -Qq | sort -u)"

    mapfile -t available < <(comm -12 <(printf '%s\n' "$wanted") <(printf '%s\n' "$in_repos") \
                             | comm -23 - <(printf '%s\n' "$installed"))
    mapfile -t skipped   < <(comm -23 <(printf '%s\n' "$wanted") <(printf '%s\n' "$in_repos"))

    if ((${#available[@]} > 0)); then
        log "Instalando ${#available[@]} pacotes oficiais."
        pacman_args=(-S --needed)
        if [[ "$ASSUME_YES" == true ]]; then pacman_args+=(--noconfirm); fi
        run sudo pacman "${pacman_args[@]}" -- "${available[@]}"
    else
        log "Nenhum pacote oficial pendente."
    fi

    if ((${#skipped[@]} > 0)); then
        log "Fora dos repositórios oficiais (possíveis AUR):"
        printf '  %s\n' "${skipped[@]}"
        if [[ "$DRY_RUN" == false ]]; then
            mkdir -p -- "$BACKUP_DIR"
            printf '%s\n' "${skipped[@]}" > "$BACKUP_DIR/packages-skipped.txt"
            BACKED_UP=true
        fi
    fi
fi

# --- Final --------------------------------------------------------------
log "Concluído."
if [[ "$DRY_RUN" == false ]]; then
    printf 'Configurações restauradas em: %s\n' "$CONFIG_TARGET"
    if [[ "$BACKED_UP" == true ]]; then
        printf 'Backup anterior em: %s\n' "$BACKUP_DIR"
    fi
    printf '\nRevise as configurações antes de recarregar o Hyprland (hyprctl reload).\n'
fi
