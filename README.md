# install-docker.sh

Script Bash d'installation de **Docker CE** multi-distributions Linux (familles Debian et RedHat), avec gestion complète du **proxy d'entreprise** : gestionnaire de paquets, démon Docker, conteneurs et builds.

Il détecte automatiquement la distribution et utilise le dépôt officiel Docker adapté. Il fonctionne en mode interactif ou entièrement piloté par un fichier `.env`.

---

## Distributions supportées

| Famille | Distributions | Gestionnaire | Dépôt Docker utilisé |
|---|---|---|---|
| Debian | Debian | `apt` | `linux/debian` |
| Debian | Ubuntu, Linux Mint, Pop!_OS | `apt` | `linux/ubuntu` |
| Debian | Kali Linux | `apt` | `linux/debian` (`bookworm`) |
| RedHat | Rocky Linux, AlmaLinux, CentOS / Stream, Oracle Linux | `dnf` / `yum` | `linux/centos` |
| RedHat | RHEL | `dnf` | `linux/rhel` |
| RedHat | Fedora | `dnf` | `linux/fedora` |

Les autres dérivés sont détectés via `ID_LIKE` dans `/etc/os-release`.
Architectures : `x86_64` et `aarch64`.

---

## Fonctionnalités

- Détection automatique de la distribution et du codename
- Installation depuis les **dépôts officiels Docker** : `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- Suppression des paquets conflictuels (`docker.io`, `podman`, `runc`, etc.)
- Configuration du proxy à trois niveaux :
  - gestionnaire de paquets (`apt`, `dnf.conf` / `yum.conf`)
  - démon Docker, pour `docker pull` (drop-in systemd)
  - conteneurs et `docker build` (`~/.docker/config.json`)
- Script de désinstallation symétrique (`uninstall-docker.sh`)
- DNS personnalisés pour les conteneurs (optionnel)
- Ajout d'un utilisateur au groupe `docker` (optionnel)
- Mode non interactif via `.env` ou variables d'environnement
- Sauvegarde automatique des fichiers de configuration modifiés
- Arrêt immédiat en cas d'erreur, avec la ligne fautive affichée
- Vérification finale avec `hello-world`

---

## Prérequis

- Une distribution supportée avec `systemd`
- Un accès `root` ou `sudo`
- Un accès réseau à `download.docker.com`, directement ou via proxy
- `jq` (optionnel) : utile seulement si un `~/.docker/config.json` existe déjà et doit être fusionné

---

## Installation rapide

### Mode interactif

```bash
git clone https://github.com/<ton-user>/<ton-repo>.git
cd <ton-repo>
chmod +x install-docker.sh
sudo ./install-docker.sh
```

Le script pose ses questions : proxy, DNS, ajout au groupe `docker`.

### Mode non interactif (`.env`)

```bash
cp .env.example .env
chmod 600 .env
nano .env                 # adapter les valeurs
sudo ./install-docker.sh
```

Le fichier `.env` placé à côté du script est chargé automatiquement. Pour utiliser un autre fichier :

```bash
sudo ENV_FILE=/chemin/prod.env ./install-docker.sh
```

---

## Configuration

| Variable | Description | Exemple | Défaut |
|---|---|---|---|
| `PROXY_HTTP` | Proxy HTTP. Vide = pas de proxy | `http://proxy:8080` | *(vide)* |
| `PROXY_HTTPS` | Proxy HTTPS | `http://proxy:8080` | valeur de `PROXY_HTTP` |
| `PROXY_NO` | Exclusions du proxy. `localhost,127.0.0.1,::1` sont ajoutés automatiquement | `.corp.local,10.0.0.0/8` | *(vide)* |
| `DOCKER_DNS` | DNS des conteneurs, séparés par des virgules | `10.0.0.1,10.0.0.2` | DNS de l'hôte |
| `DOCKER_USER` | Utilisateur à ajouter au groupe `docker` | `trystan` | *(aucun)* |
| `DOCKER_CODENAME` | Force le codename Debian/Ubuntu | `bookworm` | détecté |
| `NONINTERACTIVE` | `1` = aucune question posée | `1` | `0` |
| `ENV_FILE` | Chemin du fichier de configuration | `/opt/prod.env` | `./.env` |

Exemple de `.env` derrière un proxy d'entreprise :

```dotenv
PROXY_HTTP=http://proxy:8080
PROXY_HTTPS=http://proxy:8080
PROXY_NO=.corp.local,10.0.0.0/8,172.16.0.0/12
NONINTERACTIVE=1
```

> Pas de guillemets ni d'espaces en fin de ligne dans le `.env`.

---

## Déroulement du script

1. **Droits root** : relance automatique avec `sudo -E` si nécessaire
2. **Détection de l'OS** : famille, dépôt Docker et codename
3. **Proxy** : configuré *avant* toute requête réseau
4. **Nettoyage** : suppression des paquets conflictuels
5. **Installation** : clé GPG, dépôt officiel et paquets Docker
6. **Démon Docker** : proxy systemd, DNS, `systemctl enable --now docker`
7. **Conteneurs et builds** : proxy dans `~/.docker/config.json` (root et utilisateur cible)
8. **Groupe docker** : ajout de l'utilisateur (optionnel)
9. **Vérification** : `docker --version`, `docker compose version`, `hello-world`

---

## Proxy : comment ça marche

Docker utilise le proxy à deux endroits distincts, et le script configure les deux.

| Niveau | Sert à | Fichier configuré |
|---|---|---|
| Démon | `docker pull`, accès aux registres | `/etc/systemd/system/docker.service.d/http-proxy.conf` |
| Client | variables injectées dans les conteneurs et les `docker build` | `~/.docker/config.json` |

Pour vérifier :

```bash
# Proxy du démon
systemctl show --property=Environment docker

# Proxy injecté dans les conteneurs
docker run --rm alpine env | grep -i proxy
```

> Les conteneurs utilisent le réseau `172.17.0.0/16` par défaut. Si tes conteneurs communiquent entre eux ou avec des services internes par IP, ajoute les plages concernées à `PROXY_NO`.

---

## Fichiers modifiés

| Fichier | Famille | Sauvegarde |
|---|---|---|
| `/etc/apt/keyrings/docker.asc` | Debian | — |
| `/etc/apt/sources.list.d/docker.list` | Debian | — |
| `/etc/yum.repos.d/docker-ce.repo` | RedHat | — |
| `/etc/dnf/dnf.conf` ou `/etc/yum.conf` (si proxy) | RedHat | `.bak.<timestamp>` |
| `/etc/systemd/system/docker.service.d/http-proxy.conf` (si proxy) | Toutes | — |
| `/etc/docker/daemon.json` (si DNS) | Toutes | `.bak.<timestamp>` |
| `~/.docker/config.json` (si proxy) | Toutes | `.bak.<timestamp>` |

---

## Dépannage

| Problème | Piste |
|---|---|
| `Distribution non supportée` | Vérifie `cat /etc/os-release`. Pour un dérivé Debian, force `DOCKER_CODENAME`. |
| `Codename introuvable` | Relance avec `DOCKER_CODENAME=bookworm` (ou `trixie`, `noble`, `jammy`…). |
| `docker pull` échoue derrière le proxy | Vérifie `systemctl show --property=Environment docker`, puis `systemctl restart docker`. |
| `apt update` échoue dans un `Dockerfile` | Vérifie `~/.docker/config.json` de l'utilisateur qui lance `docker build`. |
| Conflit `containerd.io` / `runc` sur Rocky/Alma | Le script supprime `podman` et `runc`. Vérifie qu'aucun autre paquet ne les réinstalle. |
| Erreur SSL derrière le proxy | Le proxy fait de l'inspection TLS : installe le certificat racine de l'entreprise dans le magasin de l'OS. |
| `permission denied` sur `/var/run/docker.sock` | Reconnecte-toi après l'ajout au groupe `docker`, ou lance `newgrp docker`. |

---

## Sécurité

- **Groupe `docker`** : l'appartenance au groupe `docker` donne des droits équivalents à **root** sur la machine. N'y ajoute que des comptes de confiance.
- **Proxy authentifié** : avec un proxy du type `http://user:mdp@proxy:8080`, les identifiants sont stockés en clair. Ils se retrouvent dans le `.env`, le drop-in systemd, `config.json` et les variables des conteneurs (visibles via `docker inspect`). Utilise un compte de service dédié et protège le `.env` avec `chmod 600`.
- **Ne commite jamais ton `.env`** : ajoute-le au `.gitignore`.

```gitignore
.env
*.bak.*
```

---

## Désinstallation

Le script `uninstall-docker.sh` défait ce qu'a fait `install-docker.sh`. Il lit le même `.env`.

```bash
chmod +x uninstall-docker.sh
sudo ./uninstall-docker.sh                 # interactif, avec confirmation
sudo ./uninstall-docker.sh --yes           # sans question, données conservées
sudo ./uninstall-docker.sh --yes --purge   # sans question, supprime TOUT
```

| Option | Variable | Effet |
|---|---|---|
| `-y`, `--yes` | `NONINTERACTIVE=1` | Aucune confirmation demandée |
| `-p`, `--purge` | `REMOVE_DATA=1` | Supprime `/var/lib/docker` et `/var/lib/containerd` (images, conteneurs, volumes) |
| `-g`, `--group` | `REMOVE_GROUP=1` | Supprime le groupe `docker` |
| `-h`, `--help` | — | Affiche l'aide |

Ce qui est supprimé :

- les services `docker` et `containerd` (arrêtés et désactivés)
- les paquets Docker CE, y compris `docker-ce-rootless-extras`
- le dépôt Docker et sa clé GPG (y compris dans la base RPM)
- le drop-in proxy systemd et `/etc/docker`
- la ligne `proxy=` de `dnf.conf` / `yum.conf`, seulement si elle correspond à `PROXY_HTTP` (sinon le script demande)
- la section `proxies` de `~/.docker/config.json`. Les identifiants de registres (`auths`) sont conservés.

Par défaut, **les données sont conservées**. Sans `--purge`, une réinstallation retrouvera les images et les volumes.

> Sur RedHat, Podman supprimé par `install-docker.sh` n'est pas réinstallé automatiquement : `sudo dnf install podman` si besoin.

---

## Licence

MIT
