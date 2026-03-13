#!/usr/bin/env bash

# Va créer un système sur cette base :
# - installation initiale ou réinstallation (/home conservé)
# - partition btrfs chiffrée
# - création de sous-volumes et dossiers permettant l'impermanence
# - optimisations btrfs
# - déploiement d'après un configuration.nix standard, qui importe les .nix customs (téléchargés au préalable depuis github)
# - création des dossiers utilisateur en français

clear
echo "Script déploiement NixOS. Paramétrage - partionnement - installation - setup utilisateur"

# --- 1. VARIABLES ---
echo ""
echo "Quel disque ? :"
lsblk -dn -o NAME,SIZE,MODEL | grep -v "loop"
echo ""
read -p "Nom du disque sur lequel installer (ex: nvme0n1) : " DISK_NAME
echo ""

echo "Quel scenario ? :"
echo "INIT : Efface tout (Partitions, LUKS, Données)"
echo "REINSTALL : Garde @home, recrée @nix, @persist et /boot"
read -p "Choix : " SCENARIO
echo ""

echo "Quelle machine ? (le fichier .nix correspondant doit exister!):"
echo "vm / dell-5485 / r5-3600 / len-x240 / len-l380 / len-idea5 / hp-tp01"
read -p "Choix : " TARGET_HOSTNAME
echo ""

echo "Nom utilisateur ? (doit être déclaré dans les .nix!):"
read -p "Choix : " TARGET_USER
echo ""

echo "Paramétrage du mot de passe pour $TARGET_USER :"
USER_HASH=$(mkpasswd -m yescrypt)

echo -e "\n--- [RÉCAPITULATIF] ---"
echo "DISQUE CIBLE    : $DISK_NAME"
echo "SCENARIO        : $SCENARIO"
echo "HOSTNAME        : $TARGET_HOSTNAME"
echo "USER            : $TARGET_USER"
echo "--------------------------------------"

# Ajouter variables :
# - impermanence oui / non -> montage / en tmpfs + prépas persistance uniquement si oui
# - installation custom (import du .nix hostname décommenté) ou type standard (import du .nix hostname commenté) mais dans ce cas : impermanence + persistences desactivés


read -p "Confirmer le déploiement ? (oui ou non) : " CONFIRM
if [ "$CONFIRM" != "oui" ]; then
    echo "Opération annulée."
    exit 0
fi

# --- 2. PARTITIONNEMENT ---

# Simplification des chemins des périphériques
PART_BTRFS="/dev/mapper/cryptroot"
DISK="/dev/$DISK_NAME"

if [[ $DISK == *"nvme"* || $DISK == *"mmcblk"* ]]; then
    PART_BOOT="${DISK}p1"
    PART_LUKS="${DISK}p2"
else
    PART_BOOT="${DISK}1"
    PART_LUKS="${DISK}2"
fi

# Opérations sur disque
if [ "$SCENARIO" == "INIT" ]; then
    echo "Réinitialisation et repartitionnement du disque"
    sgdisk --zap-all "$DISK"
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"BOOT" "$DISK"
    sgdisk -n 2:0:0      -t 2:8300 -c 2:"SYSTEM" "$DISK"
    udevadm settle # refresh pour propager les références aux partition vers le kernel
    cryptsetup luksFormat --type luks2 "$PART_LUKS"
    cryptsetup open "$PART_LUKS" cryptroot
    mkfs.btrfs -f -L NIXOS /dev/mapper/cryptroot
    mount "$PART_BTRFS" /mnt # Montage temporaire pour créer les subvolumes
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@nix
    btrfs subvolume create /mnt/@persist
    umount /mnt
else
    # Scenario REINSTALL
    echo "Reset des sous-volumes btrfs @nix et @persist"
    cryptsetup open "$PART_LUKS" cryptroot || true #
    mount "$PART_BTRFS" /mnt  # Montage temporaire pour supprimer et recréer les subvolumes
    btrfs subvolume delete /mnt/@nix
    btrfs subvolume delete /mnt/@persist
    btrfs subvolume create /mnt/@nix
    btrfs subvolume create /mnt/@persist
    umount /mnt
fi

echo "Formatage de la partition boot"
mkfs.vfat -F 32 -n BOOT "$PART_BOOT" # format systematique de /boot

# Montage pour installation
echo "Montage des partitions et sous-volumes"
mount -t tmpfs none /mnt -o size=2G,mode=755 # / en tmpfs pour impermanence
mkdir -p /mnt/{boot,nix,persist,home,swap}
mount "$PART_BOOT" "/mnt/boot"
mount "$PART_BTRFS" "/mnt/nix" -o subvol=@nix,noatime,compress=zstd,ssd,discard=async
mount "$PART_BTRFS" "/mnt/persist" -o subvol=@persist,noatime,compress=zstd,ssd,discard=async
mount "$PART_BTRFS" "/mnt/home" -o subvol=@home,noatime,compress=zstd,ssd,discard=async

# Préparation des persistances (la liste doit correspondre avec OS-functions_impermanence.nix.)
# Les bind-mounts et environment.etc ont besoin d'une cible, même si elle est vide, pour créer les liens
echo "Initialisation du volume @persist..."
mkdir -p /mnt/persist/etc/lact
mkdir -p /mnt/persist/etc/NetworkManager/system-connections
mkdir -p /mnt/persist/etc/nixos
mkdir -p /mnt/persist/var/lib/bluetooth
mkdir -p /mnt/persist/var/log
mkdir -p /mnt/persist/var/lib/NetworkManager
mkdir -p /mnt/persist/var/lib/nixos
mkdir -p /mnt/persist/var/lib/cups
mkdir -p /mnt/persist/var/lib/fwupd
mkdir -p /mnt/persist/var/lib/flatpak

echo "Préparation disque terminée."


# --- 3. INSTALLATION ---

echo "Téléchargement du repo des .nix custom"
git clone https://github.com/binnotkari-wq/nixos-dotfiles.git /mnt/home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles # git créé lui-même le dossier cible

echo "Génération de hardware-configuration.nix et configuration.nix"
nixos-generate-config --root /mnt
rm -f /mnt/etc/nixos/configuration.nix
cat <<EOF > "/mnt/etc/nixos/configuration.nix"
# configuration.nix tel que généré lors d'une installation standard de NixOS par 
# l'installateur graphique Calamares, environnement Gnome, unfree Softwares, français. Fonctionnement garanti sur cette base.
# Quelques modifications :
# - suppression de tous les commentaires et déclarations inutilisées.
# - ajout d'une ligne d'import vers les .nix custom (qui sera adaptée automatiquement par le script d'installation)
# - "services.xserver.displayManager.gdm.enable = true;" (syntaxe pas à jour) remplacé par "services.displayManager.gdm.enable = true;"
# - "services.xserver.desktopManager.gnome.enable = true;" (syntaxe pas à jour) remplacé par "services.desktopManager.gnome.enable = true;"
# - "programs.firefox.enable = true;" supprimé (on installera un flatpak)

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      /home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles/$TARGET_HOSTNAME.nix # commenter cette ligne pour retrouver une installation identique à la solution Calamares
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  networking.hostName = "$TARGET_HOSTNAME"; # Define your hostname.

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Paris";

  # Select internationalisation properties.
  i18n.defaultLocale = "fr_FR.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "fr_FR.UTF-8";
    LC_IDENTIFICATION = "fr_FR.UTF-8";
    LC_MEASUREMENT = "fr_FR.UTF-8";
    LC_MONETARY = "fr_FR.UTF-8";
    LC_NAME = "fr_FR.UTF-8";
    LC_NUMERIC = "fr_FR.UTF-8";
    LC_PAPER = "fr_FR.UTF-8";
    LC_TELEPHONE = "fr_FR.UTF-8";
    LC_TIME = "fr_FR.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment.
  services.desktopManager.gnome.enable = true;
  services.displayManager.gdm.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "fr";
    variant = "azerty";
  };

  # Configure console keymap
  console.keyMap = "fr";

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.$TARGET_USER = {
    isNormalUser = true;
    description = "Benoit";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
    #  thunderbird
    ];
  };

  # Install firefox.
  # programs.firefox.enable = true; # décommenter cette ligne pour retrouver une installation identique à la solution Calamares

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "25.11"; # Did you read the comment?
}
EOF
echo "hardware-configuration.nix et configuration.nix générés. Vérifier le contenu"

while true; do
    read -p "Prêt pour lancement installation? (oui) : " ANSWER
    if [ "$ANSWER" = "oui" ]; then
        break
    fi
done
echo "Lancement installation"
nixos-install --no-root-passwd --root /mnt


# --- 4. FINALISATION SETUP UTILISATEUR ---

echo "Injection du mot de passe..."
echo "$TARGET_USER:$USER_HASH" | chroot /mnt /run/current-system/sw/bin/chpasswd -e

echo "Création des dossiers utilisateur en français"
USER-DIRS=("Bureau" "Téléchargements" "Modèles" "Public" "Documents" "Musique" "Images" "Vidéos")
for user-dir in "${USER-DIRS[@]}"; do
    mkdir -p /mnt/home/$TARGET_USER/$user-dir # création répertoires utlisateur en français  (oubli de NixOS)
done

echo "Création d'un user-dirs.dirs en français"
rm -f "/mnt/home/$TARGET_USER/.config/user-dirs.dirs"
mkdir -p "/mnt/home/$TARGET_USER/.config/"
cat <<EOF > "/mnt/home/$TARGET_USER/.config/user-dirs.dirs"
XDG_DESKTOP_DIR="\$HOME/Bureau"
XDG_DOWNLOAD_DIR="\$HOME/Téléchargements"
XDG_TEMPLATES_DIR="\$HOME/Modèles"
XDG_PUBLICSHARE_DIR="\$HOME/Public"
XDG_DOCUMENTS_DIR="\$HOME/Documents"
XDG_MUSIC_DIR="\$HOME/Musique"
XDG_PICTURES_DIR="\$HOME/Images"
XDG_VIDEOS_DIR="\$HOME/Vidéos"
EOF


# Placement des fichiers persistés (la liste doit correspondre avec OS-functions_impermanence.nix)
# Ceux-ci sont sont pour l'instant dans le tmpfs...on les place dans persist avant de reboot, sinon ils seraient perdus.
# Ceux qui n'existent pas encore (il faut démarrer l'OS pour celà), on les crée tout de suite (même si il sont vides),
# pour que les liens soient opérationnels au premier démarrage
mv /mnt/etc/nixos/* /mnt/persist/etc/nixos/
cp -n /mnt/etc/shadow /mnt/persist/etc/shadow
cp -n /mnt/etc/passwd /mnt/persist/etc/passwd
cp -n /mnt/etc/group /mnt/persist/etc/group
cp -n /mnt/etc/subuid /mnt/persist/etc/subuid
cp -n /mnt/etc/subgid /mnt/persist/etc/subgid
touch /mnt/persist/etc/adjtime
touch /mnt/persist/etc/machine-id

# Sécurisation
chown -R 1000:1000 "/mnt/home/$TARGET_USER"
chmod 600 /mnt/persist/etc/shadow
chmod 644 /mnt/persist/etc/passwd


echo "installation terminée, on peut redémarrer. Les partitions sont montées dans /mnt si besoin de contrôle."
