#!/usr/bin/env bash
#
# uninstall-docker.sh — Désinstallation de Docker CE multi-distributions
#
# Défait ce qu'a installé install-docker.sh :
#   - arrêt et désactivation des services Docker / containerd
#   - suppression des paquets Docker CE
#   - suppression du dépôt et de la clé GPG Docker
#   - suppression du proxy (systemd, dnf.conf/yum.conf, ~/.docker/config.json)
#   - suppression de /etc/docker/daemon.json
#   - optionnel : suppression des données (images, conteneurs, volumes)
#   - optionnel : suppression du groupe docker
#
# Familles supportées :
#   - Debian : Debian, Ubuntu, Linux Mint, Pop!_OS, Kali (et dérivés via ID_LIKE)
#   - RedHat : RHEL, Rocky Linux, AlmaLinux, CentOS / CentOS Stream, Oracle Linux, Fedora
#
# Usage :
#   sudo ./uninstall-docker.sh                 # interactif
#   sudo ./uninstall-docker.sh --yes           # sans confirmation, garde les données
#   sudo ./uninstall-docker.sh --yes --purge   # sans confirmation, supprime TOUT
#
# Variables (.env ou environnement) :
#   NONINTERACTIVE=1   équivaut à --yes
#   REMOVE_DATA=1      équivaut à --purge
#   REMOVE_GROUP=1     supprime le groupe docker
#   DOCKER_USER=xxx    utilisateur dont le ~/.docker/config.json doit être nettoyé

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
REMOVE_DATA="${REMOVE_DATA:-0}"
REMOVE_GROUP="${REMOVE_GROUP:-0}"

DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin
             docker-compose-plugin docker-ce-rootless-extras)

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

parse_args() {
  while (($#)); do
    case "$1" in
      -y|--yes)   NONINTERACTIVE=1 ;;
      -p|--purge) REMOVE_DATA=1 ;;
      -g|--group) REMOVE_GROUP=1 ;;
      -h|--help)  usage ;;
      *) die "Option inconnue : $1 (voir --help)" ;;
    esac
    shift
  done
}

ask() {
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

  local id="${ID,,}" like="${ID_LIKE,,}"
  OS_NAME="${PRETTY_NAME:-$ID}"

  case "$id" in
    ubuntu|debian|kali) FAMILY="debian" ;;
    fedora|rhel|centos|rocky|almalinux|ol) FAMILY="rhel" ;;
    *)
      if [[ "$like" == *debian* || "$like" == *ubuntu* ]]; then
        FAMILY="debian"
      elif [[ "$like" == *fedora* || "$like" == *rhel* || "$like" == *centos* ]]; then
        FAMILY="rhel"
      else
        die "Distribution non supportée : $OS_NAME (ID=$id, ID_LIKE=$like)"
      fi ;;
  esac

  if [[ "$FAMILY" == "rhel" ]]; then
    if command -v dnf >/dev/null 2>&1; then PKG="dnf"; else PKG="yum"; fi
  fi

  ok "Distribution détectée : $OS_NAME -> famille $FAMILY"
}

# --- Étape 2 : Récapitulatif et confirmation --------------------------------
confirm() {
  echo
  info "Actions prévues :"
  echo "    - arrêt des services docker / containerd"
  echo "    - suppression des paquets : ${DOCKER_PKGS[*]}"
  echo "    - suppression du dépôt Docker, de la clé GPG et de la config proxy"
  echo "    - suppression de /etc/docker"

  if [[ "$REMOVE_DATA" != "1" && "$NONINTERACTIVE" != "1" ]]; then
    local a
    a="$(ask "Supprimer aussi les DONNÉES (images, conteneurs, volumes) ? (y/N) " "n")"
    [[ "${a,,}" == "y" ]] && REMOVE_DATA=1
  fi
  if [[ "$REMOVE_DATA" == "1" ]]; then
    echo "    - ${C_ERR}suppression DÉFINITIVE de /var/lib/docker et /var/lib/containerd${C_RST}"
  else
    echo "    - données conservées dans /var/lib/docker et /var/lib/containerd"
  fi

  if [[ "$REMOVE_GROUP" != "1" && "$NONINTERACTIVE" != "1" ]]; then
    local g
    g="$(ask "Supprimer le groupe docker ? (y/N) " "n")"
    [[ "${g,,}" == "y" ]] && REMOVE_GROUP=1
  fi
  if [[ "$REMOVE_GROUP" == "1" ]]; then
    echo "    - suppression du groupe docker"
  fi
  echo

  if [[ "$NONINTERACTIVE" != "1" ]]; then
    local c
    c="$(ask "Confirmer la désinstallation ? (y/N) " "n")"
    [[ "${c,,}" == "y" ]] || { info "Désinstallation annulée."; exit 0; }
  fi
}

# --- Étape 3 : Arrêt des services -------------------------------------------
stop_services() {
  info "Arrêt des services Docker..."
  if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
    local running
    running="$(docker ps -q 2>/dev/null | wc -l)"
    if ((running > 0)); then
      warn "$running conteneur(s) en cours d'exécution vont être arrêtés."
    fi
  fi
  systemctl disable --now docker.socket docker.service containerd.service >/dev/null 2>&1 || true
  ok "Services arrêtés et désactivés."
}

# --- Étape 4 : Suppression des paquets --------------------------------------
remove_packages() {
  info "Suppression des paquets Docker..."
  local installed=() p

  if [[ "$FAMILY" == "debian" ]]; then
    for p in "${DOCKER_PKGS[@]}"; do
      dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p")
    done
    if ((${#installed[@]})); then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}"
      DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
    fi
  else
    for p in "${DOCKER_PKGS[@]}"; do
      rpm -q "$p" >/dev/null 2>&1 && installed+=("$p")
    done
    if ((${#installed[@]})); then
      $PKG remove -y "${installed[@]}"
    fi
  fi

  if ((${#installed[@]})); then
    ok "Paquets supprimés : ${installed[*]}"
  else
    info "Aucun paquet Docker CE installé."
  fi
}

# --- Étape 5 : Dépôt et clé GPG ---------------------------------------------
remove_repository() {
  info "Suppression du dépôt Docker..."
  if [[ "$FAMILY" == "debian" ]]; then
    rm -f /etc/apt/sources.list.d/docker.list \
          /etc/apt/sources.list.d/docker.sources \
          /etc/apt/keyrings/docker.asc \
          /etc/apt/keyrings/docker.gpg
    apt-get update >/dev/null 2>&1 || warn "apt-get update a échoué (à vérifier manuellement)."
  else
    rm -f /etc/yum.repos.d/docker-ce.repo
    # Clé GPG Docker importée dans la base RPM
    local key
    for key in $(rpm -q gpg-pubkey --qf '%{NAME}-%{VERSION}-%{RELEASE}\t%{SUMMARY}\n' 2>/dev/null \
                 | awk -F'\t' '/[Dd]ocker/ {print $1}'); do
      rpm -e "$key" >/dev/null 2>&1 && info "Clé GPG retirée : $key"
    done
    $PKG clean all >/dev/null 2>&1 || true
  fi
  ok "Dépôt Docker supprimé."
}

# --- Étape 6 : Configuration proxy et démon ---------------------------------
remove_config() {
  info "Suppression de la configuration Docker..."

  # Drop-in systemd (proxy du démon)
  rm -rf /etc/systemd/system/docker.service.d
  systemctl daemon-reload

  # /etc/docker (daemon.json, certificats de registres, etc.)
  if [[ -d /etc/docker ]]; then
    rm -rf /etc/docker
  fi

  # Proxy ajouté dans dnf.conf / yum.conf par install-docker.sh
  if [[ "$FAMILY" == "rhel" ]]; then
    local conf="/etc/dnf/dnf.conf"
    [[ "$PKG" == "yum" ]] && conf="/etc/yum.conf"
    if grep -q '^proxy=' "$conf" 2>/dev/null; then
      local current; current="$(grep '^proxy=' "$conf" | head -n1 | cut -d= -f2-)"
      local remove="n"
      if [[ -n "${PROXY_HTTP:-}" && "$current" == "$PROXY_HTTP" ]]; then
        remove="y"   # c'est bien celui ajouté par install-docker.sh
      else
        remove="$(ask "Retirer 'proxy=$current' de $conf ? (d'autres outils peuvent l'utiliser) (y/N) " "n")"
      fi
      if [[ "${remove,,}" == "y" ]]; then
        cp -a "$conf" "${conf}.bak.$(date +%s)"
        sed -i '/^proxy=/d' "$conf"
        info "Proxy retiré de $conf (sauvegarde créée)."
      fi
    fi
  fi

  ok "Configuration système supprimée."
}

# --- Étape 7 : ~/.docker/config.json -----------------------------------------
clean_user_config() {
  local users=("root")
  local target="${DOCKER_USER:-${SUDO_USER:-}}"
  [[ -n "$target" && "$target" != "root" ]] && users+=("$target")

  local u home cfg
  for u in "${users[@]}"; do
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -z "$home" ]] && continue
    cfg="$home/.docker/config.json"
    [[ -f "$cfg" ]] || continue

    cp -a "$cfg" "${cfg}.bak.$(date +%s)"
    if command -v jq >/dev/null 2>&1; then
      local tmp; tmp="$(mktemp)"
      if jq 'del(.proxies)' "$cfg" > "$tmp"; then
        if [[ "$(jq 'length' "$tmp")" == "0" ]]; then
          rm -f "$cfg"
          info "$cfg ne contenait que le proxy : supprimé."
        else
          cat "$tmp" > "$cfg"
          info "Section 'proxies' retirée de $cfg (identifiants de registres conservés)."
        fi
      fi
      rm -f "$tmp"
    else
      # Sans jq : on ne supprime que si le fichier ne contient que la config proxy
      if ! grep -q '"auths"\|"credsStore"\|"credHelpers"' "$cfg"; then
        rm -f "$cfg"
        info "$cfg supprimé (sauvegarde créée)."
      else
        warn "$cfg contient d'autres réglages et jq est absent : retire 'proxies' manuellement."
      fi
    fi
  done
}

# --- Étape 8 : Données -------------------------------------------------------
remove_data() {
  if [[ "$REMOVE_DATA" == "1" ]]; then
    info "Suppression des données Docker..."
    rm -rf /var/lib/docker /var/lib/containerd
    ok "Images, conteneurs et volumes supprimés."
  else
    info "Données conservées : /var/lib/docker, /var/lib/containerd"
  fi
  rm -f /var/run/docker.sock /run/docker.sock
}

# --- Étape 9 : Groupe docker -------------------------------------------------
remove_group() {
  [[ "$REMOVE_GROUP" == "1" ]] || return 0
  if getent group docker >/dev/null; then
    groupdel docker
    ok "Groupe docker supprimé."
  fi
}

# --- Étape 10 : Vérification -------------------------------------------------
verify() {
  if command -v docker >/dev/null 2>&1; then
    warn "La commande 'docker' est encore présente : $(command -v docker) (installation hors paquet ?)"
  else
    ok "Commande docker absente."
  fi
}

# --- Programme principal -----------------------------------------------------
main() {
  parse_args "$@"
  require_root "$@"
  detect_os
  confirm
  stop_services
  remove_packages
  remove_repository
  remove_config
  clean_user_config
  remove_data
  remove_group
  verify

  ok "Désinstallation de Docker terminée sur $OS_NAME."
  if [[ "$FAMILY" == "rhel" ]]; then
    info "Podman n'est pas réinstallé automatiquement : 'dnf install podman' si besoin."
  fi
}

main "$@"