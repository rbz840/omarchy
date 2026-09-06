# Omarchy ARM64 — Analyse d'écart (gap analysis) pour Raspberry Pi 5

> Version : 1.0 — 2026-09-06
> Cible : Raspberry Pi 5 (8 Go), BCM2712, aarch64, EEPROM officiel ≥ 2024 (device-tree natif)
> Base analysée : [`omacom/omarchy` @ `quattro`](https://github.com/omacom/omarchy) (arbre SHA `adcc96a`)
> Fork de travail : [`rbz840/omarchy`](https://github.com/rbz840/omarchy)

---

## 1. Méthodologie

L'analyse a porté sur l'arbre complet d'Omarchy : ISO/build, listes de paquets
(`install/*.packages`), scripts d'installation (`install/**/*.sh`), commandes runtime
(`bin/omarchy-*`), configuration desktop (`config/`, `default/`), et documentation.
Chaque composant a été classé selon trois verdicts :

| Verdict | Signification |
|---|---|
| ✅ PORTABLE | Fonctionne tel quel en aarch64 (paquet multi-arch, script arch-agnostique) |
| ⚠️ ADAPTER | Nécessite une adaptation ARM64 documentée dans ce dépôt |
| ❌ REMPLACER/SKIP | Absent d'ARM64 ou sans objet sur Pi 5 — équivalent fourni ou ignoré proprement |

---

## 2. Chaîne de boot — le fossé principal

| # | Composant Omarchy (x86_64) | Statut ARM64 | Équivalent / stratégie Pi 5 |
|---|---|---|---|
| 1 | ISO hybrid BIOS/UEFI via `archiso` | ❌ REMPLACER | Le firmware RPi ne sait pas booter un ISO9660. Livrable principal : **image brute `.img`** (GPT: ESP 512 MiB + root ext4), flashable SD/USB/NVMe. Une ISO archiso aarch64 reste fournie en variante expérimentale (netboot, via U-Boot). |
| 2 | Chargeur : **Limine** (`limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync`) | ❌ REMPLACER | Chaîne native Broadcom : EEPROM (SPI) → `start4d.elf`/firmware → `kernel_2712.img`. Aucun bootloader disque requis. `raspberrypi-bootloader` fournit le firmware boot, `linux-rpi` fournit le kernel + initramfs + `cmdline.txt`/`config.txt`. Snapshots snapper : `limine-snapper-sync` remplacé par hook grub-btrfs-like non prioritaire (voir §5). |
| 3 | Firmware UEFI alternatif (EDK2) | ❌ REJETÉ | `worproject/rpi5-uefi` est **archivé/EOL** (README officiel : plus maintenu, cassé sur les Pi 5 D0 avec EEPROM récents, sortie graphique UEFI brisée). Le device-tree natif est la seule voie supportée et complète (GPU, NVMe, WiFi). |
| 4 | `plymouth` (splash) | ✅ PORTABLE | Fonctionne sur simple framebuffer BCM2712 ; thème conservé. |
| 5 | Partitionnement ISO (GPT + ESP) | ⚠️ ADAPTER | Même layout, mais `config.txt`/`cmdline.txt` sur l'ESP + `bcm2712-rpi-5-b.dtb` (et `bcm2712-rpi-500.dtb`, `bcm2712d.dtb`) + overlays (`vc4-kms-v3d-pi5.dtbo`, `dwc2.dtbo`). |

---

## 3. Kernel & firmware

| # | Composant x86_64 | Statut | Équivalent ARM64 Pi 5 |
|---|---|---|---|
| 1 | `linux` (kernel Arch vanilla) | ❌ REMPLACER | **`linux-rpi`** (Arch Linux ARM, patches downstream RPi). Support Pi 5 ≥ 6.12 ; déploie `kernel_2712.img` + DTB 2712. Alternative suivie : `linux-rpi-16k` (page size 16K, utile pour certaines apps Android/V8), non choisi par défaut. |
| 2 | `linux-headers`, `linux-ptl`, `linux-t2` | ❌ SKIP (x86-only) | `linux-rpi-headers` requis pour DKMS éventuels. |
| 3 | `linux-firmware` (Intel/AMD blobs) | ⚠️ ADAPTER | `linux-firmware` existe en aarch64 mais on **n'en a pas besoin** pour le Pi 5. Les firmwares WiFi/BT CYW43455 viennent de `firmware-raspberrypi` (`brcm/brcmfmac43455-sdio.bin`, `.txt`, `brcmfmac43455-sdio.raspberrypi,5-model-b.txt`, hcd BT). Installer `linux-firmware` reste inoffensif (32 Mo) mais inutile → exclu de l'image par défaut. |
| 4 | `sof-firmware` (Sound Open Firmware, DSP Intel) | ❌ SKIP + neutraliser | Sans objet : audio Pi 5 = I2S vers contrôleur audio onboard/HDMI via `brcm,pwm-audio`/VC4 HDMI (driver ALSA `snd_bcm2835`), pas de DSP SOF. Neutralisé proprement (voir §4.2). |
| 5 | `thermald` (gestion thermique Intel) | ❌ REMPLACER | Pi 5 : gestion thermique par DT (`cpu_thermal`, `polling-delay`, points de rafraîchissement) + `raspberrypi-firmware-dt`/Cooling via `vc4` ; ventilateur officiel PWM contrôlé par le firmware (Option `dtparam=fan_temp0=...`). `power-profiles-daemon` reste fonctionnel (scaling governor). |
| 6 | `intel-media-driver`, `libva-intel-driver`, `libvpl`, `vpl-gpu-rt` | ❌ REMPLACER | Accélération vidéo V4L2 : `v4l2-request` (hevc/h264 décodage via la request API du VideoCore VI, patch RPi inclus dans `linux-rpi`) + `ffmpeg` compilé avec `--enable-v4l2-request` (mainliné dans FFmpeg 8.0 ; l'ffmpeg stock ALARM ne l'active pas — vérifié sur les binaires ; le paquet ALARM `ffmpeg-rpi` est un build 7.1 MMAL pour Pi 3/4/400, sans rapport) ou mpv avec `hwdec=auto-safe` (software decode + GPU). Voir `docs/03-install-guide.md` §dépannage. |
| 7 | `vulkan-intel`, `vulkan-radeon`, `vulkan-asahi`, `nvidia-*` (tous) | ❌ REMPLACER | **`vulkan-broadcom`** (driver V3DV — Vulkan 1.3 sur VideoCore VI) + `broadcom-host` Mesa aux modules `v3d`/`vc4`. |
| 8 | `intel-lpmd`, `intel-ipu7-camera`, `macbook12-spi-driver-dkms`, `apple-bcm-firmware`, `apple-t2-audio-config`, `t2fanrd`, `dell-*`, `tuxedo-drivers`, `yt6801-dkms`, `asusctl`, `qmk-hid`, `broadcom-wl`, `linux-firmware-marvell` | ❌ SKIP | Sans objet sur SoC Broadcom (laptops x86/Mac uniquement). Listés dans `build/packages/drop.txt` pour traçabilité. |

---

## 4. Paquets du bureau Omarchy (`install/omarchy-base.packages`)

### 4.1 ✅ Portable tel quel (extrait vérifié)

`hyprland`, `hyprland-guiutils`, `hyprland-preview-share-picker`, `hyprpicker`,
`hyprsunset`, `quickshell`, `uwsm`, `sddm`, `foot`, `nvim`, `omarchy-nvim`, `lazygit`,
`fd`, `fzf`, `bat`, `eza`, `btop`, `zoxide`, `yazi` (via autres), `grim`, `slurp`,
`wl-clipboard`, `cliphist`, `wtype`, `mpv`, `imv`, `chromium`, `libreoffice-fresh`,
`obs-studio` (CPU encoding), `kdenlive`, `obsidian`, `localserver`, `docker`+compose,
`networkmanager`, `bluez`, `pipewire`, `wireplumber`, `starship`, `tmux`, `mise-bin`,
`nodejs`/`python`/`ruby` toolchains, `noto-fonts*`, `ttf-*`, `yaru-icon-theme`,
`gnome-keyring`, `polkit`, `xdg-desktop-portal-hyprland/gtk`, `tesseract`, `zbar`,
`localsend`, `moonlight-qt`, `kernel-modules-hook`, `zram-generator`, `snapper`,
`btrfs-progs`, `udiskie`, `gvfs-*`, `avahi`, `cups`, `ufw`, `plymouth`.

> Hyprland fonctionne parfaitement sur V3D (Mesa `v3d` driver, GLES 3.1).
> Quickshell : paquet `quickshell` aarch64 disponible sur Arch Linux ARM repos (vérifié dans les repos ALARM `extra`).

### 4.2 ⚠️ À adapter

| Paquet | Problème | Adaptation |
|---|---|---|
| `gpu-screen-recorder` | Dépend de VAAPI/Vulkan des GPU x86 | Skippé par défaut sur Pi ; l'enregistrement passe par `wf-recorder` (déjà présent) ou `obs-studio` en x264 CPU. |
| `sof-firmware` (dep de pipewire conv.) | absent aarch64 | Retiré ; ALSA `snd_bcm2835` suffit. `pipewire-alsa` conservé. |
| `intel-media-driver` (mpv hwaccel) | x86 | `mpv` configuré avec `hwdec=auto-safe` (software decode HEVC/H264 + compositing GPU) via `config/mpv/mpv.conf` (fichier livré). |
| `mkinitcpio` hooks | hooks BIOS/UEFI x86 | Hook initcpio `omarchy-pi-esp` fourni (attente du média de boot + auto-réparation ESP — voir `build/rootfs/usr/lib/initcpio/`). |
| `plymouth` thème + `mkinitcpio` | OK | inchangé. |
| `yay` | OK | Compilé en ~10 min sur Pi 5 8 Go (alternativement `paru`). |

### 4.3 ❌ Absents des repos ARM64 → substituts

| Paquet x86 | Substitute ARM64 | Note |
|---|---|---|
| `omacalc` | conservé si repo ALARM OK ; sinon `qalculate-gtk` | vérifié présent ALARM `extra`. |
| `omawrite`, `omacut`, `ttfx`, `tensaku`, `herdr`, `tobi-try`, `cliamp` | vérifié contre l'AUR le 2026-09-06 : `tensaku`, `herdr`, `cliamp` et `aether` existent ; `omacalc`, `omacut`, `omawrite`, `tobi-try`, `ttfx` sont introuvables (AUR + repos ALARM) → retirés, tracés dans `build/packages/drop.txt`. |
| `qemu-user-static-binfmt` | `qemu-user-static` (aarch64 natif) → utile seulement pour cross; skippé par défaut | voir `docs/03-tests-validation.md`. |
| `dotnet-runtime` | présent en aarch64 (repo `extra`) | ok. |
| `postgresql-libs`, `mariadb-libs` | aarch64 OK | ok. |
| `linux-lts*` mentions | remplacé par `linux-rpi` | — |

---

## 5. Composants « agents » et shell Omarchy

| Composant | Fichiers | Statut | Adaptation |
|---|---|---|---|
| Barre Quickshell | `shell/` (QML), `bin/omarchy-bar` | ✅ PORTABLE | QML interprété ; Quickshell aarch64. Consommation ~80 Mo — OK sur 8 Go. |
| Launcher (walker/fuzzel) | `bin/omarchy-launch-*`, `config/walker/` | ✅ PORTABLE | inchangé. |
| Notifications (mako/dunst) | `bin/omarchy-notification-send` | ✅ PORTABLE | inchangé. |
| Agent CLI / usage | `bin/omarchy-agent*`, `bin/omarchy-default-agent` (claude, codex, fireworks) | ⚠️ ADAPTER | Les binaires Node de Claude Code/Codex sont multi-arch (node aarch64 OK). `bin/omarchy-agent-usage-*` : scripts bash purs → portable. |
| Idle/screensaver (hypridle) | `bin/omarchy-*idle*` | ✅ PORTABLE | inchangé. |
| Brightness | `bin/omarchy-brightness-display` | ⚠️ ADAPTER | Pas de backlight laptop sur Pi 5 HDMI → le script doit détecter l'absence de `/sys/class/backlight` et no-op proprement (déjà partiellement le cas ; hook `bin/omarchy-hw-raspberrypi5` fourni pour le déclarer). |
| Hibernation | `bin/omarchy-hibernation-*` | ❌ DISABLED | Pas de swap persistant fiable sur SD par défaut ; hibernation désactivée via `omarchy-hw-raspberrypi5` (exit 1 sur `--hibernation-available`). |
| Battery | `bin/omarchy-battery-*` | ✅ no-op | Pas de batterie ; `omarchy-battery-present` exit 1 → la barre masque l'icône (comportement existant). |
| Screenshots | `grim`/`slurp` | ✅ PORTABLE | inchangé. |
| Theming | `themes/`, `omarchy-theme-*` | ✅ PORTABLE | inchangé. |

---

## 6. Scripts d'installation Omarchy — points de modification

| Script | Modification ARM64 |
|---|---|
| `install/preinstall.sh` (ISO) | Détection `[[ $(uname -m) == aarch64 ]]` → route vers le flux Pi (`install/pi/*`). |
| `install/config/all.sh` | Sur Pi : sauter `nvidia.sh`, `vulkan.sh` (x86), `intel/*`, `asus-*`, `dell-*`, `framework*`, `apple/*`, `surface`, `fix-yt6801`. Garder `network.sh`, `set-wireless-regdom.sh`, `bluetooth.sh`, `speaker-tuning.sh` (no-op sans tuning), `snapper.sh`, `locate.sh`, `docker.sh`. |
| `install/packages.sh` | Utiliser `build/packages/*.packages` spécifiques ARM64 (livrés) au lieu d'installer `linux`+`linux-firmware`+`sof-firmware`+drivers x86. |
| `install/post-install/*` | Ajouter les étapes `install/pi/06-post-install.sh` (mkinitcpio `-P`, sync ESP, services) et le service firstboot `build/rootfs/etc/systemd/system/omarchy-firstboot-pi.service`. |
| `install/login/*` (SDDM/uwsm) | inchangé. |
| `install/provisioning/*` | inchangé (utilisateur, dotfiles, agents CLI). |

---

## 7. Matrice matérielle Pi 5 — couverture des spécificités

| Spécificité Pi 5 | Composant driver | Statut de couverture du port | Test |
|---|---|---|---|
| VideoCore VI (V3D) | Mesa `v3d` + kernel `v3d`/`vc4` (KMS) | ✅ via `vulkan-broadcom` + `mesa` | `docs/03-tests-validation.md` §T-GPU |
| Codec H.265 (HEVC) | V4L2 stateless decoder (rpivid, kernel linux-rpi) | ✅ décodage logiciel HEVC/H264 + compositing GPU (mpv `hwdec=auto-safe` + `vo=gpu`) ; hw complet nécessite un ffmpeg compilé `--enable-v4l2-request` (mainliné dans FFmpeg 8.0 — l'ffmpeg ALARM 9.0.1 ne l'active pas, vérifié sur les binaires ; `ffmpeg-rpi` ALARM = build 7.1 MMAL pour Pi 3/4/400, aucun paquet ALARM ne le dépend) | §T-VIDEO |
| WiFi CYW43455 | `brcmfmac` + firmware `firmware-raspberrypi` | ✅ | §T-NET |
| Bluetooth CYW43455 | `btusb` + `BCM4345C0.hcd` + `uart` | ✅ (overlay `disable-bt` off) | §T-NET |
| Ethernet Gigabit | `bcmgenet` (RP1) | ✅ | §T-NET |
| PCIe NVMe Gen2/Gen3 | `brcm-pcie` + `rp1` | ✅ (DT natif) | §T-STORAGE |
| HDMI 2.1 (2× 4K60) | `vc4` KMS + `v3d` | ✅ | §T-GPU |
| USB3 (via RP1) | `xhci-pci`/`dwc3` RP1 | ✅ | §T-STORAGE |
| Cooling actif/passif | DT `cpu_thermal` + firmware fan | ✅ (`dtparam` config.txt) | §T-THERMAL |
| RTC (PCF85063) | `rtc-pcf85063` | ✅ | §T-MISC |
| PMIC (TPS65959) | `tps6598x`/`raspberrypi-pmic` | ✅ | §T-MISC |

---

## 8. Synthèse — surface de code à produire

| Artefact | Rôle | Taille estimée |
|---|---|---|
| `build/Dockerfile` + `build/build.sh` | Image brute aarch64 bootable Pi 5 | ~350 lignes bash |
| `build/packages/*.packages` + `drop.txt` | Listes ARM64 + exclusions | ~150 lignes |
| `install/pi/*.sh` (6 étapes) | Détection, partitionnement, pacstrap, Pi-specific, user, post-install | ~600 lignes bash |
| `build/boot/config.txt` + `cmdline.txt` | Configuration firmware boot RPi | ~60 lignes |
| `build/archiso/releng-omarchy-aarch64/` | Variante ISO netboot expérimentale | ~120 lignes |
| `tests/` | Vérification de paquets + validation hardware sur Pi | ~250 lignes |
| `docs/` + `README.md` + `REPORT.md` | Documentation | — |
