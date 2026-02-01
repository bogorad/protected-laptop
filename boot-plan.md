## 1. Boot Security with YubiKey

When either booting or resuming from sleep/suspend/hibernate, check USB for YubiKey hardware, _and_ whether slot#2 is programmed. If it is, test against a known challenge-response pair. Continue to boot only if a YubiKey device is present, _and_ slot#2 is programmed, _and_ the test passes. If any of the conditions are not met, boot `Tails OS` instead, don't ask any questions, don't provide any feedback. YubiKey must be inserted before power-on; the check is immediate with no delay or prompt.

**Two-stage authentication:**

1. **FIDO2 assertion** - quick verification that this is the correct YubiKey
2. **HMAC-SHA1 challenge-response** - derives the LUKS decryption key

The key is pre-generated via

```bash
dd if=/dev/urandom bs=1 count=20 2>/dev/null | xxd -p
```

and stored securely (e.g., in BitWarden/VaultWarden). This allows restoring it in case of loss of Yubikey hardware.

**Note:** `PIV` slots on the same YubiKey may be used for storing SSH keys (password protection of ssh keys still recommended).

### 1.1. Encryption Key Unlock

When continuing to boot, use `Clevis` to unlock the disk encryption key using challenge-response based on data stored in the YubiKey. We will use pre-generated challenge-response secrets for YubiKey `LUKS` disk encryption to enable backup and recovery capabilities. Generate a 20-byte `HMAC-SHA1` secret externally, it becomes the authoritative backup credential. Import it into primary and however many backup YubiKeys using `ykman`. Then bind encrypted volumes using Clevis with YubiKey challenge-response. Pre-generated secret will be stored safely in case of loss/destruction of hardware (e.g., to prevent forced unlocking). Later a new YubiKey device can be programmed as a replacement.

### 1.2. Key disposal/destruction in case of emergency

In case of emergency data on the laptop can be secured by disposing of or physically destroying the YubiKey. No key - laptop boots into Tails OS. Reasoning for the attackers: "Yes, I am a paranoid type, my laptop ONLY runs Tails OS, and everywhere I visit I use TOR. Yes, I am that crazy".

### 1.3. Key recovery when the danger has passed

Buy/get a new YubiKey. Then using Tails OS and some form of OTP (e.g., acquiring a one-time recovery code from a friend) unlock your password manager, extract the OTP secret, and program it into slot#2 using command-line (or UI) tools. Then reboot, and this time the laptop will boot normally.

---

## 2. System Architecture

### 2.1. Disk Layout

```
┌─────────────────────────────────────────────────────────────────┐
│ GPT Partition Table                                             │
├──────┬──────────┬────────────┬──────────────────────────────────┤
│  #   │ Size     │ Type       │ Contents                         │
├──────┼──────────┼────────────┼──────────────────────────────────┤
│  1   │ 1 GB     │ EFI System │ Transit kernel + initramfs       │
│      │          │ (FAT32)    │ (Tails kernel embedded in initramfs) │
├──────┼──────────┼────────────┼──────────────────────────────────┤
│  2   │ 8 GB     │ Linux      │ Tails OS (unencrypted)           │
│      │          │            │ No persistence                   │
├──────┼──────────┼────────────┼──────────────────────────────────┤
│  3   │ Rest     │ Linux Swap │ LUKS2 encrypted container        │
│      │          │ (0x8200)   │ └─ LVM (cryptvg)                 │
│      │          │            │    ├─ cryptvg/boot (ext4, 500MB) │
│      │          │            │    └─ cryptvg/zfs (rest)         │
│      │          │            │       └─ ZFS pool (zpool)        │
│      │          │            │          ├─ zpool/root (rollback)│
│      │          │            │          ├─ zpool/home           │
│      │          │            │          ├─ zpool/nix            │
│      │          │            │          └─ zpool/persist        │
└──────┴──────────┴────────────┴──────────────────────────────────┘
```

**Notes:**

- Partition 3 uses swap type code for plausible deniability
- LUKS header is standard (not detached) - sufficient for threat model
- Inside LUKS: LVM with two LVs - ext4 `/boot` (kernel, initrd) + ZFS pool (NixOS root)
- Clevis stores challenge in LUKS header (no separate salt file)
- Tails kernel/initrd are embedded in Transit initramfs, not stored separately on ESP

### 2.2. Transit Partition

A minimal Alpine Linux initramfs residing in the ESP. Purpose: decide which OS to boot based on YubiKey presence and validity.

**Contents (~50MB total):**

| Path                    | Purpose                        |
| ----------------------- | ------------------------------ |
| `/init`                 | Decision script                |
| `/bin/busybox`          | Core utilities                 |
| `/usr/bin/lsusb`        | USB device detection           |
| `/usr/bin/fido2-token`  | FIDO2 presence check           |
| `/usr/bin/fido2-assert` | FIDO2 assertion verification   |
| `/usr/bin/clevis`       | LUKS unlock (YubiKey HMAC)     |
| `/sbin/cryptsetup`      | LUKS operations                |
| `/sbin/kexec`           | Kernel execution               |
| `/etc/fido2-credential` | Registered FIDO2 credential ID |
| `/tails/vmlinuz`        | Embedded Tails kernel          |
| `/tails/initrd.img`     | Embedded Tails initramfs       |

**Why Alpine:** musl-based, minimal footprint (~50MB), packaged tools available, no NixOS fingerprints in ESP.

### 2.3. Cold Boot Flow

```
Power On
    │
    ▼
UEFI loads Transit from ESP (default boot entry)
    │
    ▼
Transit /init executes
    │
    ▼
lsusb: YubiKey present? (vendor 1050:)
    │
    ├─── NO ────────────────────────────────┐
    │                                       │
    ▼                                       │
FIDO2 assertion check                       │
    │                                       │
    ├─── FAIL ──────────────────────────────┤
    │                                       │
    ▼                                       │
clevis luks unlock (HMAC-SHA1 from header)  │
    │                                       │
    ├─── FAIL ──────────────────────────────┤
    │                                       │
    ▼                                       ▼
Mount ext4 /boot                     kexec Tails kernel
kexec NixOS kernel + initrd                 │
    │                                       ▼
    ▼                                 Tails boots
NixOS initrd imports ZFS             (no trace of NixOS)
    │
    ▼
NixOS boots
```

**Timing:** Decision occurs within ~2 seconds. No visible delay or prompt.

### 2.4. Suspend/Resume Flow

```
NixOS running
    │
    ▼
Suspend triggered (lid close, idle, manual)
    │
    ▼
systemd-suspend.service
    │
    ▼
pre-suspend hook:
    cryptsetup luksSuspend cryptroot
    (encryption keys wiped from RAM)
    │
    ▼
    ... system suspended ...
    │
    ▼
Resume triggered (lid open, power button)
    │
    ▼
post-resume hook:
    │
    ▼
lsusb: YubiKey present?
    │
    ├─── NO ───────────────────────────────┐
    │                                      │
    ▼                                      │
FIDO2 assertion check                      │
    │                                      │
    ├─── FAIL ─────────────────────────────┤
    │                                      │
    ▼                                      │
HMAC-SHA1 challenge-response               │
cryptsetup luksResume cryptroot            │
    │                                      │
    ├─── FAIL ─────────────────────────────┤
    │                                      │
    ▼                                      ▼
Desktop session restored            systemctl reboot
                                           │
                                           ▼
                                    Transit → Tails
```

**Security property:** Removing YubiKey during suspend and resuming causes an immediate reset into Tails. Attacker cannot access suspended session.

### 2.5. Technologies

| Component              | Technology                               | Purpose                                           |
| ---------------------- | ---------------------------------------- | ------------------------------------------------- |
| **Bootloader**         | None (direct UEFI)                       | UEFI loads Transit kernel directly from ESP       |
| **Transit OS**         | Alpine Linux initramfs                   | Minimal decision layer (~50MB + Tails embed), musl-based |
| **USB detection**      | `lsusb` (usbutils)                       | Check for YubiKey vendor ID `1050:`               |
| **FIDO2**              | `libfido2` (`fido2-token`, `fido2-assert`) | Discover YubiKey device, verify correct key     |
| **LUKS unlock**        | Clevis + `yubikey-personalization`       | HMAC-SHA1 challenge-response, key in LUKS header  |
| **Disk encryption**    | LUKS2 (`cryptsetup`)                     | Encrypts partition 3                              |
| **Volume management**  | LVM (`lvm2`)                             | Manages boot LV and ZFS LV inside LUKS            |
| **Filesystem**         | ZFS                                      | On cryptvg/zfs LV, datasets for `/`, `/home`, `/nix`, `/persist` |
| **Impermanence**       | ZFS rollback                             | Root rolled back to blank snapshot on boot |
| **Main OS**            | NixOS                                    | Declarative, reproducible configuration           |
| **Secrets**            | sops-nix                                 | Encrypted secrets in git, decrypted at activation |
| **Kernel loading**     | `kexec`                                  | Jump directly to target kernel without UEFI       |
| **Suspend security**   | `cryptsetup luksSuspend/luksResume`      | Wipes keys from RAM during suspend                |
| **Resume auth**        | systemd service                          | Runs YubiKey check before `luksResume`            |
| **YubiKey removal**    | udev rule                                | Immediate reset into Tails                        |

**NixOS-specific requirements:**

- Disable `grub` and `systemd-boot` (Transit handles boot)
- ZFS support enabled
- sops-nix for runtime secrets (after boot, not for FIDO2 credential or LUKS salt)
- Custom systemd services for `luks-suspend` and `luks-resume`
- udev rule for YubiKey removal → immediate reset into Tails
- Packages: `yubikey-personalization`, `yubikey-manager`, `libfido2`, `cryptsetup`, `lvm2`

### 2.6. Transit `/init` Script

```bash
#!/bin/busybox sh
set -e

# Mount essential filesystems
mount -t devtmpfs devtmpfs /dev
mount -t sysfs sysfs /sys
mount -t proc proc /proc
mkdir -p /mnt/boot

# ─────────────────────────────────────────────────────────────
# Stage 1: YubiKey presence (immediate, no delay)
# ─────────────────────────────────────────────────────────────
if ! lsusb 2>/dev/null | grep -q "1050:"; then
    exec /boot-tails
fi

# ─────────────────────────────────────────────────────────────
# Stage 2: FIDO2 assertion (find YubiKey device dynamically)
# ─────────────────────────────────────────────────────────────
CREDENTIAL=$(cat /etc/fido2-credential)
YUBIKEY_DEV=""
for dev in /dev/hidraw*; do
    if fido2-token -I "$dev" 2>/dev/null | grep -q "Yubico"; then
        YUBIKEY_DEV="$dev"
        break
    fi
done

if [ -z "$YUBIKEY_DEV" ]; then
    exec /boot-tails
fi

# Generate random challenge and verify assertion
CHALLENGE=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)
if ! echo "$CHALLENGE" | fido2-assert -G "$YUBIKEY_DEV" "$CREDENTIAL" >/dev/null 2>&1; then
    exec /boot-tails
fi

# ─────────────────────────────────────────────────────────────
# Stage 3: LUKS unlock via Clevis (challenge in LUKS header)
# ─────────────────────────────────────────────────────────────
if ! clevis luks unlock -d /dev/disk/by-partlabel/cryptdata -n cryptroot; then
    exec /boot-tails
fi

# Activate LVM inside LUKS
vgchange -ay cryptvg

# ─────────────────────────────────────────────────────────────
# Stage 4: Mount ext4 /boot and kexec NixOS
# ─────────────────────────────────────────────────────────────
mount -t ext4 /dev/cryptvg/boot /mnt/boot

kexec -l /mnt/boot/kernel \
    --initrd=/mnt/boot/initrd \
    --command-line="root=ZFS=zpool/root"

umount /mnt/boot
vgchange -an cryptvg
cryptsetup close cryptroot

kexec -e

# ─────────────────────────────────────────────────────────────
# Fallback (should never reach)
# ─────────────────────────────────────────────────────────────
exec /boot-tails
```

**`/boot-tails` helper:**

```bash
#!/bin/busybox sh
kexec -l /tails/vmlinuz --initrd=/tails/initrd.img \
    --command-line="boot=live live-media=removable nopersistence quiet"
kexec -e
```

### 2.7. Build Plan

#### Phase 1: Prepare Secrets (on trusted machine)

1. **Generate HMAC-SHA1 secret** (store in password manager):

   ```bash
   dd if=/dev/urandom bs=1 count=20 2>/dev/null | xxd -p
   ```

2. **Program YubiKey slot 2**:

   ```bash
   ykman otp chalresp 2 <secret-hex>
   ```

3. **Register FIDO2 credential**:

   ```bash
   # Find YubiKey device
   YUBIKEY_DEV=$(fido2-token -L | grep -i yubico | cut -d: -f1)
   
   # Create credential (use your domain as relying party)
   fido2-cred -M -i - -o credential "$YUBIKEY_DEV" <<EOF
   <relying-party-id>
   <user-id>
   EOF
   
   # Extract credential ID for use in Transit
   fido2-cred -V -i credential -o /dev/null && echo "Credential valid"
   ```

4. **Store FIDO2 credential in repo** (plaintext, useless without physical YubiKey):

   ```bash
   echo "<credential-id>" > boot-secrets/fido2-credential
   git add boot-secrets/
   ```

#### Phase 2: Partition Disk (boot from NixOS live USB)

1. **Create GPT partition table**:

   ```bash
   parted /dev/nvme0n1 -- mklabel gpt
   ```

2. **Create partitions**:

   ```bash
   parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 1025MiB
   parted /dev/nvme0n1 -- set 1 esp on
   parted /dev/nvme0n1 -- mkpart tails ext4 1025MiB 9217MiB
   parted /dev/nvme0n1 -- mkpart cryptdata linux-swap 9217MiB 100%
   ```

3. **Format ESP**:
   ```bash
   mkfs.fat -F32 -n ESP /dev/nvme0n1p1
   ```

#### Phase 3: Setup LUKS

1. **Format LUKS container** (initial passphrase, will be replaced by Clevis):

   ```bash
   cryptsetup luksFormat --type luks2 /dev/nvme0n1p3
   cryptsetup open /dev/nvme0n1p3 cryptroot
   ```

2. **Create LVM inside LUKS**:

   ```bash
   # Initialize LVM on the LUKS container
   pvcreate /dev/mapper/cryptroot
   vgcreate cryptvg /dev/mapper/cryptroot
   
   # ext4 for /boot (500MB)
   lvcreate -L 500M -n boot cryptvg
   mkfs.ext4 -L boot /dev/cryptvg/boot
   
   # LV for ZFS (remaining space)
   lvcreate -l 100%FREE -n zfs cryptvg
   ```

3. **Bind Clevis with YubiKey** (replaces passphrase):

   ```bash
   clevis luks bind -d /dev/nvme0n1p3 yubikey '{"slot":2}'
   # Clevis generates challenge, gets HMAC response, stores in LUKS header
   ```

#### Phase 4: Setup ZFS

1. **Create pool on dedicated LV**:

   ```bash
   zpool create -o ashift=12 \
       -O mountpoint=none \
       -O acltype=posixacl \
       -O compression=zstd \
       -O dnodesize=auto \
       -O normalization=formD \
       -O relatime=on \
       -O xattr=sa \
       zpool /dev/cryptvg/zfs
   ```

2. **Create datasets**:

   ```bash
   zfs create -o mountpoint=legacy zpool/root
   zfs create -o mountpoint=legacy zpool/home
   zfs create -o mountpoint=legacy zpool/nix
   zfs create -o mountpoint=legacy zpool/persist
   
   # Create empty snapshot for impermanence rollback
   zfs snapshot zpool/root@blank
   ```

#### Phase 5: Install Tails

1. **Write Tails image to partition 2**:

   ```bash
   # Use dd or Tails installer to write to /dev/nvme0n1p2
   ```

2. **Extract Tails kernel for Transit initramfs embedding**:
   ```bash
   # Extract Tails boot files to staging directory for Transit build
   mkdir -p /tmp/tails-extract /mnt/tails
   mount /dev/nvme0n1p2 /mnt/tails
   cp /mnt/tails/live/vmlinuz /tmp/tails-extract/
   cp /mnt/tails/live/initrd.img /tmp/tails-extract/
   umount /mnt/tails
   # These files will be embedded into Transit initramfs in Phase 7
   ```

#### Phase 6: Install NixOS

1. **Mount filesystems**:

   ```bash
   mount -t zfs zpool/root /mnt
   mkdir -p /mnt/{boot,home,nix,persist}
   mount /dev/cryptvg/boot /mnt/boot
   mount -t zfs zpool/home /mnt/home
   mount -t zfs zpool/nix /mnt/nix
   mount -t zfs zpool/persist /mnt/persist
   ```

2. **Clone NixOS configuration** (includes Transit derivation, sops secrets):

   ```bash
   git clone <your-nixos-config-repo> /mnt/etc/nixos
   ```

3. **Install**:
   ```bash
   nixos-install --no-bootloader --flake /mnt/etc/nixos#hostname
   ```

#### Phase 7: Build and Deploy Transit

1. **Build Transit initramfs** (Alpine-based, built on NixOS host):
   - Minimal kernel
   - Initramfs with: busybox, lsusb, libfido2, clevis, cryptsetup, kexec, lvm2
   - `/init` script baked in
   - FIDO2 credential baked in (plaintext, useless without physical YubiKey)
   - Tails kernel/initrd embedded from `/tmp/tails-extract/` (Phase 5)
   - Files placed at `/tails/vmlinuz` and `/tails/initrd.img` inside initramfs CPIO

2. **Deploy to ESP**:

   ```bash
   mount /dev/nvme0n1p1 /mnt/esp
   mkdir -p /mnt/esp/EFI/transit
   cp result/vmlinuz /mnt/esp/EFI/transit/
   cp result/initramfs.img /mnt/esp/EFI/transit/
   ```

#### Phase 8: Configure UEFI

1. **Create boot entry for Transit**:

   ```bash
   efibootmgr --create --disk /dev/nvme0n1 --part 1 \
       --label "Transit" \
       --loader "\EFI\transit\vmlinuz" \
       --unicode "initrd=\EFI\transit\initramfs.img"
   ```

2. **Set Transit as default boot**:
   ```bash
   efibootmgr --bootorder XXXX  # Transit entry number
   ```

#### Phase 9: Test

1. **With YubiKey inserted**: Power on → should boot NixOS
2. **Without YubiKey**: Power on → should boot Tails silently
3. **Wrong YubiKey**: Power on → should boot Tails silently
4. **Suspend with YubiKey**: Should resume normally
5. **Suspend, remove YubiKey, resume**: Should reboot into Tails
