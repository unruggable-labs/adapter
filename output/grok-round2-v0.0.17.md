# Adapter8004 v0.0.17 — Grok round 2 (20 new scenarios)

None of these restates a round-1 mechanism. Round 1: `output/attack-scenarios-v0.0.17.md` + `test/security/GrokExploit_*.t.sol`. Primary: `src/Adapter8004.sol`.

`forge test`: **453 passed, 0 failed**. Prior **433** still green. **20** new tests this pass.

Standing rules applied. **Findings: 0.**

---

## 1. Duplicate agentId rebind

**Why not R1:** R1 #12 was two agentIds / one UBID. This is the inverse: one agentId / two bindings.

**Verdict: DEFENDED-BY-DESIGN** (identityRegistry is a trusted unique-id issuer).

**Test:** `test/security/GrokR2_1_DuplicateAgentIdRebind.t.sol`

**Success condition:** a second register overwrites `_bindings[agentId]` so Alice's identity is captured.

**What happened.** `OverflowRegistry` returns `type(uint256).max` from every `register`. Alice then Bob both get that id. `_register` writes `_bindings[agentId]` unconditionally (`Adapter8004.sol:162`). Bob's binding wins; `isController` follows the live binding, so Alice is out. Production ERC-8004 registries increment and do not collide. An attacker cannot swap the immutable `identityRegistry` (`:88`, `:100-106`). Missing uniqueness is defense-in-depth against a buggy registry, not a mountable attack.

---

## 2. Stray NFT receive

**Why not R1:** Round 1 §5 cut this as griefing and never executed it.

**Verdict: DEFENDED.** `onERC721Received` (`:293-296`) accepts the transfer; `bindingOf(99)` reverts `UnknownAgent`; `isController` is false.

**Test:** `test/security/GrokR2_2_StrayNftReceive.t.sol`

**Success condition:** a stranger parks an unrelated NFT on the adapter and forges a binding for it.

---

## 3. Batch reserved-key atomicity

**Why not R1:** R1 #18 was single-key normalization. This is `setMetadataBatch` partial commit.

**Verdict: DEFENDED.** `_requireNoReservedBindingKey` (`:229-230`, `:900-908`) runs before any registry write in the loop (`:233-237`). Whole tx reverts `ReservedMetadataKey`. First key `"ok"` is not stored. Canonical `agent-binding` unchanged.

**Test:** `test/security/GrokR2_3_BatchReservedAtomicity.t.sol`

---

## 4. Register-time reserved metadata

**Why not R1:** R1 #18 was post-register `setMetadata`. This is the `register(..., metadata)` array.

**Verdict: DEFENDED.** `_requireNoReservedBindingKey` (`:150`) runs *before* `identityRegistry.register` (`:155-159`). Revert `ReservedMetadataKey`. `bindingOf(0)` is `UnknownAgent` — no mint.

**Test:** `test/security/GrokR2_4_RegisterReservedMetadata.t.sol`

---

## 5. Unbound view forwarding

**Why not R1:** R1 #2 was `isController` totality on *bound* agents. This is view/`UnknownAgent` skew on a raw registry id.

**Verdict: DEFENDED.** `ownerOf`/`getMetadata`/`tokenURI`/`getAgentWallet` (`:174-184`) forward without `_knownBinding`. `isController` (`:284-286`) returns false. `bindingOf`/`bindingHashOf`/`setAgentURI` revert `UnknownAgent`. No wrong bool.

**Test:** `test/security/GrokR2_5_UnboundViewForwarding.t.sol`

---

## 6. Cross-proxy UBID collision

**Why not R1:** R1 #13 was one adapter, chainid in/out. This is two proxies, one chain, one token.

**Verdict: DEFENDED.** `_bindingHashFrom` (`:961-968`) includes `interoperableAddress(address(this))` (`:929-930`). Two proxies, two UBIDs.

**Test:** `test/security/GrokR2_6_CrossProxyUbid.t.sol`

---

## 7. abi.encode word alignment

**Why not R1:** R1 #11 was unvalidated `(ACCOUNT, x, 7)` coordinates. This is packed second-preimage of `address` vs `tokenId`.

**Verdict: DEFENDED.** `abi.encode` (never packed, `:959-967`) puts `boundAddress` and `tokenId` in separate 32-byte words. `hashBinding(ERC721, address(1), 0) != hashBinding(ERC721, address(0), 1<<160)`. Standard is its own word too.

**Test:** `test/security/GrokR2_7_EncodePreimage.t.sol`

---

## 8. ACCOUNT tokenId = uint256.max

**Why not R1:** R1 #11 used `tokenId=7`. This is the integer edge on the same canonical-id guard.

**Verdict: DEFENDED.** `_requireCanonicalTokenId` (`:736-738`) reverts `NonZeroTokenIdForAccount(victim, max)` before control. Phantom UBID ≠ canonical `(victim, 0)`. Victim still registers `tokenId=0`.

**Test:** `test/security/GrokR2_8_MaxTokenIdAccount.t.sol`

---

## 9. chainid 0

**Why not R1:** R1 #13 used nonzero chainids. ERC-7930 forbids chainid 0.

**Verdict: DEFENDED.** `_erc7930AddressFor` (`:953`) reverts `InvalidChainId` on `hashBinding`, `interoperableAddress`, and `chainIdentifier`.

**Test:** `test/security/GrokR2_9_ChainIdZero.t.sol`

---

## 10. Upgrade-and-reinitialize

**Why not R1:** R1 #20 was `RegistryMismatch` / lying getter. This is `upgradeToAndCall(initialize(attacker))`.

**Verdict: DEFENDED.** `upgradeToAndCall` with `initialize(attacker)` reverts `InvalidInitialization`. Owner stays admin. Whole tx reverts so the impl swap does not land.

**Test:** `test/security/GrokR2_10_UpgradeReinit.t.sol`

---

## 11. Dead slot 0

**Why not R1:** R1 #20 read `identityRegistry()` on the incoming impl. This is proxy slot 0 vs the immutable getter.

**Verdict: DEFENDED.** Fresh proxy slot 0 is `0` (`__deadRegistrySlot`, `:90-94`). Getter returns the immutable registry. A storage reader cannot treat slot 0 as a mutable registry pointer the owner can swap.

**Test:** `test/security/GrokR2_11_DeadSlot0.t.sol`

---

## 12. Registry write reentrancy

**Why not R1:** Round 1 / existing suite reentered via `ownerOf` STATICCALL. This is `setAgentURI` → registry → `setAgentURI`.

**Verdict: DEFENDED.** `setAgentURI` is `nonReentrant` (`:190`). Callback reverts `ReentrancyGuardReentrantCall`. URI is not overwritten.

**Test:** `test/security/GrokR2_12_RegistryReenterWrite.t.sol`

---

## 13. Empty metadata key

**Why not R1:** R1 #18 used `"Agent-Binding"` / whitespace / NUL. This is `""`.

**Verdict: DEFENDED.** `keccak256("") != BINDING_METADATA_KEY_HASH` (`:46-47`, `:210-211`). Empty key stores a different slot. Canonical `agent-binding` remains `abi.encodePacked(adapter)`.

**Test:** `test/security/GrokR2_13_EmptyMetadataKey.t.sol`

---

## 14. Counterfactual batch reserved key

**Why not R1:** R1 #14 was unminted per-key plant. This is reserved key inside `counterfactualSetMetadataBatch`.

**Verdict: DEFENDED.** `_requireNoReservedBindingKey` (`:441`) before emit (`:446-447`). Revert `ReservedMetadataKey`. No `CounterfactualMetadataBatchSet`.

**Test:** `test/security/GrokR2_14_CfBatchReserved.t.sol`

---

## 15. Attestation type in preimage

**Why not R1:** R1 #17 was stranger `revoke` ordering. This is `CONFIRM_ACCOUNT` vs `RATING` with empty payload sharing an id.

**Verdict: DEFENDED.** `_attest` (`:610-614`) includes `attestationType` in the identifier. Two events, two ids.

**Test:** `test/security/GrokR2_15_AttestationTypePreimage.t.sol`

---

## 16. tokenId max vs 0

**Why not R1:** R1 #12 was duplicate *same* coordinate. This is max vs 0 on one ERC-721.

**Verdict: DEFENDED.** Distinct UBIDs, distinct `agentId`s, `bindingHashOf` matches each coordinate.

**Test:** `test/security/GrokR2_16_MaxVsZeroTokenId.t.sol`

---

## 17. hashBinding vs bindingHashOf

**Why not R1:** Round 1 never asked whether a live row's stored hash diverges from the public helper.

**Verdict: DEFENDED.** After register, `bindingHashOf(agentId) == hashBinding(standard, boundAddress, tokenId)` of `bindingOf`. No identity skew.

**Test:** `test/security/GrokR2_17_HashBindingMatchesStored.t.sol`

---

## 18. CONTRACT_OWNABLE bound to the adapter

**Why not R1:** R1 #4 was a hostile `owner()` on an external contract. This binds `CONTRACT_OWNABLE` to the adapter proxy itself.

**Verdict: DEFENDED.** `_currentContractOwner` (`:842-857`) reads adapter `owner()` = admin. Stranger `isController` false; `setAgentURI` reverts `NotController`. Bound address itself is not an authority under this standard (`:786-794`).

**Test:** `test/security/GrokR2_18_BindAdapterOwnable.t.sol`

---

## 19. Metadata-array register still unsets wallet

**Why not R1:** Round 1 never compared the two `_register` overloads for the default-wallet clear (`:167-168`).

**Verdict: DEFENDED.** `register(uri, metadata)` still `unsetAgentWallet`. `getAgentWallet` is `address(0)`. User key `"k"` and reserved `agent-binding` both correct.

**Test:** `test/security/GrokR2_19_MetadataRegisterClearsWallet.t.sol`

---

## 20. chainIdentifier vs address(0) envelope

**Why not R1:** R1 #13 hashed `interoperableAddress(adapter)`. This is `chainIdentifier()` colliding with `interoperableAddress(address(0))`.

**Verdict: DEFENDED.** ERC-7930 address-length byte differs (`:933-941`, `:948-956`). Three envelopes, three hashes, `chain.length != zeroAddr.length`.

**Test:** `test/security/GrokR2_20_ChainVsAddressEnvelope.t.sol`

---

## Tally

| Verdict | Count |
|---|---|
| DEFENDED | 19 |
| DEFENDED-BY-DESIGN | 1 (#1, trusted registry id uniqueness) |
| FINDINGS | 0 |

New tests: **20**. Full suite: **453 passing**.
