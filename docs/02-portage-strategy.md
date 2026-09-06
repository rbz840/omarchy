# Omarchy ARM64 — Stratégie de portage pour Raspberry Pi 5

> Version : 1.0 — 2026-09-06
> Décisions structurantes et architecture de la solution.

---

## 1. Décisions d'architecture

### D1 — Boot natif device-tree, pas d'UEFI

Le portage utilise la **chaîne de boot Broadcom native** :

```
EEPROM SPI (bootloader RPi, 2024+)
   └─ charge start.elf / start4d.elf (VideoCore firmware) depuis l'ESP (FAT32)
        └─ lit config.txt + bcm2712-rpi-5-b.dtb
             └─ charge kernel_2712.img (linux-rpi) + initramfs-linux-rpi.img
                  └─ kernel démarre avec cmdline.txt, DT fourni par le firmware
```

**Pourquoi pas UEFI (EDK2)** : le port `worproject/rpi5-uefi` est archivé (2025) et
cassé sur les Pi 5 stepping D0 avec les EEPROM récents (sortie graphique UEFI brisée).
Le device-tree natif est la seule voie complète : GPU V3D, NVMe, WiFi, HDMI, tous
fonctionnels. Le kernel `linux-rpi` est construit pour ce mode (DTB 2712 fourni par
`raspberrypi-bootloader`, overlay `vc4-kms-v3d-pi5`).

Conséquences acceptées (voir `docs/04-limitations.md`) : pas de Secure Boot, pas de
TPM, pas de `systemd-boot`/GRUB, boot géré par `config.txt` sur l'ESP.

### D2 — Base « Arch Linux ARM » (repos ALARM), kernel `linux-rpi`

Deux options existaient :

| Option | Pour | Contre | Verdict |
|---|---|---|---|
| A. Arch Linux ARM (archlinuxarm.org) | repos stables depuis 2009, kernel `linux-rpi` maintenu, `firmware-raspberrypi` + `raspberrypi-bootloader` dédiés, pacstrap simple | miroirs séparés d'Arch, pas de signature Arch officielle | ✅ **CHOISI** |
| B. Port Arch Linux aarch64 non officiel (drzee.net, ARMv8.2-only) | paquets plus récents, ARMv8.2 tuning | repos non officiels ARMv8.2-only (Pi 4 cassé), kernel Pi via repo `forge` moins intégré, contrats de support faibles | réservé comme source de paquets ad hoc |

Le kernel `linux-rpi` intègre les patches Broadcom downstream (V3D, V4L2-request,
GENET, PCIe, RP1, DWC3, RTC, PMIC) — exactement ce dont Omarchy a besoin, sans
patcher quoi que ce soit nous-mêmes.

### D3 — Livrable principal : image brute `.img` (pas d'ISO)

Le firmware RPi ne boot pas d'ISO9660. Le livrable principal est
`omarchy-arm64-rpi5-YYYYMMDD.img` (image GPT) :

| Partition | Taille | FS | Contenu |
|---|---|---|---|
| 1 | 512 MiB | FAT32 (ESP) | firmware boot RPi (`start.elf`, `config.txt`, DTB, overlays), `kernel_2712.img`, initramfs, `cmdline.txt` |
| 2 | reste | ext4 | rootfs Omarchy complet (paquets, agents, thèmes, configs) |

Flash : `dd`/balenaEtcher/Raspberry Pi Imager sur **SD, USB3 ou NVMe** — la même
image fonctionne sur les trois (root attendu en `/dev/mmcblk0p2`, résolu par UUID
au premier boot ; voir `install/pi/03-pacstrap.sh`).

Une **ISO archiso aarch64** (profil `releng-omarchy-aarch64`) est fournie en
variante expérimentale pour l'installation réseau via U-Boot/`booti` — non requise
par le flux principal.

### D4 — Conservation maximale de l'identité Omarchy

Le port **n'édite pas le code Omarchy upstream**. Il ajoute :

- un **dossier `install/pi/`** (étapes d'install spécifiques Pi, appelées depuis
  l'orchestrateur),
- un **dossier `build/`** (production d'image),
- deux **commandes runtime** : `bin/omarchy-hw-raspberrypi5` (détecteur hardware,
  même convention que `omarchy-hw-*`) et `bin/omarchy-firstboot-pi` (service
  d'extension rootfs au premier boot),
- un **profil mpv** ARM (`config/mpv/mpv.conf`) pour le décodage V4L2-request,
- les listes de paquets ARM (`build/packages/`).

Tous les agents Omarchy (barre Quickshell, launcher, notifications, thèmes, agents
CLI, mise à jour) sont installés depuis les repos ALARM/AUR sans modification.

### D5 — Construction croisée via Docker (QEMU binfmt)

Le build s'exécute sur un hôte x86_64 (ou natif aarch64) dans un conteneur Docker
multi-arch (image `archlinux:base-devel` aarch64 via `qemu-user-static` binfmt).
Le script `build/build.sh` :

1. vérifie/crée le buildx builder multi-arch,
2. monte `pacman.conf` ARM (repos ALARM),
3. construit le rootfs par `pacstrap` dans le conteneur aarch64,
4. assemble l'image (partitions, mkfs, rsync du rootfs, fichiers boot RPi),
5. (optionnel) génère l'ISO archiso expérimentale.

Un build natif sur Pi 5 lui-même est également supporté (`--native`) — plus lent
(~40 min) mais sans dépendance Docker/QEMU.

---

## 2. Flux d'installation (post-flash, sur le Pi)

```
Boot 1 : kernel + initramfs (rootfs squashé sur partition 2 ext4)
   └─ systemd service oneshot omarchy-firstboot-pi.service
        ├─ étend la partition 2 à 100% du disque (growpart)
        ├─ resize2fs
        ├─ applique configs Pi (config.txt, fstab, locale, hostname)
        └─ déclenche l'orchestrateur Omarchy : install/pi/install-all.sh
             ├─ 01-detect.sh    → arme = aarch64 ? BCM2712 présent ?
             ├─ 02-partition.sh → partitionnement (déjà fait, idempotent)
             ├─ 03-pacstrap.sh      → paquets Omarchy ARM64 (pacman --needed, idempotent)
             ├─ 04-user.sh          → utilisateur Omarchy, sudo, dotfiles, services
             ├─ 05-pi-specific.sh   → WiFi/BT firmware, V3D/Vulkan, V4L2 HEVC, agents AUR
             └─ 06-post-install.sh  → mkinitcpio -P, sync ESP, enable services, reboot
```

> **Idempotence** : chaque étape est rejouable (`systemd` `RemainAfterExit=no`,
> guards sur fichiers déjà présents, `pacman` no-op si déjà installé).

---

## 3. Gestion des paquets x86-only

Voir `docs/01-gap-analysis.md` §3, §4, §6 pour la liste complète. Résumé :

| Catégorie | Traitement |
|---|---|
| Kernel/firmware x86 (`linux`, `linux-firmware` x86 blobs, `sof-firmware`, `thermald`, `intel-*`, `nvidia-*`) | **Remplacés** par `linux-rpi`, `firmware-raspberrypi`, `raspberrypi-bootloader`, `vulkan-broadcom`, `power-profiles-daemon` |
| Laptops x86/Mac (`asus*`, `dell-*`, `apple-*`, `surface`, `t2*`, `tuxedo-*`, `framework*`, `broadcom-wl`, `intel-ipu7`) | **Skippés** (listés dans `build/packages/drop.txt`) |
| Paquets Omarchy runtime (Hyprland, Quickshell, agents) | **Conservés** — tous disponibles en aarch64 (ALARM extra / AUR) |
| Accélération vidéo x86 (VAAPI/VPL) | **Adaptée** : HEVC/H264 décodés en logiciel + compositing GPU (mpv `hwdec=auto-safe` + `vo=gpu`) ; le chemin V4L2-request (`rpivid`) est prêt côté kernel mais aucun ffmpeg/mpv empaqueté ALARM n'active le hwdec `v4l2request` (vérifié sur les binaires 2026-09-06) — un ffmpeg compilé `--enable-v4l2-request` (mainliné FFmpeg 8.0) restaure le décodage matériel |

Les listes source de vérité sont :

- `build/packages/omarchy-pi5-base.packages` — paquets bureau + système Pi (remplace `install/omarchy-base.packages` pour l'image Pi)
- `build/packages/omarchy-pi5-other.packages` — remplace `install/omarchy-other.packages`
- `build/packages/aur.txt` — paquets AUR à compiler (agents Omarchy absents des repos ALARM)
- `build/packages/drop.txt` — exclusions explicites (traçabilité)

---

## 4. Choix non faits (et pourquoi)

| Option rejetée | Raison |
|---|---|
| UEFI (EDK2) comme voie principale | Firmware archivé, cassé sur D0 ; DT natif plus complet et supporté |
| Kernel mainline vanilla (`linux-aarch64`) | Patches RPi manquants (V3D stable, V4L2-request, RP1 récents) → Hyprland non fluide, HEVC non décodé |
| Bootloader GRUB/systemd-boot/Limine sur l'ESP | Le firmware Broadcom ne les exécute pas (pas d'UEFI) ; Limine est le bootloader upstream Omarchy x86 — remplacé ici par le firmware natif |
| Base Debian/RPi OS | Casserait l'identité Arch + pacman + AUR d'Omarchy |
| 16K page size (`linux-rpi-16k`) | Certains binaires pré-compilés (Chromium, Steam runtime) cassent sur 16K ; 4K par défaut = meilleure compat |

---

## 5. Risques & mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| `linux-rpi` régresse sur un upgrade | boot cassé | `IgnorePkg` optionnel documenté ; snapshots btrfs/snapper ; images datées |
| Paquet AUR Omarchy non compilable aarch64 | agent absent | `build/packages/aur.txt` vérifié par `tests/check-aur-availability.sh` ; fallback documenté dans `docs/04-limitations.md` |
| RAM 8 Go insuffisante pour compile lourde (rust, chromium) | build AUR lent/échec | `zram-generator` actif par défaut (4 Go zram) ; cross-build Docker documenté |
| Firmware EEPROM Pi trop vieux pour boot USB/NVMe | boot impossible | Procédure de mise à jour EEPROM via Raspberry Pi Imager (docs/README) |
| V3D Vulkan (v3dv) instable sur certaines apps | crash apps 3D | Fallback GL (GLES) par défaut dans Hyprland ; variable d'env documentée |
| Quickshell change d'API upstream | barre cassée | Pinné via `omarchy-pkg-add` + note de version ; suivi upstream Omarchy |
