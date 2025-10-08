## 1. Boot Security with YubiKey

When either booting or resuming from sleep/suspend/hibernate, check USB for YubiKey hardware, _and_ whether slot#2 is programmed. If it is, test against a known challenge-response pair. Continue to boot only if a YubiKey device is present, _and_ slot#2 is programmed, _and_ the test passes. If any of the conditions are not met, boot `Tails OS` instead, don't ask any questions, don't provide any feedback. The key is pre-generated via

```bash
dd if=/dev/urandom bs=1 count=20 2>/dev/null | base32 | tr -d '='
```

and stored securely (e.g., in BitWarden/VaultWarden). This allows restoring it in case of loss of Yubikey hardware.

**Note:** `PIV` slots on the same YubiKey may be used for storing SSH keys (password protection of ssh keys still recommended).

### 1.1. Encryption Key Unlock

When continuing to boot, use `Clevis` to unlock the disk encryption key using challenge-response based on data stored in the YubiKey. We will use pre-generated challenge-response secrets for YubiKey `LUKS` disk encryption to enable backup and recovery capabilities. Generate a 20-byte `HMAC-SHA1` secret externally, it becomes the authoritative backup credential. Import it into primary and however many backup YubiKeys using `ykman`. Then bind encrypted volumes using Clevis with YubiKey challenge-response. Pre-generated secret will be stored safely in case of loss/destruction of hardware (e.g., to prevent forced unlocking). Later a new YubiKey device can be programmed as a replacement.

### 1.2. Key disposal/destruction in case of emergency

In case of emergency data on the laptop can be secured by disposing of or physically destroying the YubiKey. No key - laptop boots into Tails OS. Reasoning for the attackers: "Yes, I am a paranoid type, my laptop ONLY runs Tails OS, and everywhere I visit I use TOR. Yes, I am that crazy".

### 1.3. Key recovery when the danger has passed

Buy/get a new YubiKey. Then using Tails OS and some form of OTP (e.g., acquiring a one-time recovery code from a friend) unlock your password manager, extract the OTP secret, and program it into slot#2 using command-line (or UI) tools. Then reboot, and this time the laptop will boot normally.
