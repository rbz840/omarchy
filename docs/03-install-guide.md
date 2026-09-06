# Omarchy ARM64 — Guide d'installation pas-à-pas (Raspberry Pi 5)

> Durée totale : ~30 min (hors build d'image) · Niveau : intermédiaire
> Matériel requis : Raspberry Pi 5 (8 Go recommandé), alimentation officielle 27 W
> (5.1 V / 5 A), carte microSD A2 (≥ 32 Go) **ou** NVMe (via HAT PCIe) **ou** clé
> USB3, câble micro-HDMI, clavier/souris, écran.

---

## 0. Obtenir l'image

Deux options :

### Option A — Télécharger une image pré-construite (recommandé dès disponible)

```bash
# Emplacement des releases du fork :
# https://github.com/rbz840/omarchy/releases
# Fichier attendu : omarchy-arm64-rpi5-YYYYMMDD.img.xz
wget https://github.com/rbz840/omarchy/releases/latest/download/omarchy-arm64-rpi5.img.xz
```

### Option B — Construire l'image vous-même

```bash
git clone https://github.com/rbz840/omarchy.git
cd omarchy
# Sur hôte x86_64 : activer l'émulation aarch64 (une fois)
docker run --privileged --rm tonistiigi/binfmt --install arm64
# Construire (~1 h sur x86_64 émulé, ~40 min natif aarch64)
./build/build.sh --output ./out
# Résultat : ./out/omarchy-arm64-rpi5-YYYYMMDD.img
```

---

## 1. Mettre à jour l'EEPROM (une seule fois, recommandé)

Le bootloader SPI du Pi 5 doit connaître le boot USB/NVMe. Sur une SD avec
Raspberry Pi OS (ou l'outil Raspberry Pi Imager → "Misc utility images" →
"Bootloader"), mettez l'EEPROM à jour vers la version la plus récente (2024+).

Alternative depuis un Linux avec la SD insérée :

```bash
# Vérifier/flasher l'EEPROM de recovery avec l'image "pieeprom" récente :
# https://github.com/raspberrypi/rpi-eeprom/releases
# Suivre la procédure officielle : flasher "recovery.bin" + "pieeprom-*.bin"
# sur une FAT32, insérer la SD, démarrer (LED verte clignote vite), patienter.
```

> Sans cette étape, le boot NVMe/USB peut échouer ; la SD fonctionne toujours.

---

## 2. Flasher l'image

### Avec Raspberry Pi Imager (GUI)

1. *Choose OS* → *Use custom* → sélectionner `omarchy-arm64-rpi5-YYYYMMDD.img`.
2. *Choose Storage* → votre SD/NVMe/USB.
3. *OS Customisation* (roue dentée) : définir hostname, activer SSH, configurer
   le WiFi (SSID + clé) — l'installateur les appliquera au premier boot.
4. *Write*, patienter (~5 min SD, < 1 min NVMe).

### En ligne de commande

```bash
# Identifier votre disque (ATTENTION : dd écrase tout !)
lsblk -d -o NAME,SIZE,MODEL
# Exemple : /dev/sdX (SD via USB), /dev/nvme0n1, /dev/mmcblk0

# Décompresser et flasher
unxz omarchy-arm64-rpi5-YYYYMMDD.img.xz   # (si téléchargée compressée)
sudo dd if=omarchy-arm64-rpi5-YYYYMMDD.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

---

## 3. Premier boot

1. Insérer le média dans le Pi 5, connecter écran (micro-HDMI **port le plus
   proche de l'alimentation** = HDMI0), clavier, réseau Ethernet (optionnel si
   WiFi configuré à l'étape 2), alimentation en dernier.
2. Le boot affiche le rainbow screen court, puis les logs kernel
   (`console=tty1`), puis le service `omarchy-firstboot-pi.service` prend le
   relais :

   - extension automatique de la partition root à 100 % du média,
   - installation des paquets Omarchy ARM64 (pacman, 10–25 min selon média),
   - création de l'utilisateur `omarchy` (mot de passe à définir),
   - agents/thèmes/configs, activation SDDM/NetworkManager/bluetooth,
   - régénération de l'initramfs, reboot automatique.

> **Suivi** : après login console (auto-login root pendant le firstboot), tapez
> `omarchy-firstboot-pi status` ou `journalctl -u omarchy-firstboot-pi -f`.

3. Après le reboot : l'écran de connexion **SDDM** apparaît → session
   **Hyprland (uwsm)** → le desktop Omarchy (barre Quickshell, launcher,
   notifications) se lance.

---

## 4. Post-install (recommandé)

```bash
# Mettre à jour tout le système
sudo pacman -Syu

# Validation matérielle complète (GPU, WiFi, BT, NVMe, audio, thermal...)
sudo /opt/omarchy/tests/validate-pi-hardware.sh

# Régler la zone horaire
sudo timedatectl set-timezone Europe/Paris

# Régler la locale (ex. français)
sudo localectl set-locale fr_FR.UTF-8

# NVMe boot (si OS sur SD mais données sur NVMe) :
# rien à faire — le NVMe apparaît comme /dev/nvme0n1 standard.
```

### Activer le boot NVMe (OS sur NVMe)

Si vous souhaitez déplacer le système sur NVMe : flashez la même image sur le
NVMe, mettez l'EEPROM à jour (étape 1), puis définissez l'ordre de boot :

```bash
# Sur le Pi (après boot SD avec le paquet rpi-eeprom installé) :
sudo rpi-eeprom-config --edit
# Ajouter/modifier :
#   BOOT_ORDER=0xf46   (1=SD, 4=USB, 6=NVMe — priorité de droite à gauche)
sudo reboot
```

Le premier boot sur NVMe refait l'extension rootfs automatiquement
(`omarchy-firstboot-pi` détecte le changement de média).

---

## 5. Dépannage rapide

| Symptôme | Cause probable | Fix |
|---|---|---|
| Écran noir au boot | câble HDMI sur le mauvais port | utiliser le port HDMI0 (près de l'alim) |
| Écran noir persistant | KMS non chargé | vérifier `dtoverlay=vc4-kms-v3d-pi5` dans `/boot/config.txt` |
| Pas de WiFi | firmware absent | `sudo pacman -S firmware-raspberrypi` puis reboot |
| `omarchy-firstboot-pi` échoue | paquet manquant/AUR | `omarchy-firstboot-pi logs` ; corriger ; `omarchy-firstboot-pi rerun` |
| Boot NVMe ignoré | EEPROM vieux ou BOOT_ORDER | étape 1 + `rpi-eeprom-config` |
| ESP corrompu (cmdline.txt/config.txt perdus) | écriture interrompue, FAT défectueux | **auto-réparé au boot** par le hook initramfs `omarchy-pi-esp` (copies vierges embarquées, `root=` réécrit vers le média réel) |
| Hyprland saccadé | pas d'accélération | `ls /dev/dri/renderD*` ; vérifier `mesa`/`vulkan-broadcom` installés |
| Sons absent | pipewire user session | se reconnecter dans la session desktop ; `pactl info` |

Plus d'aide : `docs/04-limitations.md` (limitations connues) et
[`manual/45-troubleshooting.md`](https://github.com/omacom/omarchy/blob/quattro/manual/45-troubleshooting.md) (upstream).
