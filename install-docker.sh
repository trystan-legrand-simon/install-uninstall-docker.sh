#!/usr/bin/env bash
#
# install-docker.sh — Installation de Docker CE multi-distributions
#
# Familles supportées :
#   - Debian : Debian, Ubuntu, Linux Mint, Pop!_OS, Kali (et dérivés via ID_LIKE)
#   - RedHat : RHEL, Rocky Linux, AlmaLinux, CentOS / CentOS Stream, Oracle Linux, Fedora
#
# Usage :
#   sudo ./install-docker.sh
#   sudo ENV_FILE=/chemin/prod.env ./install-docker.sh
#
# Configuration : un fichier .env placé à côté du script est chargé automatiquement
# (voir .env.example).
#
# Mode non interactif (optionnel) via variables d'environnement :
#   PROXY_HTTP=http://proxy:8080 PROXY_HTTPS=http://proxy:8080 \
#   PROXY_NO="localhost,127.0.0.1,.corp.local" DOCKER_DNS="10.0.0.1,10.0.0.2" \
#   DOCKER_USER=trystan NONINTERACTIVE=1 sudo -E ./install-docker.sh
#
# Surcharge du codename Debian/Ubuntu si ta distrib n'est pas reconnue :
#   DOCKER_CODENAME=bookworm sudo -E ./install-docker.sh

set -Eeuo pipefail

# --- Chargement du .env (même dossier que le script) --------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# --- Affichage ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_INFO=$'\e[1;34m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'; C_ERR=$'\e[1;31m'; C_RST=$'\e[0m'
else
  C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

info() { echo "${C_INFO}[*]${C_RST} $*"; }
ok()   { echo "${C_OK}[+]${C_RST} $*"; }
warn() { echo "${C_WARN}[!]${C_RST} $*" >&2; }
die()  { echo "${C_ERR}[x]${C_RST} $*" >&2; exit 1; }

trap 'die "Échec à la ligne $LINENO : ${BASH_COMMAND}"' ERR

NONINTERACTIVE="${NONINTERACTIVE:-0}"

ask() {
  # ask "Question" "valeur par défaut" -> écrit la réponse sur stdout
  local prompt="$1" default="${2:-}" answer=""
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    echo "$default"; return
  fi
  read -r -p "$prompt" answer </dev/tty || true
  echo "${answer:-$default}"
}

# --- Étape 0 : Droits root ---------------------------------------------------
require_root() {
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Ce script doit être lancé en root (sudo introuvable)."
    info "Relance du script avec sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

# --- Étape 1 : Détection de la distribution ---------------------------------
detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release introuvable, distribution non identifiable."
  # shellcheck disable=SC1091
  . /etc/os-release

  OS_ID="${ID,,}"
  OS_LIKE="${ID_LIKE,,}"
  OS_NAME="${PRETTY_NAME:-$ID}"
  FAMILY=""
  DOCKER_DISTRO=""
  CODENAME=""

  case "$OS_ID" in
    ubuntu)
      FAMILY="debian"; DOCKER_DISTRO="ubuntu"
      CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
    debian)
      FAMILY="debian"; DOCKER_DISTRO="debian"
      CODENAME="${VERSION_CODENAME:-}" ;;
    kali)
      # Kali est une rolling basée sur Debian testing : Docker n'a pas de dépôt "kali-rolling"
      FAMILY="debian"; DOCKER_DISTRO="debian"; CODENAME="bookworm" ;;
    fedora)
      FAMILY="rhel"; DOCKER_DISTRO="fedora" ;;
    rhel)
      FAMILY="rhel"; DOCKER_DISTRO="rhel" ;;
    centos|rocky|almalinux|ol)
      FAMILY="rhel"; DOCKER_DISTRO="centos" ;;
    *)
      # Dérivés : on se base sur ID_LIKE
      if [[ "$OS_LIKE" == *ubuntu* ]]; then
        FAMILY="debian"; DOCKER_DISTRO="ubuntu"
        CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      elif [[ "$OS_LIKE" == *debian* ]]; then
        FAMILY="debian"; DOCKER_DISTRO="debian"
        CODENAME="${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}"
      elif [[ "$OS_LIKE" == *fedora* || "$OS_LIKE" == *rhel* || "$OS_LIKE" == *centos* ]]; then
        FAMILY="rhel"; DOCKER_DISTRO="centos"
      else
        die "Distribution non supportée : $OS_NAME (ID=$OS_ID, ID_LIKE=$OS_LIKE)"
      fi ;;
  esac

  # Surcharge manuelle possible
  CODENAME="${DOCKER_CODENAME:-$CODENAME}"

  if [[ "$FAMILY" == "debian" && -z "$CODENAME" ]]; then
    die "Codename introuvable. Relance avec DOCKER_CODENAME=<bookworm|trixie|noble|...>."
  fi

  # Gestionnaire de paquets RedHat : dnf (RHEL 8+/Fedora) ou yum (CentOS 7)
  if [[ "$FAMILY" == "rhel" ]]; then
    if command -v dnf >/dev/null 2>&1; then PKG="dnf"; else PKG="yum"; fi
  fi

  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64|arm64) ;;
    *) warn "Architecture $arch : support Docker CE non garanti sur cette plateforme." ;;
  esac

  ok "Distribution détectée : $OS_NAME -> famille $FAMILY, dépôt Docker '$DOCKER_DISTRO'${CODENAME:+ ($CODENAME)}"
}

# --- Étape 2 : Proxy (AVANT toute requête réseau) -----------------------------
configure_proxy() {
  local use_proxy="n"
  if [[ -n "${PROXY_HTTP:-}" ]]; then
    use_proxy="y"
  else
    use_proxy="$(ask "Votre serveur utilise-t-il un proxy (y/N) ? " "n")"
  fi

  if [[ "${use_proxy,,}" == "y" ]]; then
    PROXY_HTTP="${PROXY_HTTP:-$(ask "Adresse du proxy HTTP (ex: http://proxy.exemple.com:8080) : " "")}"
    [[ -n "$PROXY_HTTP" ]] || die "Adresse de proxy HTTP vide."
    PROXY_HTTPS="${PROXY_HTTPS:-$(ask "Adresse du proxy HTTPS [$PROXY_HTTP] : " "$PROXY_HTTP")}"
    local extra_no
    extra_no="${PROXY_NO:-$(ask "Exclusions supplémentaires no_proxy (ex: .corp.local,10.0.0.0/8) [aucune] : " "")}"
    PROXY_NO="localhost,127.0.0.1,::1${extra_no:+,$extra_no}"

    # Utilisé par curl, apt et dnf/yum pendant l'exécution du script
    export http_proxy="$PROXY_HTTP" HTTP_PROXY="$PROXY_HTTP"
    export https_proxy="$PROXY_HTTPS" HTTPS_PROXY="$PROXY_HTTPS"
    export no_proxy="$PROXY_NO" NO_PROXY="$PROXY_NO"

    # yum/dnf ne lisent pas toujours les variables d'environnement : on force via dnf.conf / yum.conf
    if [[ "$FAMILY" == "rhel" ]]; then
      local conf="/etc/dnf/dnf.conf"
      [[ "$PKG" == "yum" ]] && conf="/etc/yum.conf"
      if ! grep -q '^proxy=' "$conf" 2>/dev/null; then
        cp -a "$conf" "${conf}.bak.$(date +%s)"
        echo "proxy=$PROXY_HTTP" >> "$conf"
        info "Proxy ajouté dans $conf (sauvegarde créée)."
      fi
    fi

    ok "Proxy configuré : HTTP=$PROXY_HTTP | HTTPS=$PROXY_HTTPS | NO_PROXY=$PROXY_NO"
  else
    PROXY_HTTP=""; PROXY_HTTPS=""; PROXY_NO=""
  fi
}

# --- Étape 3 : Suppression des paquets conflictuels -------------------------
remove_conflicts() {
  info "Suppression d'éventuels paquets Docker/Podman conflictuels..."
  if [[ "$FAMILY" == "debian" ]]; then
    local pkgs=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
    local installed=()
    for p in "${pkgs[@]}"; do
      dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p")
    done
    if ((${#installed[@]})); then
      DEBIAN_FRONTEND=noninteractive apt-get remove -y "${installed[@]}"
    fi
  else
    # Sur RHEL/Rocky/Alma, podman et runc entrent en conflit avec containerd.io
    $PKG remove -y docker docker-client docker-client-latest docker-common \
      docker-latest docker-latest-logrotate docker-logrotate docker-engine \
      podman podman-docker buildah runc >/dev/null 2>&1 || true
  fi
}

# --- Étape 4a : Installation famille Debian ---------------------------------
install_docker_debian() {
  export DEBIAN_FRONTEND=noninteractive

  info "Installation des dépendances (apt)..."
  apt-get update
  apt-get install -y ca-certificates curl gnupg

  info "Ajout de la clé GPG Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  info "Ajout du dépôt Docker (${DOCKER_DISTRO} ${CODENAME})..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  info "Installation de Docker..."
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# --- Étape 4b : Installation famille RedHat ---------------------------------
install_docker_rhel() {
  info "Installation des dépendances ($PKG)..."
  # curl-minimal est présent par défaut sur Rocky/Alma 9+ : ne pas forcer "curl" (conflit)
  command -v curl >/dev/null 2>&1 || $PKG install -y curl
  $PKG install -y ca-certificates

  info "Ajout du dépôt Docker (${DOCKER_DISTRO})..."
  curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/docker-ce.repo" \
    -o /etc/yum.repos.d/docker-ce.repo

  info "Installation de Docker (la clé GPG Docker est importée automatiquement)..."
  $PKG makecache
  $PKG install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# --- Étape 5 : Proxy et DNS pour le démon Docker -----------------------------
configure_docker_daemon() {
  if [[ -n "$PROXY_HTTP" ]]; then
    info "Configuration du proxy pour le démon Docker (drop-in systemd)..."
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY_HTTP}"
Environment="HTTPS_PROXY=${PROXY_HTTPS}"
Environment="NO_PROXY=${PROXY_NO}"
EOF
  fi

  # DNS personnalisés (optionnel) : utile si le DNS interne ne résout pas depuis les conteneurs
  local dns="${DOCKER_DNS:-}"
  if [[ -z "$dns" && "$NONINTERACTIVE" != "1" ]]; then
    dns="$(ask "DNS personnalisés pour les conteneurs, séparés par des virgules (vide = DNS de l'hôte) : " "")"
  fi
  if [[ -n "$dns" ]]; then
    mkdir -p /etc/docker
    [[ -f /etc/docker/daemon.json ]] && cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%s)"
    local json_dns
    json_dns="$(echo "$dns" | tr -d ' ' | sed 's/,/", "/g')"
    cat > /etc/docker/daemon.json <<EOF
{
  "dns": ["${json_dns}"]
}
EOF
    info "DNS Docker configurés : $dns"
  fi

  systemctl daemon-reload
  systemctl enable --now containerd docker
  systemctl restart docker
  ok "Service Docker actif et activé au démarrage."
}

# --- Étape 5b : Proxy pour les conteneurs et les builds ----------------------
configure_container_proxy() {
  [[ -z "$PROXY_HTTP" ]] && return 0

  local users=("root")
  local target="${DOCKER_USER:-${SUDO_USER:-}}"
  [[ -n "$target" && "$target" != "root" ]] && users+=("$target")

  local u home cfg_dir cfg backup
  for u in "${users[@]}"; do
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -z "$home" ]] && continue
    cfg_dir="$home/.docker"
    cfg="$cfg_dir/config.json"
    mkdir -p "$cfg_dir"

    if [[ -s "$cfg" ]]; then
      if ! command -v jq >/dev/null 2>&1; then
        warn "$cfg existe déjà et jq est absent : ajoute la section 'proxies' manuellement."
        continue
      fi
      backup="${cfg}.bak.$(date +%s)"
      cp -a "$cfg" "$backup"
      if ! jq --arg h "$PROXY_HTTP" --arg s "$PROXY_HTTPS" --arg n "$PROXY_NO" \
           '.proxies.default = {httpProxy: $h, httpsProxy: $s, noProxy: $n}' \
           "$backup" > "$cfg"; then
        cp -a "$backup" "$cfg"
        warn "Fusion jq échouée pour $cfg (fichier restauré)."
        continue
      fi
    else
      cat > "$cfg" <<EOF
{
  "proxies": {
    "default": {
      "httpProxy": "${PROXY_HTTP}",
      "httpsProxy": "${PROXY_HTTPS}",
      "noProxy": "${PROXY_NO}"
    }
  }
}
EOF
    fi
    chown -R "$u":"$(id -gn "$u")" "$cfg_dir"
    chmod 600 "$cfg"
    info "Proxy conteneurs/builds configuré pour '$u' ($cfg)."
  done
}

# --- Étape 6 : Ajout de l'utilisateur au groupe docker (optionnel) -----------
add_user_to_docker_group() {
  local target="${DOCKER_USER:-${SUDO_USER:-}}"
  [[ -z "$target" || "$target" == "root" ]] && return 0

  local answer="y"
  if [[ -z "${DOCKER_USER:-}" ]]; then
    answer="$(ask "Ajouter '$target' au groupe docker (usage sans sudo, équivaut à des droits root) (y/N) ? " "n")"
  fi
  if [[ "${answer,,}" == "y" ]]; then
    usermod -aG docker "$target"
    ok "'$target' ajouté au groupe docker (reconnexion nécessaire)."
  fi
}

# --- Étape 7 : Vérification --------------------------------------------------
verify_docker_installation() {
  info "Vérification de l'installation..."
  docker --version
  docker compose version
  docker run --rm hello-world >/dev/null
  ok "Docker est opérationnel (hello-world exécuté avec succès)."
}

# --- Programme principal -----------------------------------------------------
main() {
  require_root "$@"
  detect_os
  configure_proxy
  remove_conflicts

  case "$FAMILY" in
    debian) install_docker_debian ;;
    rhel)   install_docker_rhel ;;
  esac

  configure_docker_daemon
  configure_container_proxy
  add_user_to_docker_group
  verify_docker_installation

  ok "Installation et configuration de Docker terminées avec succès sur $OS_NAME !"
}

main "$@"