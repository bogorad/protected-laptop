# Project BitVPN: A High-Stealth Obfuscated Tunneling System

## Overview

Project BitVPN is a personal, high-stealth VPN alternative designed to evade sophisticated network surveillance and Deep Packet Inspection (DPI). It achieves this by meticulously camouflaging its traffic to be indistinguishable from mundane BitTorrent activity.

This system is not a tool for using the BitTorrent network. Instead, it leverages the BitTorrent protocol as a disguise, creating a secure, resilient, and difficult-to-block tunnel for a small, trusted group of users. The architecture relies on a decentralized discovery mechanism where each exit node publishes its encrypted contact information to a secret, hard-to-find "mailbox" on the public DHT. Only trusted clients possess the secret key required to locate and decrypt these records.

## Core Concepts

- **BitTorrent Camouflage:** The entire lifecycle of a connection, from server discovery to data transfer, is wrapped in legitimate-looking BitTorrent protocol messages.
- **Decentralized Discovery via Encrypted DHT Mailboxes:** The system avoids public, trackable announcements. Each exit node encrypts its connection details into a "contact record" and stores this blob in a secret mailbox on the DHT. The address of this mailbox is derived from a shared secret, making it undiscoverable by outsiders.
- **Time-Stamped Confidential Payloads:** The node's IP address is not published in plaintext. It is combined with a current timestamp and then encrypted using a shared, static symmetric key. This provides both confidentiality (only clients can read it) and freshness (clients reject old, replayed messages).
- **Constant-Rate Cover Traffic:** To defeat traffic correlation and timing analysis, the system eliminates revealing periods of silence. During user inactivity, the client and server automatically generate and exchange encrypted "noise" packets disguised as standard `piece` messages. This smooths the traffic flow from a bursty, interactive pattern into a continuous stream, more closely mimicking a large file transfer and frustrating behavioral fingerprinting.
- **Multi-Node Resilience & Performance:** The system is designed to run with multiple exit nodes. Clients discover all available nodes, select the fastest (lowest latency), and perform instant failover if a node becomes unreachable.

## System Architecture

The system consists of three main components:

1.  **The Client Application:** A smart client run by each user. It handles the discovery process: calculating the secret mailbox locations on the DHT, fetching the encrypted records, decrypting them, and validating the internal timestamp for freshness. It then performs latency testing, node selection, and all protocol camouflage logic, exposing a simple SOCKS5 proxy.
2.  **The Exit Node Servers:** A fleet of servers you control. Each server periodically publishes its current IP address and a fresh timestamp within an encrypted record to its designated secret mailbox in the DHT.
3.  **The Public BitTorrent DHT:** The global, decentralized BitTorrent "phonebook." We use its generic storage feature as a robust and censorship-resistant database for our encrypted mailboxes.

## The Cryptographic Foundation

The system's security is built on a simple and robust model where shared secrets are derived once from a single master secret.

1.  **The Permanent Secret Salt (The Master Secret):** A single, long, random string of text generated once by the administrator. This is the root from which all shared symmetric keys are derived. These derived keys are static and do not rotate.

    - **Mailbox Address Key (`K_mailbox`):** `K_mailbox = HKDF(salt, info="bitvpn_mailbox_v1")`. A static key used to derive the DHT address for each node's mailbox.
    - **AEAD Payload Key (`K_announce`):** `K_announce = HKDF(salt, info="bitvpn_announce_v1")`. A static AEAD key (e.g., for XChaCha20-Poly1305) used to encrypt the contact record (IP and timestamp), ensuring its confidentiality.
    - **Tunnel Obfuscation Key (`obfuscation_key`):** `obfuscation_key = HKDF(salt, info="bitvpn_tunnel_v1")`. A static key used to encrypt the inner XTLS tunnel handshake.

2.  **The Tunneling Protocol (XTLS):** The secure tunnel is built using XTLS (based on TLS 1.3). This protocol is responsible for all data transmission security. It independently negotiates its own ephemeral session keys for every connection, providing perfect forward secrecy for all user traffic.

## Flow of a Connection: A Step-by-Step Journey

This is the lifecycle of a connection, layering all stealth and resilience strategies.

#### Phase 1: Discovery & Node Selection (The Mailbox Hunt)

1.  A user starts the Client Application. It has a pre-configured list of `node_id`s for all trusted Exit Nodes and has derived the static keys (`K_mailbox`, `K_announce`).
2.  For each trusted `node_id`, the client calculates its secret mailbox address on the DHT (e.g., `mailbox_address = SHA1(K_mailbox + node_id)`).
3.  It performs a DHT `GET` request for the data at that address.
4.  **The client now performs a strict, two-step validation:**
    - **1. Decrypt for Confidentiality:** It uses the static `K_announce` key to AEAD-decrypt the received data blob. If decryption fails, the record is considered invalid garbage from an outsider and is immediately discarded.
    - **2. Verify Freshness:** It inspects the decrypted payload to find the internal timestamp. If the timestamp is older than a set tolerance (e.g., 30 minutes), the record is a valid but stale replay, and is discarded.
5.  The client aggregates the IP addresses from all records that pass both checks.
6.  It then performs a quick **latency test** on every valid IP and sorts the nodes from fastest to slowest.

#### Phase 2: Connection & The Cover Story

1.  The client attempts to connect to the **fastest available node** from its sorted list.
2.  Upon successful TCP connection, it performs a **perfectly standard BitTorrent handshake**.
3.  To establish a benign context, it engages in a **"bait data" exchange**, requesting and receiving a few real `piece` messages from a pre-shared bait file.
4.  **Failover:** If the connection fails, the client automatically discards that node and repeats the process with the next-fastest node.

#### Phase 3: The Secret Handshake

1.  With its cover story established, the client begins the real handshake, disguised within the common **`ut_metadata` protocol**.
2.  It uses the static `obfuscation_key` to **encrypt** its XTLS `ClientHello` message and **wraps** it inside a `ut_metadata` message to send.
3.  The Exit Node follows the identical encrypt-then-wrap process for its responses.
4.  A secure XTLS tunnel is established.

#### Phase 4: The Secure Tunnel & Active Camouflage

1.  The XTLS tunnel is now active, secured by its own ephemeral session keys.
2.  All application traffic is encrypted by the tunnel and wrapped inside standard BitTorrent **`piece` messages** for transfer.
3.  **Active Camouflage via Cover Traffic:** To mask the natural rhythm of user activity, the tunnel actively conceals periods of idleness.
    - If no real data has been sent for a short, randomized period, both the client and the server will independently generate a **cover traffic packet**.
    - This packet, marked internally with a discard signal, is encrypted by the XTLS session and wrapped in a `piece` message.
    - The receiving end decrypts the packet, recognizes the discard signal, and silently drops it.
    - From an external observer's perspective, the flow of `piece` messages is continuous and steady.

## Deployment Guide

#### Administrator Setup (The "Genesis" Event)

1.  **Generate Secrets:**
    - Generate the single **Permanent Secret Salt**.
    - Assign a unique, stable `node_id` (e.g., "exit01", "exit02") to each planned Exit Node.
2.  **Deploy Servers:**
    - Set up multiple Linux VPS instances.
    - On each server, install the Exit Node software.
    - Create a configuration file on each server containing its unique `node_id` and the shared **Permanent Salt**.
    - Run the software. It will derive its static keys and begin publishing encrypted updates to its secret DHT mailbox.
3.  **Distribute Client Credentials:**
    - Securely transmit the necessary credentials to each user. This includes:
      - The **Permanent Secret Salt**.
      - A **list of all trusted `node_id`s**.

#### Client Setup

1.  The user receives the Client Application executable.
2.  They create a configuration file containing the Permanent Salt and the list of trusted `node_id`s.
3.  They run the application.

## User Experience

1.  The user runs the client.
2.  The client automatically handles the entire discovery, decryption, and connection process.
3.  It creates a local **SOCKS5 proxy** (e.g., at `127.0.0.1:1080`).
4.  The user configures their applications to use this proxy.

## Security & Limitations

- **Trust:** The security of the entire system relies on the secrecy of the Permanent Secret Salt. All nodes are part of a single trust domain.
- **Discovery Security:** The discovery mechanism is protected from outsiders by strong AEAD encryption. Replay attacks are prevented by the use of an internal, encrypted timestamp.
- **Behavioral Resilience:** The use of constant-rate cover traffic hardens the system against timing and traffic correlation attacks by smoothing the data flow to more closely resemble a continuous file transfer.
- **Data Security:** All user traffic is protected with perfect forward secrecy by the underlying XTLS tunnel, which negotiates unique session keys for every connection.
- **Not for Public Torrenting:** This system is a VPN alternative. It should not be used to download public torrents, as this would create traceable network patterns that deviate from the system's intended behavioral camouflage.

[Comparison to BitSmugler VPN](./bitvpn-vs-bitsmugler-vpn.md)
