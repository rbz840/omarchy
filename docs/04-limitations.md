# Omarchy ARM64 — Limitations connues (Raspberry Pi 5)

> État au 2026-09-06. Cette liste évolue : les corrections apportées par les
> mises à jour du kernel `linux-rpi`, de Mesa (v3d/v3dv) et du firmware
> Broadcom peuvent en retirer certaines.

---

## 1. Chaîne de boot

| Limitation | Détail | Contournement |
|---|---|---|
| Pas de Secure Boot | Le firmware Broadcom ne signe pas les kernels ; EDK2/UEFI (qui l'aurait permis) est archivé/cassé sur Pi 5 D0 | Aucun. Ne pas stocker de secrets sensibles non chiffrés |
| Pas de TPM | Aucun TPM sur le Pi 5 | Vérifications d'intégrité via dm-verity (non fourni) |
| Pas de bootloader disque (Limine/GRUB/systemd-boot) | Le firmware boot `kernel_2712.img` directement | Mises à jour kernel = copie sur l'ESP (automatique via `/boot` unique) |
| Snapshots btrfs non bootables depuis le menu | `limine-snapper-sync` (upstream) n'existe pas pour ce boot chain | Snapshots restaurables manuellement (`snapper rollback` + copie noyau) ; work non prioritaire |
| Hibernation indisponible | Pas de swap persistant fiable sur SD/NVMe sans compromis | `zram` seulement ; `systemctl hibernate` désactivé |

## 2. GPU / vidéo

| Limitation | Détail | Contournement |
|---|---|---|
| Vulkan 1.3 « best effort » | v3dv est conforme à ~1.3 mais certaines extensions manquent | Apps Vulkan exigeantes (DXVK, certains émulateurs) : tester au cas par cas |
| H.264 encode non accéléré | VideoCore VI décode H.264/HEVC mais l'encodage HW n'est pas exposé en V4L2 | Encodage CPU (x264) — suffisant pour capture 1080p sur Pi 5 8 Go |
| HEVC 4K HDR → limites | Le décodeur HEVC gère 4K60 mais le pipeline d'affichage HDR est restreint (KMS) | Contenu SDR OK ; HDR à éviter |
| `gpu-screen-recorder` inutilisable | Repose sur VAAPI/NVENC | Utiliser `wf-recorder` ou OBS (x264) |

## 3. Périphériques

| Limitation | Détail | Contournement |
|---|---|---|
| Bluetooth audio: A2DP après reprise veille | CYW43455 parfois dé-sync après sleep | `systemctl restart bluetooth` (script fourni dans le hook suspend) |
| Pas de caméra CSI par défaut | `rp1_cfe` chargé mais pipeline libcamera non configuré | `pacman -S libcamera` + config par app |
| Ventilateur boîtier tiers (non-PWM) | Contrôlé par le firmware seulement si PWM officiel | Ventilateurs 5V always-on, ou `pwm-fan` DT overlay custom |
| RTC sans pile | L'horloge perdra l'heure hors tension | `systemd-timesyncd`/chrony via réseau |
| Double écran HDMI 4K60 simultané | Le V3D + KMS gère 2×4K60 mais certaines composites limitent la cadence | Réduire à 4K30 sur le second écran si besoin |

## 4. Paquets & agents

| Limitation | Détail | Contournement |
|---|---|---|
| Certains agents AUR lents à compiler | Chromium, Electron, Rust sur 4×A76 | `zram` actif ; build nocturne ; alternatives binaires quand dispo |
| `qemu-user-static-binfmt` inutile en natif | Sert uniquement à l'émulation croisée | Peut être désinstallé sans effet |
| `docker` images x86_64 | Les images Docker x86 tournent via QEMU (binfmt) — lent | Préférer des images arm64 (la plupart des images officielles sont multi-arch) |
| Steam / gaming x86 | Pas d'executable x86 natif | Box86/Box64 non fournis ; gaming retro via `omarchy-games-retro-install` (émus ARM) |

## 5. Build & CI

| Limitation | Détail | Contournement |
|---|---|---|
| Build Docker émulé lent (~1 h) | QEMU sur x86_64 pour tout le pacstrap | Build natif aarch64 (`--native`) ou runner ARM CI (GitHub ARM runners) |
| Pas de signature GPG de l'image | Le build n'est pas reproductible bit-à-bit | Publier SHA256 ; à terme, reproducible-builds sur l'arbre |
| Miroir ALARM pas toujours à l'heure | Paquets parfois en retard vs Arch x86 | Patience ; miroirs secondaires configurables dans `build/pacman-arm.conf` |
