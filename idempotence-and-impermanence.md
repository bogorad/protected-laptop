## 1. Idempotent and Impermanent System

Everything is `idempotent` and `impermanent`. In `NixOS`, `ZFS` is used, and `/root` dataset is rolled back from clean slate on every boot. Only specific folders are stored as `/persist/` and bound-mounted to folders that need it (e.g., `/var/lib/tailscale` is bound-mounted to `/persist/var-lib/tailscale`). All bound-mounts automatically recreated on boot.
