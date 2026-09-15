# Wallets: design and plan

Written 2026-09-14. The Wallets page exists (list, receive, USD price).

## Status (2026-09-14, evening): the Monero engine is built

`packages/xmr_core/lib/src/wallet/`, each part checked against an
independent oracle:
- `account.dart`: 25-word mnemonic (Monero's English list and CRC32
  checksum), spend/view keys, address, subaddresses; equal to monero-python
  on every vector. View-only accounts.
- `crypto/ec_ops.dart`: hash to point (`ge_fromfe_frombytes_vartime`), key
  images, scalar arithmetic, multi-scalar multiplication; Monero's own
  `tests/crypto/tests.txt` (2618 vectors) pass.
- `transaction.dart`: full and pruned transactions (prefix, RingCT base,
  Bulletproofs+, CLSAGs); 263 real mainnet transactions hash to their block
  ids.
- `scanner.dart`, `outputs.dart`: view tags, subaddress lookup, amount
  decryption checked against the commitment, key images, spend detection.
- `bulletproofs_plus.dart`, `clsag.dart`: prover and verifier; our verifiers
  accept the proofs and signatures of real mainnet transactions (rings from
  a node), and our own proofs pass them.
- `decoys.dart` (wallet2's gamma picker over the whole output distribution,
  3.76M blocks in 2 s from the compressed binary RPC), `tx_builder.dart`
  (type 6, rings of 16, inputs sorted by key image, fee = weight x fee per
  byte rounded to the quantization mask, self-check before sending),
  `node_rpc.dart` (monerod reads no chunked bodies: content length set).
- `wallet_service.dart`: an isolate with its own light chain and PoW
  checks over P2P, scanning pruned blocks by id from the wallet's birthday
  (new wallets start at the tip), mempool, reorganizations, sends
  (decoys from the node, submitted through it and relayed to our peers).

App: a Monero wallet is created automatically (sealed with the device key,
password optional, backup reminder); restore from 25 words, view-only
(address and view key; also offered for the miner's address-only entry),
address-only. The miner pays the app wallet when no address is set.
Settings has the node for sending (public nodes by default: Cake Wallet,
HashVault, Stack Wallet). Still to verify with real funds: receiving and a
send confirmed on mainnet.


## What exists

- `lib/wallets/wallet.dart`: a `Wallet` is one chain (`monero` today),
  a label, an address and a list of `WalletAsset`s (the chain's coin first,
  then tokens; each with decimals, an optional contract and a `BigInt`
  balance that stays null until known).
- Wallets are independent from the miners (`wallets.json`). The address
  the Monero miner pays is added automatically; others are added by address.
- `MoneroWallet` receives (shows and copies the address). The balance is
  "not scanned yet"; the payouts the node saw from mining are shown beside
  it. Send is disabled with the reason.
- Prices: `PriceService` asks Kraken (XMR/USD), then KuCoin (XMR-USDT),
  then CoinGecko, using the ids in `assets/mining_catalog.json`; cached for
  a minute, refreshed every minute on the page.

## Monero wallet engine

The chain is on hard fork v16 (`supportedMajorVersion`), so transactions
are RingCT type 6: CLSAG ring signatures (ring of 16), Bulletproofs+ range
proofs, view tags.

1. **Keys.** Create and restore with the 25 word Monero mnemonic (word
   lists from Monero's `src/mnemonics`, BSD-3) and Polyseed (16 words,
   license to check before porting), plus view-only import (address and
   private view key). The view key is derived from the spend key with
   Keccak, already in `xmr_core`. Subaddresses: `m = Hs("SubAddr" || a || major || minor)`.
2. **Storage.** Keys never leave the device. Encrypted with a password:
   Argon2id (we have Argon2d; add the id variant) and
   XChaCha20-Poly1305 (to write in Dart, RFC 8439 vectors). Android can
   wrap the key with the Keystore.
3. **Receiving and balance, over P2P only.** Our levin peer asks peers for
   full blocks with their transactions from the wallet's restore height,
   then follows new blocks and the mempool. For each output: derivation
   `D = 8aR`, the one-byte view tag skips all but about 1 in 256 outputs,
   then `P = Hs(D || i)G + B` (with the subaddress table), the amount from
   the ECDH field, checked against the commitment. Key images `x Hp(P)`
   (needs the spend key) find spends. P2Pool payouts are coinbase outputs,
   so the mining payouts become verified on chain instead of estimated.
   A wallet created in the app starts at today's height; restoring an old
   wallet downloads every block since its restore height (roughly
   20000 blocks per month of history).
4. **Sending.** Inputs, change, fee from the dynamic fee (median block
   weights, from the blocks the light chain already keeps), outputs with
   view tags, tx extra, CLSAG and Bulletproofs+. Porting source:
   monero-oxide (MIT) for CLSAG, Bulletproofs+, serialization and decoy
   selection (Monero's gamma distribution). Broadcast through our own P2P
   peers (`NOTIFY_NEW_TRANSACTIONS`).
5. **Decoys and the data source.** Every input needs 15 decoy
   outputs picked from the whole chain's output history (their keys and
   commitments by global index, plus the output distribution). The Monero
   P2P protocol has no message for that. The options:
   - **A Monero node's RPC that the user chooses** (their own monerod, or a
     public node): `get_output_distribution`, `get_outs`. This is what
     Feather and Cake Wallet do. That node learns which outputs are
     requested and the IP (Tor can hide the IP later); it does not get
     keys. Receiving stays P2P; only sending uses the node.
   - **Pure P2P**: build our own output index by downloading every RingCT
     output since 2017 (well over 100 million outputs, many GB, days of
     download). Desktop only at best; not for phones.
   - **A light wallet server** (LWS): the server gets the view key and
     sees the whole history. The least private.

   **Decided (user, 2026-09-14): a node the user chooses.** No node is set
   by default; sending stays off until the user picks one. The node is used
   only for decoys (and the fee estimate); receiving, balance and
   broadcasting stay on our own P2P peers.
6. **The next Monero upgrade (FCMP++ and Carrot, hard fork v17, not active
   yet).** It replaces rings with a membership proof over all outputs
   (curve trees; the wallet needs tree paths, again node data), changes
   key derivation for new addresses (Carrot) and the transaction format.
   The engine keeps the proof system behind one interface so v17 can be
   added without rewriting scanning and storage.
7. **UI.** Send (address, amount, fee level, password to confirm),
   Receive (primary address, subaddresses, a QR code from a pure Dart QR
   encoder), history (incoming, outgoing, confirmations), locked and
   unlocked balance (10 blocks; 60 for coinbase outputs).
8. **Tests.** Monero's crypto and mnemonic test vectors, monero-oxide's
   vectors, then a stagenet run (stagenet peers and a faucet) before
   mainnet.

## Ethereum and tokens (plan only)

- **Accounts.** One secp256k1 key per account, from a BIP-39 mnemonic
  with BIP-32/44 derivation (`m/44'/60'/0'/0/i`); several accounts per
  seed. The same account works on Ethereum and on its L2s (Arbitrum,
  Base, Optimism), which differ only by chain id: a wallet gets a list of
  networks.
- **Assets.** ETH plus tokens: ERC-20 first (`balanceOf`, `decimals`,
  `symbol`), NFTs (ERC-721/1155) later. Tokens come from a curated token
  list shipped as JSON, tokens the user adds by contract, and discovery
  from `Transfer` logs to the address. `WalletAsset` already carries the
  contract, the decimals and a `BigInt` balance, so tokens need no model
  change.
- **Data source.** The same question as Monero sends: an Ethereum
  JSON-RPC endpoint the user picks (own node or provider) first; later a
  consensus light client (Helios style, verifying RPC answers against the
  sync committee) so answers need not be trusted.
- **Prices.** CoinGecko by contract address for tokens, Kraken for majors.
- **Sending.** EIP-1559 transactions (RLP, Keccak we have, secp256k1
  ECDSA to write), gas estimation over RPC, ERC-20 `transfer` calldata.

## Order of work (proposal)

1. Monero keys, encrypted storage, view-only import.
2. P2P scanning from the restore height: balance, history, mining payouts
   verified on chain.
3. Receive with a QR code, subaddresses.
4. Node setting, decoys, transaction building, sending (stagenet first).
5. Ethereum accounts, ETH and ERC-20.
