#!/usr/bin/env bash
set -euo pipefail
clear

echo "Script déploiement NixOS. Paramétrage - partionnement - installation - setup utilisateur"

# =============================================================================
# FONCTION LOGIQUE
# =============================================================================

executer_logique() {

# --- 1. PARAMETRES ---

initialiser_variable_par_defaut
choisir_disque
choisir_scenario
choisir_customisation
choisir_impermanence
choisir_machine
definir_utilisateur
afficher_recapitulatif
attendre_confirmation


# --- 2. PARTITIONNEMENT ---

unifier_chemins_partitions

if [ "$SCENARIO" = "INIT" ]; then
    detruire_table_partitions
    creer_nouvelles_partitions
    chiffrer_partition_LUKS
    ouvrir_partition_LUKS
    formater_volume_btrfs
    monter_volume_btrfs # Montage temporaire pour créer les sous-volumes
    creer_sous_volumes_nix_home
    if [ "$IMPERMANENCE" = "oui" ]; then
        creer_sous_volume_persist
    else
        creer_sous_volume_sysroot
    fi
fi

if [ "$SCENARIO" = "REINSTALL" ]; then
    ouvrir_partition_LUKS
    monter_volume_btrfs
    reset_sous_volume_nix
    if [ "$IMPERMANENCE" = "oui" ]; then
        reset_sous_volumes_persist
    else
        reset_sous_volume_sysroot
    fi
fi

formater_partition_boot
finaliser_partionnement

if [ "$IMPERMANENCE" = "oui" ]; then
    monter_tmpfs_sysroot
    monter_sous_volume_persist
    creer_dossiers_impermanence
else
    monter_sous_volume_sysroot
fi

monter_sous_volumes_nix_home
monter_partition_boot

echo "Préparation disque terminée."


# --- 3. INSTALLATION ---

echo "Mise en place des fichiers .nix"
nixos-generate-config --root /mnt

if [ "$CUSTOMISATION_NIXOS" = "oui" ]; then
    telecharger_dotfiles_nix
    definir_variables_custom
else
    definir_variables_origine
fi

if [ "$IMPERMANENCE" = "oui" ]; then
    definir_imports_nix_impermanence
else
    definir_imports_nix_stateless
fi

generer_configuration_nix

echo "Fichiers .nix en place."
attendre_confirmation "Après contrôle du contenu des .nix : lancer nixos-install ?"

echo "Lancement installation"
nixos-install --no-root-passwd --root /mnt


# --- 4. FINALISATION SETUP UTILISATEUR ---

echo "Injection du mot de passe..."
echo "$TARGET_USER:$USER_HASH" | chroot /mnt /run/current-system/sw/bin/chpasswd -e

echo "Création des dossiers utilisateur en français"
creer_dossiers_utilisateur


# --- 5. SECURISATION SYSTEME ---

if [ "$IMPERMANENCE" = "oui" ]; then
    placer_fichiers_impermanence
fi

traiter_permissions

echo "installation terminée, on peut redémarrer. Les partitions sont montées dans /mnt si besoin de contrôle."
}


# =============================================================================
# FONCTIONS DE PARAMETRAGE
# =============================================================================

initialiser_variable_par_defaut() {
    DISK_NAME=""
    SCENARIO=""
    CUSTOMISATION_NIXOS=""
    IMPERMANENCE=""
    TARGET_HOSTNAME=""
    TARGET_USER=""
    USER_HASH=""
    LUKS_UUID=""
    PART_BOOT=""
    PART_LUKS=""
    IMPORT_MACHINE_NIX=""
    FIREFOX=""
}

choisir_disque() {
    DISK_NAME=""
    lsblk -dn -o NAME,SIZE,MODEL | grep -v loop
    echo ""
    # Tant que le disque n'existe pas dans /dev/, on redemande
    while [[ ! -b "/dev/$DISK_NAME" || -z "$DISK_NAME" ]]; do
	read -rp "Disque cible (ex: nvme0n1) : "    DISK_NAME
	if [[ ! -b "/dev/$DISK_NAME" ]]; then
	    echo "❌ Erreur : /dev/$DISK_NAME est introuvable."
	fi
    done
}

choisir_scenario() {
    SCENARIO=""
    until [[ "$SCENARIO" == "INIT" || "$SCENARIO" == "REINSTALL" ]]; do
        echo "  INIT      : efface tout"
        echo "  REINSTALL : conserve @home"
        read -rp "Scénario (INIT/REINSTALL) : " SCENARIO
    done
}

choisir_customisation() {
    CUSTOMISATION_NIXOS=""
    until [[ "$CUSTOMISATION_NIXOS" == "oui" || "$CUSTOMISATION_NIXOS" == "non" ]]; do
        echo "  Attention, la personnalisation de Nixos est un prérequis à l'impermanence."
        read -rp "Customisation Nixos? (oui/non) : " CUSTOMISATION_NIXOS
    done
}

choisir_impermanence() {
    if [ "$CUSTOMISATION_NIXOS" = "oui" ]; then
	IMPERMANENCE=""
	until [[ "$IMPERMANENCE" == "oui" || "$IMPERMANENCE" == "non" ]]; do
	    echo "  / en tmpfs, /persist stocke les fichiers persistés"
	    read -rp "Impermanence? (oui/non) : " IMPERMANENCE
	done
    fi
}

choisir_machine() {
    echo "  vm / dell-5485 / r5-3600 / len-x240 / len-l380 / len-idea5 / hp-tp01"
    read -rp "Machine : "                  TARGET_HOSTNAME
}

definir_utilisateur() {
    read -rp "Utilisateur : "                       TARGET_USER
    echo "  Mot de passe pour $TARGET_USER :"
    USER_HASH=$(mkpasswd -m yescrypt)
}

afficher_recapitulatif() {
    echo ""
    printf "  Disque : %s | Scénario : %s | Impermanence : %s | Personnalisation : %s |  Host : %s | User : %s\n" \
	    "$DISK_NAME" "$SCENARIO" "$CUSTOMISATION_NIXOS" "$IMPERMANENCE" "$TARGET_HOSTNAME" "$TARGET_USER"
}


# =============================================================================
# FONCTIONS DISQUE : BASE
# =============================================================================

detruire_table_partitions() {
    echo "Réinitialisation et repartitionnement du disque"
    echo "Destruction et recréation de la table des partition (GPT)"
    sgdisk --zap-all "/dev/$DISK_NAME"
}

creer_nouvelles_partitions() {
    echo "Création des partitions (EFI et système)"
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"BOOT" "/dev/$DISK_NAME"
    sgdisk -n 2:0:0      -t 2:8300 -c 2:"SYSTEM" "/dev/$DISK_NAME"
}

chiffrer_partition_LUKS() {
    echo "Encryption de la partition système (LUKS2)"
    cryptsetup luksFormat --type luks2 "$PART_LUKS"
}

ouvrir_partition_LUKS() {
    cryptsetup open "$PART_LUKS" cryptroot
}

formater_volume_btrfs() {
    mkfs.btrfs -f -L NIXOS /dev/mapper/cryptroot
}

monter_volume_btrfs() {
    mount /dev/mapper/cryptroot /mnt 
}

creer_sous_volumes_nix_home() {
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@nix
}

creer_sous_volume_sysroot() {
    btrfs subvolume create /mnt/@
}

reset_sous_volume_nix() {
    btrfs subvolume delete /mnt/@nix
    btrfs subvolume create /mnt/@nix
}

reset_sous_volume_sysroot() {
    btrfs subvolume delete /mnt/@
    btrfs subvolume create /mnt/@
}

formater_partition_boot() {
    echo "Formatage de la partition boot"
    mkfs.vfat -F 32 -n BOOT "$PART_BOOT" # format systematique de /boot
}

finaliser_partionnement() {
    umount /mnt
    udevadm settle # refresh pour propager les références aux partition vers le kernel
}

monter_sous_volume_sysroot() {
    mount /dev/mapper/cryptroot "/mnt/" -o subvol=@,noatime,compress=zstd,ssd,discard=async
}

monter_sous_volumes_nix_home() {
    mkdir -p /mnt/{nix,home}
    mount /dev/mapper/cryptroot "/mnt/nix" -o subvol=@nix,noatime,compress=zstd,ssd,discard=async
    mount /dev/mapper/cryptroot "/mnt/home" -o subvol=@home,noatime,compress=zstd,ssd,discard=async
}

monter_partition_boot() {
    mkdir -p /mnt/boot
    mount "$PART_BOOT" "/mnt/boot"
}


# =============================================================================
# FONCTIONS DISQUE : SPECIFIQUES IMPERMANENCE
# =============================================================================

creer_sous_volume_persist() {
    # Scenario INIT
    btrfs subvolume create /mnt/@persist
}

reset_sous_volume_persist() {
    # Scenario REINSTALL
    echo "Reset du sous-volume btrfs @persist"
    btrfs subvolume delete /mnt/@persist
    btrfs subvolume create /mnt/@persist
}

monter_tmpfs_sysroot() {
    mount -t tmpfs none /mnt -o size=2G,mode=755
}

monter_sous_volume_persist() {
    mkdir -p /mnt/persist
    mount /dev/mapper/cryptroot "/mnt/persist" -o subvol=@persist,noatime,compress=zstd,ssd,discard=async
}

creer_dossiers_impermanence() {
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
}

placer_fichiers_impermanence() {
    # Placement des fichiers persistés (la liste doit correspondre avec OS-functions_impermanence.nix)
    # Ceux-ci sont sont pour l'instant dans le tmpfs, on les place dans persist avant de reboot, sinon ils seraient perdus.
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
}


# =============================================================================
# FONCTIONS INSTALLATION
# =============================================================================

telecharger_dotfiles_nix() {
    echo "Téléchargement du repo des .nix custom"
    git clone https://github.com/binnotkari-wq/nixos-dotfiles.git /mnt/home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles # git créé lui-même le dossier cible
}

definir_variables_custom() {
    FIREFOX="# programs.firefox.enable = true;"
    IMPORT_MACHINE_NIX="/home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles/$TARGET_HOSTNAME.nix"
}

definir_variables_origine() {
    FIREFOX="programs.firefox.enable = true;"
    IMPORT_MACHINE_NIX="# /home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles/$TARGET_HOSTNAME.nix"
}

definir_imports_nix_impermanence() {
    IMPORT_IMPERMANENCE="/home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles/modules/OS-functions_impermanence.nix"
    IMPORT_STATELESS="# /home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles/modules/OS-optimizations_stateless.nix"
}

definir_imports_nix_stateless() {
    IMPORT_IMPERMANENCE="# /home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles/modules/OS-functions_impermanence.nix"
    IMPORT_STATELESS="/home/$TARGET_USER/Mes-Donnees/Git/nixos-dotfiles/modules/OS-optimizations_stateless.nix"
}

generer_configuration_nix() {
    LUKS_UUID=$(blkid -s UUID -o value "$PART_LUKS")
    # On exporte les variables pour qu'elles soient visibles par envsubst. Puis envsubst va remplacer le contenu de la cible, pr le contenu de la source dont les variables auront été interprétées.
    export TARGET_USER TARGET_HOSTNAME FIREFOX IMPORT_MACHINE_NIX IMPORT_IMPERMANENCE IMPORT_STATELESS LUKS_UUID
    nix-shell -p gettext --run "envsubst '\$TARGET_USER,\$TARGET_HOSTNAME,\$FIREFOX,\$IMPORT_MACHINE_NIX,\$IMPORT_IMPERMANENCE,\$IMPORT_STATELESS,\$LUKS_UUID' < ./configuration.nix.template > /mnt/etc/nixos/configuration.nix"
    
}


# =============================================================================
# FONCTIONS SETUP UTILISATEUR
# =============================================================================

creer_dossiers_utilisateur() {
    USER_DIRS=("Bureau" "Téléchargements" "Modèles" "Public" "Documents" "Musique" "Images" "Vidéos")
    for user_dir in "${USER_DIRS[@]}"; do
	mkdir -p /mnt/home/$TARGET_USER/$user_dir # création répertoires utlisateur en français  (oubli de NixOS)
    done
    mkdir -p /mnt/home/$TARGET_USER/.config
    mv ./user-dirs.dirs.template /mnt/home/$TARGET_USER/.config/user-dirs.dirs
}


# =============================================================================
# FONCTIONS FIN DE DEPLOIEMENT
# =============================================================================

traiter_permissions() {
    chown -R 1000:1000 "/mnt/home/$TARGET_USER"
    chmod 600 /mnt/persist/etc/shadow
    chmod 644 /mnt/persist/etc/passwd
}


# =============================================================================
# FONCTIONS UTILITAIRES
# =============================================================================

attendre_confirmation() { 
    local r=""  # On l'initialise à vide pour satisfaire set -u
    local message="${1:-Confirmation requise}"
    until [ "$r" = "oui" ]; do 
        read -rp "$message (oui) : " r
    done
}


choisir_customisation() {
    until [[ "$CUSTOMISATION_NIXOS" == "oui" || "$CUSTOMISATION_NIXOS" == "non" ]]; do
        echo "  Attention, la personnalisation de Nixos est un prérequis à l'impermanence."
        read -rp "Customisation Nixos? (oui/non) : " CUSTOMISATION_NIXOS
    done
}


unifier_chemins_partitions() {
    if [[ $DISK_NAME == *"nvme"* || $DISK_NAME == *"mmcblk"* ]]; then
	PART_BOOT="/dev/${DISK_NAME}p1"
	PART_LUKS="/dev/${DISK_NAME}p2"
    else
	PART_BOOT="/dev/${DISK_NAME}1"
	PART_LUKS="/dev/${DISK_NAME}2"
    fi
}


# =============================================================================
# EXECUTION
# =============================================================================

executer_logique "$@"
