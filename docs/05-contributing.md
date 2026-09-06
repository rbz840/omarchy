# Contribuer au port Omarchy ARM64 (Raspberry Pi 5)

Merci de votre intérêt ! Ce port vit grâce aux tests sur matériel réel.

## 1. Signaler un bug

Ouvrez une issue sur [`rbz840/omarchy`](https://github.com/rbz840/omarchy/issues)
avec :

1. **Modèle exact** : `cat /proc/device-tree/model | tr -d '\0'`
2. **EEPROM** : `rpi-eeprom-update` (version)
3. **Kernel** : `uname -a`
4. **Validation matérielle** : sortie complète de
   `sudo /opt/omarchy/tests/validate-pi-hardware.sh`
5. **Logs firstboot** (si install cassée) :
   `omarchy-firstboot-pi logs` ou `journalctl -u omarchy-firstboot-pi`
6. **Étapes de reproduction** minimales + comportement attendu/observé.

## 2. Tester une image

Chaque release est testable sans compilation. Procédure :

1. Flasher la dernière `.img.xz` (voir `docs/03-install-guide.md` §2),
2. Lancer `sudo /opt/omarchy/tests/validate-pi-hardware.sh`,
3. Copier la sortie dans votre issue/PR,
4. Tester le desktop : Hyprland fluide ? Barre Quickshell ? WiFi/BT ?
   Son HDMI ? Mise en veille ?

Les retours "OK sur rev 1.0 / D0 stepping" sont précieux : le stepping du SoC
(`rpi-eeprom-update`, ou marquage sur le PCB) influe sur le comportement boot.

## 3. Proposer un changement

- **Fork → branche descriptive → PR** (ex. `fix/wifi-d0-nvram`).
- Scripts bash : suivre le style upstream Omarchy
  (`[[ ]]`, 2 espaces, `#!/bin/bash`, pas de hard-wrap dans les docs).
- Toute modification de script d'install doit rester **idempotente**
  (rejouable sans effet de bord).
- Tout nouveau paquet : l'ajouter à `build/packages/*.packages` (repos) ou
  `build/packages/aur.txt` (AUR), et le faire passer
  `tests/check-pkg-availability.sh` + `tests/check-aur-availability.sh`.

### Vérifications avant PR

```bash
# Syntaxe bash de tous les scripts modifiés
shellcheck build/**/*.sh install/**/*.sh tests/*.sh 2>/dev/null || true
for f in $(git diff --name-only --diff-filter=ACMR HEAD | grep '\.sh$'); do bash -n "$f"; done

# Cohérence des listes de paquets (réseau requis)
./tests/check-pkg-availability.sh
./tests/check-aur-availability.sh
```

## 4. Construire & publier une image

Voir `build/build.sh --help`. La **CI hebdomadaire** (`.github/workflows/build-arm64.yml`)
construit l'image sur un runner natif `ubuntu-24.04-arm` tous les lundis à 04:00 UTC
(déclenchement manuel possible via *workflow_dispatch*, avec option de release en
brouillon) et publie :

- une **release GitHub** tagguée `vYYYY.MM.DD` avec l'asset `.img.zst` (zstd -9,
  sous la limite de 2 GiB par fichier) et son `.sha256`,
- un **artefact de workflow** (rétention 14 jours) pour les builds de test.

Le chemin de build est identique à un build local (Docker builder aarch64 natif —
pas d'émulation QEMU), ce qui garantit la reproductibilité CI/local. Pour un
build manuel :

## 5. Zones prioritaires (bon premiers PR)

| Zone | Tâche |
|---|---|
| QEMU boot test | Le hook ESP est couvert bout-en-bout par `tests/qemu-esp-restore-test.sh` (2 boots QEMU, sabotage du cmdline.txt, vérification de la restauration) — il tourne aussi en CI à chaque build ; sur matériel réel, vérifier en plus le boot complet firmware→desktop |
| Gate self-test | Le gate de release est lui-même testé à chaque push : `tests/make-fixture-image.sh` construit une image synthétique 64 MiB (réels templates/hook, cpio newc réel) qui doit PASSER le gate, et 3 variantes `--omit-{cmdline,dtb,hook}` qui doivent l'ÉCHOUER (workflow `test-verify-gate.yml`) |
| WiFi D0 | Le Pi 5 D0 (rev récente) peut exiger un NVRAM txt différent — tester et reporter |
| Snapshots | Re-implémenter `limine-snapper-sync` comme hook `btrfs` + menu boot custom |
| Agents AUR | Vérifier la compilabilité aarch64 de `herdr`, `tensaku`, `ttfx`, etc. |
| Docs | Traductions, captures d'écran du desktop tournant sur Pi 5 |
| **PR upstream** | La proposition pour fusionner le support Pi 5 dans `omacom/omarchy` est prête : [`docs/upstream-pr/PROPOSAL.md`](upstream-pr/PROPOSAL.md) + fichiers candidats (`install/hardware/raspberry-pi5.sh`, `bin/omarchy-hw-raspberrypi5`) |
