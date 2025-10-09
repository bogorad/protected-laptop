# Secure Laptop Configuration Documentation

These are preliminary musings that reflect research towards my plan to create
a reproducible, turn-key configuration for a personal/business laptop that can
be safely carried anywhere, with good protection against data theft, forced disclosure,
having good deniability, and protected network access.

First attempt was using OpenWRT running in a QEMU VM. Benefits: versatility,
extremely low memory tax (64MiB easily). Drawbacks: complex init. Postponed, will
return later.

Second attempt. Simplified config with a nixos micro-VM running xray and nftables.
Benefits: fully static declarative config, although to accomodate USB wifi and various wifi
SSID/PSK pairs we might need some sort of UI config. Working.

Work in progress, obviously.

## Parts:

1. [Boot plan](./boot-plan.md)
1. [Network topology](./network-topology.md)
1. [BitVPN](./bitvpn.md)
1. [Idempotence and impermanence](./idempotence-and-impermanence.md)
