# Rapport technique — Portage d'Omarchy sur Raspberry Pi 5 (ARM64)

> **Date** : 6 septembre 2026 · **Auteur** : Buffy (agent d'ingénierie) · **Statut** : v1.0
> **Cible** : Raspberry Pi 5 (8 Go), BCM2712, aarch64, EEPROM 2024+, boot device-tree natif
> **Upstream** : [`omacom/omarchy` @ `quattro`](https://github.com/omacom/omarchy) (SHA `adcc96a`)
> **Fork de travail** : [`rbz840/omarchy`](https://github.com/rbz840/omarchy)

---

## Table des matières

1. [Analyse](#1-analyse) — écart x86_64 → ARM64
2. [Stratégie](#2-stratégie) — architecture et décisions
3. [Scripts](#3-scripts) — livrables exécutables
4. [Tests](#4-tests) — plan de validation
5. [Documentation](#5-documentation) — guides et contribution
6. [Conclusion](#6-conclusion)

---

## 1. Analyse

### 1.1 Ce qu'est Omarchy

Omarchy est une distribution « opinionated » construite sur Arch Linux :
Hyprland (Wayland) + Quickshell (barre/shell QML) + uwsm + SDDM, une suite
d'agents CLI (launcher, notifications, capture, thèmes, agents AI), un
installateur ISO archiso x86_64, et des scripts d'adaptation matérielle
(`install/hardware/*` pour ASUS/Dell/Framework/Mac/T2/Surface/Intel/NVIDIA).

### 1.2 Ce qui bloque un boot ARM64 natif

L'analyse (détail complet : [`docs/01-gap-analysis.md`](docs/01-gap-analysis.md))
identifie **cinq fossés structurels** :

| # | Fossé | Composant x86 concerné |
|---|---|---|
| F1 | **ISO vs image brute** — le firmware Pi ne sait pas booter d'ISO9660 | `archiso` releng, ISO hybride |
| F2 | **Bootloader** — pas d'UEFI/BIOS sur Pi 5 en mode DT | `limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync` |
| F3 | **Kernel** — le vanilla Arch `linux` n'a ni V3D stable, ni V4L2-request, ni RP1 à jour | `linux`, `linux-headers` |
| F4 | **Firmware & drivers GPU/vidéo/audio** — tout l'écosystème Intel/NVIDIA/AMD est sans objet | `nvidia-*`, `intel-*`, `vulkan-intel/radeon/asahi`, `sof-firmware`, `thermald`, `vpl-gpu-rt` |
| F5 | **Scripts d'install** — le flux x86 suppose UEFI + ESP + Limine + kernel vanilla | `install/preinstall.sh`, `install/hardware/all.sh`, `install/packages.sh` |

À l'inverse, **la totalité du bureau Omarchy est portable** : Hyprland,
Quickshell, foot, walker, mako, les thèmes, les configs, les agents CLI
(Claude Code/Codex via Node multi-arch) et l'intégralité des outils CLI
(`fd`, `fzf`, `bat`, `eza`, `lazygit`, …) existent en aarch64 sur les repos
Arch Linux ARM ou se compilent depuis l'AUR.

### 1.3 Le point UEFI (décision d'exclusion)

La piste « boot UEFI via EDK2 » ([`worproject/rpi5-uefi`](https://github.com/worproject/rpi5-uefi))
a été **écartée en connaissance de cause** : le projet est officiellement
archivé (notice « End of support »), avec sortie graphique UEFI brisée sur les
Pi 5 stepping D0 et EEPROM récents. Le mode device-tree natif est :

- la seule voie supportée par Raspberry Pi Ltd,
- la seule couvrant **tout** le matériel (V3D, NVMe, WiFi, HDMI, audio),
- celle pour laquelle `linux-rpi` est construit.

Conséquences acceptées (documentées) : pas de Secure Boot, pas de TPM, pas de
chargeur de boot disque — voir [`docs/04-limitations.md`](docs/04-limitations.md).

### 1.4 Matrice de couverture matérielle Pi 5

| Spécificité | Driver/chemin | Couvert par |
|---|---|---|
| GPU VideoCore VI | `v3d` (kernel) + Mesa `v3d`/`v3dv` | `mesa`, `vulkan-broadcom` |
| Décode HEVC/H264 | V4L2 stateless (`rpivid`) | kernel `linux-rpi` + `mpv hwdec=auto-safe` (software decode + GPU compositing ; le hwdec `v4l2request` est absent des ffmpeg/mpv ALARM — vérifié sur les binaires) |
| WiFi CYW43455 | `brcmfmac` + firmware | `firmware-raspberrypi` |
| Bluetooth CYW43455 | `hci_uart`/`btbcm` + `BCM4345C0.hcd` | `firmware-raspberrypi` |
| Ethernet Gigabit | `bcmgenet` (RP1) | kernel `linux-rpi` |
| PCIe NVMe | `brcm-pcie` + `rp1` | kernel `linux-rpi` (DT natif) |
| HDMI 2.1 2× 4K60 | `vc4` KMS | kernel + overlay `vc4-kms-v3d-pi5` |
| USB3 | xHCI via RP1 | kernel `linux-rpi` |
| Cooling | DT thermal + fan PWM firmware | `config.txt` (`dtparam=fan_temp*`) |

---

## 2. Stratégie

Résumé des cinq décisions (détail et alternatives rejetées :
[`docs/02-portage-strategy.md`](docs/02-portage-strategy.md)) :

| # | Décision | Justification courte |
|---|---|---|
| D1 | **Boot DT natif**, pas d'UEFI | rpi5-uefi archivé/cassé sur D0 ; DT = seule voie complète |
| D2 | **Base Arch Linux ARM**, kernel `linux-rpi` | repos matures, kernel Pi maintenu, pacstrap simple |
| D3 | **Livrable `.img`** (GPT: ESP 512M + ext4) ; ISO archiso expérimentale en option | le firmware Pi ne boote pas d'ISO |
| D4 | **Zéro modification d'Omarchy upstream** : ajout de `install/pi/`, `build/`, 2 commandes `bin/`, 1 profil mpv | minimise le coût de maintenance, facilite les merges upstream |
| D5 | **Build croisé Docker/QEMU binfmt** (ou natif aarch64) | buildable partout, sans toolchain croisée à maintenir |

Flux d'installation post-flash :

```
Boot 1 : firstboot-pi.service
  ├─ extension rootfs (growpart + resize2fs)
  ├─ 01-detect          (aarch64 ? Pi 5 ? RAM ?)
  ├─ 02-partition       (fstab UUIDs, ESP)
  ├─ 03-pacstrap        (paquets Omarchy ARM64 via pacman --needed)
  ├─ 04-user            (user omarchy, sudo, dotfiles, services)
  ├─ 05-pi-specific     (WiFi/BT, Vulkan/V3D, HEVC, agents AUR, mpv)
  ├─ 06-post-install    (mkinitcpio -P, sync ESP, enable services)
  └─ reboot → SDDM → Hyprland (uwsm) → Quickshell
```

Chaque étape est **idempotente** (markers dans `/var/lib/omarchy-firstboot-pi/stages/`)
et **journalisée** (`/var/lib/omarchy-firstboot-pi/logs/install.log`).

---

## 3. Scripts

Tous les scripts sont exécutables, commentés, idempotents. Syntaxe vérifiée
(`bash -n`). Arborescence livrée :

```
build/
  build.sh                    Orchestrateur hôte : Docker/Podman aarch64, binfmt,
                              options (--size, --name, --no-iso, --iso-only, --native)
  build-image.sh              Assemblage in-container : truncate → parted → mkfs →
                              pacstrap (repos ALARM) → overlay Omarchy → firstboot →
                              ESP (firmware, kernel_2712.img, initramfs, config.txt)
  Dockerfile                  archlinux:base-devel, platform linux/arm64,
                              clé ALARM importée dans le keyring
  pacman-arm.conf             Repos [core]/[extra]/[alarm]/[aur] → mirror.archlinuxarm.org
  boot/config.txt             armstub8-2712, DTB 2712, kernel_2712.img,
                              dtoverlay=vc4-kms-v3d-pi5, dtparam=fan_temp*, pciex1
  boot/cmdline.txt            root=/dev/mmcblk0p2 rw rootwait console=… plymouth
  rootfs/                     Overlay : service firstboot systemd, fstab template,
                              sysctl zram/réseau, modprobe (blacklist fkms),
                              modules-load (vc4/v3d/rpivid/hci_uart), NM, profile.d,
                              hook initcpio omarchy-pi-esp (attente du média de boot
                              NVMe/USB + auto-réparation de l'ESP : cmdline.txt/
                              config.txt restaurés depuis des copies embarquées
                              dans l'initramfs, root= réécrit vers le média réel)
  packages/                   omarchy-pi5-base.packages, omarchy-pi5-other.packages,
                              aur.txt, drop.txt (traçabilité des exclusions x86)
  archiso/releng-omarchy-aarch64/  Profil ISO expérimental (packages.aarch64, profiledef.sh)
install/
  lib/common.sh               Helpers : logs tee, require_root, is_aarch64/is_rpi5,
                              run_stage (markers + FORCE_STAGE), pacman_install_list
  pi/firstboot-entrypoint.sh  Expand rootfs → 6 stages → disable service → reboot
  pi/01-detect.sh             Architecture, modèle, BCM2712, modules kernel, RAM, média
  pi/02-partition.sh          Vérifie layout, écrit /etc/fstab avec UUIDs réels
  pi/03-pacstrap.sh           pacman -Sy + 2 listes de paquets (--needed, idempotent)
  pi/04-user.sh               User omarchy, sudoers, dotfiles, OMARCHY_PATH, services
  pi/05-pi-specific.sh        Firmware WiFi/BT, Vulkan/V3D, rpivid, mpv.conf,
                              AUR agents (yay as user), fan/NVMe notes
  pi/06-post-install.sh       mkinitcpio -P, sync ESP, enable services, nettoyage sudoers
bin/
  omarchy-hw-raspberrypi5     Détecteur (exit 0/1) — convention omarchy-hw-*
  omarchy-firstboot-pi        status / rerun / logs
config/mpv/mpv.conf           hwdec=auto-safe (HEVC software + GPU ; voir note V4L2-request)
```

### 3.1 Commandes clés (copier-coller)

Construire l'image :

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
git clone https://github.com/rbz840/omarchy.git && cd omarchy
./build/build.sh --output ./out
```

Flasher :

```bash
sudo dd if=out/omarchy-arm64-rpi5-*.img of=/dev/sdX bs=4M conv=fsync status=progress
```

Post-install sur le Pi :

```bash
sudo /opt/omarchy/tests/validate-pi-hardware.sh   # validation matérielle
omarchy-firstboot-pi status                        # état du firstboot
omarchy-firstboot-pi rerun                         # rejouer l'installation
```

---

## 4. Tests

### 4.1 Tests exécutables livrés

| Script | Où | Ce qu'il valide |
|---|---|---|
| `tests/check-pkg-availability.sh` | hôte (réseau) | Chaque paquet des listes existe dans ALARM core/extra/alarm/aur |
| `tests/check-aur-availability.sh` | hôte (réseau) | Chaque candidat AUR a une page AUR vivante |
| `tests/validate-pi-hardware.sh` | **Pi 5** (post-install) | 9 sections : boot/kernel/EEPROM, GPU (DRI, v3d, Vulkan), HEVC (rpivid, V4L2, capacité hwdec mpv), réseau (eth0/wlan0/firmware), BT, stockage (RP1/NVMe/USB3), audio ALSA/PipeWire, thermique, agents Omarchy |
| `tests/verify-image.sh` | hôte (root, loop) | Contenu boot-critique de l'image : kernel_2712.img, config.txt (kernel=), cmdline.txt, DTB bcm2712, overlay V3D, hook omarchy-pi-esp + templates dans l'initramfs |
| `tests/qemu-esp-restore-test.sh` | hôte (QEMU aarch64) | **Bout-en-bout** : boote 2× le kernel+initramfs de l'image sous QEMU, supprime cmdline.txt de l'ESP entre les deux boots, vérifie que le hook le restaure avec root= réécrit vers le vrai médium (/dev/vda2) |
| `tests/make-fixture-image.sh` | hôte (root, loop) | Construit une image synthétique 64 MiB (layout Pi 5 réel, templates + hook du dépôt, cpio newc réel) pour tester le gate en CI — avec variantes négatives `--omit-cmdline/--omit-dtb/--omit-hook` prouvant que le gate échoue bien |

### 4.2 Protocole de validation sur matériel réel

| Test | Commande | Critère PASS |
|---|---|---|
| Boot SD | flash + boot | SDDM affiché ≤ 3 min |
| Boot NVMe | `BOOT_ORDER=0xf46` + reboot | SDDM depuis NVMe |
| GPU | `ls /dev/dri/renderD*` + `vulkaninfo --summary` | nœud render + device Broadcom |
| Fluidité Hyprland | session + `hyprctl dispatch exec alacritty` | ≥ 60 fps ressenti, pas de tearing |
| HEVC | `mpv --hwdec=auto-safe --msg-level=vd=v sample-hevc-1080p.mp4` | lecture fluide ; log `Using hardware decoding` ABSENT (= attendu, software) — un jour : `Using hardware decoding (v4l2request)` si un ffmpeg `--enable-v4l2-request` est installé |
| Ethernet | `ip link show eth0` + ping | link up, DHCP OK |
| WiFi | `nmcli device wifi connect …` | association + internet |
| Bluetooth | `bluetoothctl scan on` | devices visibles |
| NVMe | `ls /dev/nvme0n1` + `hdparm -t` | device présent, débit conforme |
| USB3 | clé USB3 + `hdparm -t` | débit ≈ 300+ MB/s |
| Audio HDMI | `pactl info` + `speaker-test` | sink présent, son audible |
| Agents | `omarchy-bar`, launcher, notifications | process actifs dans la session |
| Thermal | `vcgencmd measure_temp` sous charge | < 80 °C (throttling absent) |

### 4.3 Intégration continue (proposée)

Workflow GitHub Actions sur runner `ubuntu-24.04-arm` : build hebdomadaire de
l'image, checks de disponibilité paquets pré-build, gate de contenu, test QEMU
d'auto-réparation ESP, checksums SHA256 et release (voir
[`docs/05-contributing.md`](docs/05-contributing.md) §4). Le cache pacman
(`actions/cache` autour du build, monté via `build.sh --pkg-cache`) évite de
retélécharger les paquets ALARM inchangés d'une semaine sur l'autre. Les tests
matériels restent manuels (communauté) — un label `tested-on-pi5` est suggéré
pour les PR.

---

## 5. Documentation

| Document | Audience | Contenu |
|---|---|---|
| [`README.md`](README.md) | tous | Vue d'ensemble, install rapide, layout |
| [`docs/01-gap-analysis.md`](docs/01-gap-analysis.md) | contributeurs | Écart complet x86 → ARM64, verdicts composant par composant |
| [`docs/02-portage-strategy.md`](docs/02-portage-strategy.md) | contributeurs | Décisions D1–D5, alternatives rejetées, risques |
| [`docs/03-install-guide.md`](docs/03-install-guide.md) | **utilisateurs** | Pas-à-pas : EEPROM, flash, premier boot, WiFi, NVMe, dépannage |
| [`docs/04-limitations.md`](docs/04-limitations.md) | utilisateurs | Limitations connues + contournements |
| [`docs/05-contributing.md`](docs/05-contributing.md) | contributeurs | Bugs (template), tests matériel, PR, CI, priorités |

---

## 6. Conclusion

Le portage d'Omarchy sur Raspberry Pi 5 est **faisable sans toucher au code
upstream** : l'essentiel du travail consiste à substituer la couche
kernel/firmware/boot (linux-rpi, firmware-raspberrypi, boot DT natif) et à
rerouter les scripts d'installation vers les paquets ARM64 — soit ~1 300 lignes
de bash nouvelles et ~150 lignes de listes de paquets.

L'expérience utilisateur visée (Hyprland fluide via V3D, barre Quickshell,
launcher, notifications, agents CLI, thèmes) est préservée à l'identique. Les
limites matérielles du Pi 5 (pas de Secure Boot/TPM, encodage vidéo CPU,
Vulkan « best effort ») sont documentées avec contournements.

### Prochaines étapes recommandées

1. **Build de référence** sur runner ARM + publication d'une release `.img.xz` + SHA256.
2. **Campagne de tests matériels** (SD/USB/NVMe × rev C1/D0) via la communauté.
3. **Validation agents AUR** un par un (`herdr`, `tensaku`, `ttfx`, …) sur aarch64.
4. **Snapshot boot** : ré-implémentation d'un menu de restauration snapper adapté au boot DT.
5. **PR upstream** : proposition rédigée et prête à ouvrir —
   [`docs/upstream-pr/PROPOSAL.md`](docs/upstream-pr/PROPOSAL.md)
   (détecteur `bin/omarchy-hw-raspberrypi5` + leaf
   `install/hardware/raspberry-pi5.sh`, conventions upstream respectées).
