# Omarchy ARM64 — Raspberry Pi 5 Port

> Beautiful, Modern & Opinionated Linux — **sur Raspberry Pi 5 (aarch64)**.
> Fork de portage de [`omacom/omarchy`](https://github.com/omacom/omarchy) vers
> Raspberry Pi 5 (BCM2712), conservant intégralement l'expérience Omarchy :
> Hyprland, Quickshell, thèmes, agents, CLI.

**Rapport technique complet : [`REPORT.md`](REPORT.md)**
**Guide d'installation : [`docs/03-install-guide.md`](docs/03-install-guide.md)**

---

## Qu'est-ce que c'est ?

Omarchy est la distribution "opinionated" de DHH (Basecamp) : Arch + Hyprland +
Quickshell, orientée développeurs, avec ses agents (barre, launcher,
notifications, CLI agents AI). Ce dépôt la rend installable **nativement** sur
Raspberry Pi 5.

Ce qui est conservé à l'identique :

- Hyprland + uwsm + SDDM, barre et shell Quickshell, launcher, notifications,
- tous les thèmes, configs, scripts et agents Omarchy,
- pacman, AUR (yay), la philosophie "rolling release",
- l'identité visuelle et le workflow complets.

Ce qui change pour le Pi 5 :

- kernel **`linux-rpi`** (patches Broadcom downstream : V3D, V4L2-request HEVC,
  GENET Ethernet, PCIe/RP1, WiFi/BT CYW43455) au lieu de `linux`,
- GPU **Vulkan-Broadcom (v3dv)** + Mesa V3D au lieu des drivers Intel/NVIDIA/AMD,
- boot **natif Broadcom** (EEPROM → firmware → kernel_2712.img) au lieu de
  Limine/UEFI — aucune dépendance EDK2 (archivé upstream, cassé sur Pi 5 D0),
- firmwares WiFi/BT/audio Pi via `firmware-raspberrypi` (pas de `sof-firmware`),
- livrable : **image brute `.img`** (le firmware Pi ne boote pas d'ISO).

---

## Installation rapide

```bash
# 1. Télécharger la dernière image (ou la construire, voir docs/)
wget https://github.com/rbz840/omarchy/releases/latest/download/omarchy-arm64-rpi5.img.xz

# 2. Flasher sur SD / USB3 / NVMe
#    (Raspberry Pi Imager, balenaEtcher, ou dd)
sudo dd if=omarchy-arm64-rpi5.img of=/dev/sdX bs=4M conv=fsync status=progress

# 3. Insérer le média dans le Pi 5, connecter écran + clavier, booter.
#    Le premier boot installe tout automatiquement (10–25 min) puis reboote
#    sur le desktop Omarchy.
```

Pas-à-pas complet (EEPROM, NVMe boot, WiFi, dépannage) :
**[`docs/03-install-guide.md`](docs/03-install-guide.md)**

---

## Construire l'image soi-même

```bash
git clone https://github.com/rbz840/omarchy.git
cd omarchy

# Sur hôte x86_64 : émulation aarch64 (une seule fois)
docker run --privileged --rm tonistiigi/binfmt --install arm64

# Build complet (~1 h émulé, ~40 min natif)
./build/build.sh --output ./out
```

Options : `--size 16G`, `--no-iso`, `--native` (Pi 5 lui-même), `--help`.
Détails : `build/build.sh` (en-tête), [`docs/02-portage-strategy.md`](docs/02-portage-strategy.md).

---

## Layout du dépôt (spécifique au port)

```
build/                        Construction de l'image ARM64
  build.sh                    Orchestrateur hôte (Docker/Podman aarch64)
  build-image.sh              Assemblage réel (partitions, pacstrap, ESP)
  Dockerfile                  Conteneur builder aarch64
  pacman-arm.conf             pacman.conf → repos Arch Linux ARM
  boot/config.txt             Config firmware Pi (GPU, fan, KMS)
  boot/cmdline.txt            Ligne de commande kernel
  rootfs/                     Overlay rootfs (fstab, services, sysctl, modprobe)
  packages/                   Listes de paquets ARM64 + exclusions (drop.txt)
  archiso/                    Profil ISO expérimental (netboot, non requis)
install/
  pi/                         Étapes d'install spécifiques Pi (idempotentes)
    firstboot-entrypoint.sh   Orchestrateur du premier boot
    01-detect.sh … 06-post-install.sh
  lib/common.sh               Helpers partagés (logs, markers)
bin/
  omarchy-hw-raspberrypi5     Détecteur hardware (convention omarchy-hw-*)
  omarchy-firstboot-pi        Statut/relance manuelle du firstboot
config/mpv/mpv.conf           Profil V4L2-request (HEVC hw decode)
tests/
  validate-pi-hardware.sh     Validation matérielle sur Pi (GPU, WiFi, NVMe…)
  check-pkg-availability.sh   Vérifie que les listes existent dans ALARM
  check-aur-availability.sh   Vérifie que les paquets AUR existent
docs/
  01-gap-analysis.md          Analyse d'écart x86 → ARM64
  02-portage-strategy.md      Stratégie & décisions d'architecture
  03-install-guide.md         Guide d'installation pas-à-pas
  04-limitations.md           Limitations connues
  05-contributing.md          Contribuer (PR, tests, bugs)
REPORT.md                     Rapport technique structuré (référence)
```

Tout le reste (`bin/`, `config/`, `shell/`, `themes/`, `default/`, `manual/`,
`install/` existants) provient d'**Omarchy upstream sans modification**.

---

## Tests

```bash
# Sur votre machine (vérifie les listes de paquets, réseau requis)
./tests/check-pkg-availability.sh
./tests/check-aur-availability.sh

# Sur le Pi 5, après installation (validation matérielle)
sudo /opt/omarchy/tests/validate-pi-hardware.sh
```

---

## Limitations connues

Pas de Secure Boot ni TPM (firmware Broadcom), pas d'hibernation, encodage
vidéo CPU (décodage HEVC 4K60 matériel OK), Vulkan 1.3 "best effort".
Liste complète et contournements : [`docs/04-limitations.md`](docs/04-limitations.md).

---

## Contribuer

Voir [`docs/05-contributing.md`](docs/05-contributing.md) — les retours de tests
sur matériel réel (surtout Pi 5 rev D0) sont les plus précieux.

## Licence & remerciements

- Omarchy upstream : [`omacom/omarchy`](https://github.com/omacom/omarchy) (MIT) —
  tout le travail desktop est leur mérite.
- Arch Linux ARM ([archlinuxarm.org](https://archlinuxarm.org)) — repos aarch64,
  kernel `linux-rpi`, firmwares.
- Projet Raspberry Pi — firmware, EEPROM, kernel downstream.
