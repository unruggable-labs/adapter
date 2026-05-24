# Adapter8004 `counterfactualRegisterWithSig` Final Spec

## Status

Final design spec only. Do not treat this document as implementation approval.

This method is a new external entry point on a Safe-owned UUPS proxy and extends the experimental counterfactual surface. A fresh security review and audit pass are a required gate before any implementation upgrade is proposed to, approved by, or deployed from the multisig.

## Summary

Add `counterfactualRegisterWithSig`, a signature-authorized counterfactual registration method for token-bound agents across ERC-721, ERC-1155, ERC-6909, ERC-1155F, and ERC-6909F. The token holder signs one EIP-712 payload authorizing:

- the counterfactual registration claim;
- the full initial URI and metadata payload;
- an optional bundled agent wallet, using `address(0)` as the native ERC-8004 unset sentinel;
- a bounded expiration.

Anyone can submit the signed payload: a relayer, router, NFT mint function, or any other caller. The adapter remains the single event emitter, so indexers continue to trust one audited event surface rather than every NFT contract reimplementing the counterfactual ABI.

The signed call performs a full initial counterfactual registration in one shot: `agentURI`, the complete `metadata` array, and the optional `agentWallet`, all bound by the owner signature.

The signed path is intentionally narrower than the existing unsigned counterfactual surface in v1:

- strict direct-holder signature only;
- one full initial registration per call (URI + metadata + wallet); no standalone signed setters for later per-field updates;
- no nonce.

## Purpose and Update Path

This method exists for one reason: to solve the register-at-mint problem. During an NFT mint (or any router/relayer flow), `msg.sender` is the minting contract or relayer, not the token owner, so the owner-gated unsigned `counterfactualRegister` cannot be called. The owner signature decouples the authorizer from the caller, letting the registration be folded into the mint transaction. It is a one-time bootstrap, not the update mechanism.

After registration, individual records are updated through the existing unsigned counterfactual setters, gated by `_requireBindingControl`, which allows the current owner or an ERC-721/ERC-1155F/ERC-6909F delegate.xyz hot wallet to act as `msg.sender`:

- `counterfactualSetAgentURI`
- `counterfactualSetMetadata` / `counterfactualSetMetadataBatch`
- `counterfactualSetAgentWallet` / `counterfactualUnsetAgentWallet`

Because counterfactual claims are latest-event-wins per `(tokenContract, tokenId)`, the owner can also re-sign a fresh full `counterfactualRegisterWithSig` to overwrite everything at once. Either way, no signature-authorized per-field setters are needed: the only thing the signature ever solved was the mint-time sender mismatch.

## Final Decisions

1. **Delegate.xyz v2 hot-wallet signatures are out of scope for v1.**

   The signer MUST directly control the token: ERC-721, ERC-1155F, and ERC-6909F require `ownerOf(tokenId) == owner`; ERC-1155 and ERC-6909 require `balanceOf(owner, tokenId) > 0`. Allowing a delegate.xyz hot wallet to sign would introduce a second revocation domain: a delegation can be revoked without a token transfer, but previously signed payloads would still replay until expiration unless nonce or delegation-state binding were added. Direct-holder-only is the right v1 surface.

   Existing unsigned counterfactual methods still use `_requireBindingControl`, so delegate.xyz remains supported there.

2. **No standalone signed URI or metadata setters in v1.**

   `counterfactualRegisterWithSig` performs a full initial registration in one owner signature: `agentURI`, the complete `metadata` array, and the optional `agentWallet`. Metadata is in scope and bound by the signature; the only thing deferred is *signature-authorized per-field setters for later updates* (`counterfactualSetAgentURIWithSig`, `counterfactualSetMetadataWithSig`, `counterfactualSetMetadataBatchWithSig`). Those are unnecessary because, after registration, the owner or a single-owner-standard delegate updates individual records directly through the existing unsigned setters (see "Purpose and Update Path"), and the signature only ever solved the mint-time sender mismatch. They can be added later as separate specs if a relayed-update need appears.

3. **All five standards are supported through direct-holder control.**

   The signature authenticates which holder authorized the event, and the adapter checks that holder's direct token control at submission time. ERC-721, ERC-1155F, and ERC-6909F use current `ownerOf(tokenId)` ownership; ERC-1155 and ERC-6909 use positive balance. The signed path still does not call `_requireBindingControl`, because that helper allows delegate.xyz for single-owner standards and the signed path must remain direct-holder-only.

4. **EIP-712 domain is `name = "Adapter8004"`, `version = "1"`.**

   This domain name identifies the adapter, not the underlying ERC-8004 identity registry. Version `1` is the first typed-data domain for this adapter method family. The domain is computed statelessly from constants, `block.chainid`, and `address(this)`.

## Final Function Signature

Add this function to `Adapter8004` and to `IERC8004AdapterCounterfactual`:

```solidity
function counterfactualRegisterWithSig(
    TokenStandard standard,
    address tokenContract,
    uint256 tokenId,
    string calldata agentURI,
    IERC8004IdentityRegistry.MetadataEntry[] calldata metadata,
    address agentWallet,
    address owner,
    uint256 expiration,
    bytes calldata signature
) external nonReentrant returns (bytes32 computedHash);
```

Parameter semantics:

- `standard`: token standard being claimed. Supported values are `TokenStandard.ERC721`, `TokenStandard.ERC1155`, `TokenStandard.ERC6909`, `TokenStandard.ERC1155F`, and `TokenStandard.ERC6909F`.
- `tokenContract`: token contract being claimed. Reuses the existing counterfactual token-contract validation.
- `tokenId`: token id being claimed.
- `agentURI`: initial counterfactual agent URI.
- `metadata`: initial counterfactual metadata entries. The reserved counterfactual keys remain forbidden.
- `agentWallet`: optional wallet claim. `address(0)` means unset and emits no wallet event. Any nonzero value emits a bundled `CounterfactualAgentWalletSet`.
- `owner`: claimed authorizer and EIP-712 signer. It is passed explicitly because ERC-1271 verification requires the claimed signer address up front.
- `expiration`: absolute timestamp. MUST be no more than `MAX_EXPIRATION_DELAY` seconds after `block.timestamp`.
- `signature`: owner signature over the EIP-712 digest. Supports EOAs and ERC-1271 contract wallets via OpenZeppelin `SignatureChecker`.

Constant:

```solidity
uint256 private constant MAX_EXPIRATION_DELAY = 30 minutes;
```

## EIP-712 Domain and Typehashes

The implementation MUST compute the EIP-712 domain separator inline. Do not add storage, do not cache the separator, and do not add a reinitializer.

Exact domain type string:

```solidity
"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
```

Exact constants:

```solidity
bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
);

string private constant EIP712_NAME = "Adapter8004";
string private constant EIP712_VERSION = "1";
```

Domain separator:

```solidity
function _domainSeparator() internal view returns (bytes32) {
    return keccak256(
        abi.encode(
            EIP712_DOMAIN_TYPEHASH,
            keccak256(bytes(EIP712_NAME)),
            keccak256(bytes(EIP712_VERSION)),
            block.chainid,
            address(this)
        )
    );
}
```

Exact signed struct type string:

```solidity
"CounterfactualRegister(uint8 standard,address tokenContract,uint256 tokenId,bytes32 agentURIHash,bytes32 metadataHash,address agentWallet,address owner,uint256 expiration)"
```

Exact signed struct typehash:

```solidity
bytes32 private constant COUNTERFACTUAL_REGISTER_TYPEHASH = keccak256(
    "CounterfactualRegister(uint8 standard,address tokenContract,uint256 tokenId,bytes32 agentURIHash,bytes32 metadataHash,address agentWallet,address owner,uint256 expiration)"
);
```

The signed struct intentionally uses `bytes32 agentURIHash` and `bytes32 metadataHash` rather than embedding dynamic strings, bytes, and arrays directly in the primary type. This keeps wallet-side encoding simple while preserving full payload binding.

Exact metadata entry type string:

```solidity
"MetadataEntry(string metadataKey,bytes metadataValue)"
```

Exact metadata entry typehash:

```solidity
bytes32 private constant METADATA_ENTRY_TYPEHASH = keccak256(
    "MetadataEntry(string metadataKey,bytes metadataValue)"
);
```

Metadata array hashing MUST follow the EIP-712 array rule: hash each encoded entry, concatenate the entry hashes, then hash the concatenation.

```solidity
function _hashMetadata(IERC8004IdentityRegistry.MetadataEntry[] calldata entries)
    internal
    pure
    returns (bytes32)
{
    bytes32[] memory hashes = new bytes32[](entries.length);
    for (uint256 i; i < entries.length; ++i) {
        hashes[i] = keccak256(
            abi.encode(
                METADATA_ENTRY_TYPEHASH,
                keccak256(bytes(entries[i].metadataKey)),
                keccak256(entries[i].metadataValue)
            )
        );
    }
    return keccak256(abi.encodePacked(hashes));
}
```

Struct hash:

```solidity
bytes32 structHash = keccak256(
    abi.encode(
        COUNTERFACTUAL_REGISTER_TYPEHASH,
        standard,
        tokenContract,
        tokenId,
        keccak256(bytes(agentURI)),
        _hashMetadata(metadata),
        agentWallet,
        owner,
        expiration
    )
);
```

Digest:

```solidity
bytes32 digest = MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash);
```

## Events

Do not add new events for v1. Reuse the existing counterfactual events in `IERC8004AdapterCounterfactual`.

Always emit `CounterfactualAgentRegistered` on success:

```solidity
event CounterfactualAgentRegistered(
    bytes32 indexed registrationHash,
    address indexed tokenContract,
    uint256 indexed tokenId,
    uint8 version,
    IERCAgentBindings.TokenStandard standard,
    string agentURI,
    IERC8004IdentityRegistry.MetadataEntry[] metadata,
    address emitter
);
```

When `agentWallet != address(0)`, also emit `CounterfactualAgentWalletSet`:

```solidity
event CounterfactualAgentWalletSet(
    bytes32 indexed registrationHash,
    address indexed tokenContract,
    uint256 indexed tokenId,
    uint8 version,
    address newWallet,
    address emitter
);
```

Emitter semantics:

- unsigned `counterfactualRegister`: `emitter = msg.sender`;
- signed `counterfactualRegisterWithSig`: `emitter = owner`;
- relayer or router address is deliberately not emitted as the counterfactual authorizer.

For both events emitted by the signed path:

- `registrationHash` MUST equal `_registrationHash(standard, tokenContract, tokenId)`;
- `version` MUST equal `COUNTERFACTUAL_PAYLOAD_VERSION`;
- `emitter` MUST equal `owner`.

## Errors

New errors:

```solidity
error ExpirationTooFar(uint256 expiration);
error SignatureExpired(uint256 expiration);
error InvalidSignature();
```

Reused errors:

```solidity
error InvalidTokenContract();
error InvalidTokenContractIsRegistry();
error ReservedMetadataKey(string metadataKey);
error NotController(address account, uint256 agentId);
```

Revert taxonomy:

- `ExpirationTooFar(expiration)`: `expiration > block.timestamp + MAX_EXPIRATION_DELAY`.
- `SignatureExpired(expiration)`: `block.timestamp > expiration`.
- `InvalidTokenContract()`: `tokenContract == address(0)`.
- `InvalidTokenContractIsRegistry()`: `tokenContract == address(identityRegistry)`.
- `ReservedMetadataKey(metadataKey)`: any metadata entry key is `agent-binding` or `cf-registration`.
- `NotController(owner, type(uint256).max)`: direct-control check fails for the supplied standard and owner.
- `InvalidSignature()`: `SignatureChecker.isValidSignatureNow(owner, digest, signature)` returns false.

The exact check order below defines which error wins when multiple inputs are invalid.

## Step-by-Step Flow

1. Enforce the expiration cap, then expiry:

   ```solidity
   if (expiration > block.timestamp + MAX_EXPIRATION_DELAY) revert ExpirationTooFar(expiration);
   if (block.timestamp > expiration) revert SignatureExpired(expiration);
   ```

   `MAX_EXPIRATION_DELAY = 30 minutes`.

2. Validate `tokenContract`:

   ```solidity
   _requireValidTokenContract(tokenContract);
   ```

3. Reject reserved counterfactual metadata keys:

   ```solidity
   _requireNoReservedCounterfactualKeys(metadata);
   ```

4. Require the signer to directly control the token:

   ```solidity
   _requireDirectControl(standard, tokenContract, tokenId, owner);
   ```

   `_requireDirectControl` checks `ownerOf(tokenId) == owner` for ERC-721, ERC-1155F, and ERC-6909F, `IERC1155(tokenContract).balanceOf(owner, tokenId) > 0` for ERC-1155, and `IERC6909(tokenContract).balanceOf(owner, tokenId) > 0` for ERC-6909. Do not call `_requireBindingControl` here. That helper would allow delegate.xyz for single-owner standards, and the signed path is intentionally direct-holder-only.

5. Build the EIP-712 digest using the domain and struct hashes specified above.

6. Verify the owner signature:

   ```solidity
   if (!SignatureChecker.isValidSignatureNow(owner, digest, signature)) {
       revert InvalidSignature();
   }
   ```

   `SignatureChecker` supports EOAs and ERC-1271 contract owners. The implementation imports OpenZeppelin `SignatureChecker` and `MessageHashUtils`.

8. Compute the registration hash:

   ```solidity
   computedHash = _registrationHash(standard, tokenContract, tokenId);
   ```

9. Emit `CounterfactualAgentRegistered`:

   ```solidity
   emit CounterfactualAgentRegistered(
       computedHash,
       tokenContract,
       tokenId,
       COUNTERFACTUAL_PAYLOAD_VERSION,
       standard,
       agentURI,
       metadata,
       owner
   );
   ```

10. If `agentWallet != address(0)`, emit `CounterfactualAgentWalletSet`:

    ```solidity
    if (agentWallet != address(0)) {
        emit CounterfactualAgentWalletSet(
            computedHash,
            tokenContract,
            tokenId,
            COUNTERFACTUAL_PAYLOAD_VERSION,
            agentWallet,
            owner
        );
    }
    ```

11. Return `computedHash`.

No ERC-8004 registry call, adapter binding write, wallet write, metadata write, nonce write, or other `SSTORE` is part of this method.

## Bundled Agent Wallet

`agentWallet` is covered by the owner signature. A nonzero value emits a counterfactual wallet claim in the same call. `address(0)` is the ERC-8004 unset sentinel and emits no wallet event.

The signed counterfactual path MUST NOT collect a wallet-consent signature. This matches the existing `counterfactualSetAgentWallet` model:

- real ERC-8004 `setAgentWallet` requires consent from the new wallet because it creates a canonical on-chain binding;
- counterfactual wallet setting is soft-state only and emits an event gated by token control;
- promotion from counterfactual state to real on-chain ERC-8004 registration remains the wallet-consent checkpoint.

Accepted property: a counterfactual claim can name a wallet that never consented. That property already exists on the unsigned counterfactual wallet setter and cannot silently become a real wallet binding without the wallet's own promotion-time consent signature.

## Replay and Freshness Analysis

No nonce is used.

Cross-chain replay is blocked by the EIP-712 domain `chainId`.

Cross-adapter replay is blocked by the EIP-712 domain `verifyingContract = address(this)` and by the existing `_registrationHash` domain.

Cross-token replay is blocked by the signed `standard`, `tokenContract`, and `tokenId`.

Payload tampering is blocked because `agentURIHash`, `metadataHash`, `agentWallet`, `owner`, and `expiration` are all signed.

Replay is bounded for all supported standards by `MAX_EXPIRATION_DELAY = 30 minutes`.

For ERC-721, former-owner replay is additionally blocked by transfer freshness. Once the token transfers, `ownerOf(tokenId) != owner` and the old owner's signature reverts with `NotController(owner, type(uint256).max)`.

For ERC-1155 and ERC-6909, a signature remains valid only while the signer still holds a positive balance for the signed token id. If the signer transfers away all balance, the old signature reverts with `NotController(owner, type(uint256).max)`. If the signer keeps or reacquires a positive balance, replay remains bounded by the signed expiration cap.

This does not introduce a new attack compared with the existing unsigned counterfactual surface, which already lets any positive-balance ERC-1155 or ERC-6909 holder emit counterfactual events for the bound token id.

Identical replay during the same owner's tenure is allowed and idempotent. It emits the same claim again. Indexers already use latest-event-wins semantics per counterfactual key, so duplicate payloads do not corrupt adapter or registry state.

Superseded replay during the same holder's control period is the accepted edge. An old signed payload can be resubmitted after the holder signs a newer payload, as long as the old expiration has not expired and the holder still directly controls the token. The relayer pays gas and can only roll the soft-state event stream back to a payload the current holder previously signed. The `MAX_EXPIRATION_DELAY = 30 minutes` cap bounds this window. Adding single-use semantics would require storage, likely `mapping(bytes32 digest => bool used)`, and is intentionally rejected for v1.

Delegate revocation replay is avoided by direct-holder-only v1. Because delegate.xyz signers are not accepted, the method does not need to bind signatures to delegation state or delegation revocation timing.

## Upgrade Safety

The implementation MUST be storage-layout neutral:

- no new storage variables;
- no cached domain separator;
- no nonce mapping;
- no reinitializer;
- no change to existing storage slots or ERC-7201 namespaces.

The ABI change is additive: one new function and four new custom errors. Existing counterfactual event topics are reused unchanged. Existing indexers that ignore unknown function selectors continue to work; indexers that already consume `CounterfactualAgentRegistered` and `CounterfactualAgentWalletSet` only need to account for `emitter = owner` on the signed path.

External calls in the signed path:

- `IERC721(tokenContract).ownerOf(tokenId)` for ERC-721 direct ownership;
- `IERC1155(tokenContract).balanceOf(owner, tokenId)` for ERC-1155 direct positive-balance control;
- `IERC6909(tokenContract).balanceOf(owner, tokenId)` for ERC-6909 direct positive-balance control;
- `SignatureChecker.isValidSignatureNow(owner, digest, signature)`, which may `staticcall` `owner` if it is a contract.

The method MUST remain `nonReentrant`, consistent with the rest of the counterfactual surface.

Because this is a Safe-owned UUPS contract and the counterfactual surface is experimental, implementation MUST go through a fresh security review and audit pass before multisig deployment.

## Interface Placement

`counterfactualRegisterWithSig` belongs in `IERC8004AdapterCounterfactual` alongside `registrationHash`, `counterfactualPayloadVersion`, and the counterfactual event declarations. Although the interface comment currently describes an event-only surface, the signed entry point should be declared there so callers, tests, and indexers can type against the counterfactual family without importing the full adapter.

## Foundry Test Plan

Add a focused test file, preferably:

```text
test/security/Adapter8004.counterfactual-with-sig.t.sol
```

Required tests:

1. `testCounterfactualRegisterWithSigEOAHappyPathRelayer`

   Owner signs. A different `msg.sender` submits. Function returns the expected `registrationHash`. `CounterfactualAgentRegistered` emits with `emitter == owner`, not relayer.

2. `testCounterfactualRegisterWithSigEOAWithBundledWallet`

   Nonzero `agentWallet` emits both `CounterfactualAgentRegistered` and `CounterfactualAgentWalletSet`. Both events use the same `registrationHash`, version `1`, and `emitter == owner`.

3. `testCounterfactualRegisterWithSigZeroWalletEmitsOnlyRegistration`

   `agentWallet == address(0)` succeeds and emits no wallet event.

4. `testCounterfactualRegisterWithSigERC1271OwnerHappyPath`

   The ERC-721 owner is an ERC-1271 contract wallet returning the magic value for the digest. A relayer submits successfully.

5. `testCounterfactualRegisterWithSigRejectsBadERC1271Signature`

   ERC-1271 owner returns the wrong value or rejects the digest. Reverts with `InvalidSignature`.

6. `testCounterfactualRegisterWithSigExpiredExpiration`

   `block.timestamp > expiration` reverts with `SignatureExpired(expiration)`.

7. `testCounterfactualRegisterWithSigExpirationTooFar`

   `expiration > block.timestamp + 30 minutes` reverts with `ExpirationTooFar(expiration)`.

8. `testCounterfactualRegisterWithSigAtExpirationSucceeds`

   `block.timestamp == expiration` is accepted.

9. `testCounterfactualRegisterWithSigAtMaxExpirationSucceeds`

   `expiration == block.timestamp + 30 minutes` is accepted.

10. `testCounterfactualRegisterWithSigNonOwnerSignerRejected`

    Signature is valid for a non-owner, but `owner != ownerOf(tokenId)`. Reverts with `NotController(owner, type(uint256).max)`.

11. `testCounterfactualRegisterWithSigFormerOwnerReplayAfterTransferRejected`

    Alice signs while she owns the token. Token transfers to Bob. Alice's signed payload reverts with `NotController(alice, type(uint256).max)`.

12. `testCounterfactualRegisterWithSigIdenticalReplayDuringTenureEmitsAgain`

    Same signature submitted twice while the owner still owns the token. Both submissions succeed and emit identical events.

13. `testCounterfactualRegisterWithSigSupersededReplayAllowedUntilExpiration`

    Owner signs payload A and payload B. B is submitted, then A is replayed before expiry. A succeeds. The test documents the accepted latest-event-wins behavior.

14. `testCounterfactualRegisterWithSigSupersededReplayRejectedAfterExpiration`

    Same setup as above, but warp beyond A's expiration. A reverts with `SignatureExpired`.

15. `testCounterfactualRegisterWithSigRejectsTamperedAgentURI`

    Sign URI A, submit URI B. Reverts with `InvalidSignature`.

16. `testCounterfactualRegisterWithSigRejectsTamperedMetadataValue`

    Sign metadata A, submit metadata B. Reverts with `InvalidSignature`.

17. `testCounterfactualRegisterWithSigRejectsTamperedMetadataOrder`

    Sign metadata entries in one order, submit the same entries in a different order. Reverts with `InvalidSignature`.

18. `testCounterfactualRegisterWithSigRejectsTamperedTokenId`

    Sign token id A, submit token id B. Reverts with `InvalidSignature` if `ownerOf(B) == owner`, otherwise `NotController`; write the fixture so ownership passes and signature binding is isolated.

19. `testCounterfactualRegisterWithSigRejectsTamperedWallet`

    Sign wallet A, submit wallet B. Reverts with `InvalidSignature`.

20. `testCounterfactualRegisterWithSigRejectsTamperedExpiration`

    Sign expiration A, submit expiration B. Reverts with `InvalidSignature` when expiration B is otherwise valid.

21. `testCounterfactualRegisterWithSigRejectsCrossChainDigest`

    Signature produced with a different `chainId` is rejected by this chain's domain.

22. `testCounterfactualRegisterWithSigRejectsCrossAdapterDigest`

    Signature produced for adapter A is rejected by adapter B because `verifyingContract` differs.

23. `testCounterfactualRegisterWithSigRejectsZeroTokenContract`

    `tokenContract == address(0)` reverts with `InvalidTokenContract`.

24. `testCounterfactualRegisterWithSigRejectsRegistryAsTokenContract`

    `tokenContract == address(identityRegistry)` reverts with `InvalidTokenContractIsRegistry`.

25. `testCounterfactualRegisterWithSigRejectsReservedAgentBindingMetadata`

    Metadata key `agent-binding` reverts with `ReservedMetadataKey("agent-binding")`.

26. `testCounterfactualRegisterWithSigRejectsReservedCfRegistrationMetadata`

    Metadata key `cf-registration` reverts with `ReservedMetadataKey("cf-registration")`.

27. `testCounterfactualRegisterWithSigERC1155HappyPathRelayerWithBundledWallet`

    Positive-balance holder signs an ERC-1155 payload, a different relayer submits, `emitter == owner`, and an optional bundled wallet emits both counterfactual events.

28. `testCounterfactualRegisterWithSigERC6909HappyPathRelayer`

    Positive-balance holder signs an ERC-6909 payload, a different relayer submits, and `emitter == owner`.

29. `testCounterfactualRegisterWithSigERC1155ZeroBalanceRevertsNotController`

    ERC-1155 signer with zero balance reverts with `NotController`.

30. `testCounterfactualRegisterWithSigERC6909ZeroBalanceRevertsNotController`

    ERC-6909 signer with zero balance reverts with `NotController`.

31. `testCounterfactualRegisterWithSigERC1155OldSignatureFailsAfterBalanceTransferredAway`

    ERC-1155 signer transfers away all balance after signing; the old signature reverts with `NotController`.

32. `testCounterfactualRegisterWithSigERC6909OldSignatureFailsAfterBalanceTransferredAway`

    ERC-6909 signer transfers away all balance after signing; the old signature reverts with `NotController`.

33. `testCounterfactualRegisterWithSigRejectsDelegateSigner`

    Configure a delegate.xyz v2 hot-wallet delegation if test infrastructure supports it, or mock the registry path used by existing tests. A valid hot-wallet signature MUST revert because the signer is not `ownerOf(tokenId)`.

34. `testCounterfactualRegisterWithSigMetadataHashingNonEmptyArray`

    Non-empty metadata array signs, verifies, emits unchanged, and preserves dynamic bytes values.

35. `testCounterfactualRegisterWithSigEmptyMetadataHashMatchesEIP712ArrayRule`

    Empty metadata signs and verifies using `keccak256(abi.encodePacked(new bytes32[](0)))`, i.e. `keccak256("")`.

32. `testCounterfactualRegisterWithSigHasNoRegistryOrAdapterSideEffects`

    Assert no ERC-8004 registry mint, no registry metadata write, no registry wallet write, no adapter `_bindings` write, and no observable state mutation beyond emitted logs. Mirror the existing `testAllCounterfactualSettersHaveNoRegistryOrAdapterSideEffects`.

33. `testCounterfactualRegisterWithSigDomainNameAndVersion`

    Build the digest in the test using `name = "Adapter8004"` and `version = "1"` and prove it verifies. A digest built with any other name or version reverts with `InvalidSignature`.

34. `testCounterfactualRegisterWithSigExactTypehashes`

    Assert implementation constants, if exposed through a harness, equal:

    ```text
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    keccak256("CounterfactualRegister(uint8 standard,address tokenContract,uint256 tokenId,bytes32 agentURIHash,bytes32 metadataHash,address agentWallet,address owner,uint256 expiration)")
    keccak256("MetadataEntry(string metadataKey,bytes metadataValue)")
    ```

35. `testCounterfactualRegisterWithSigReentrancyGuardCoversOwnerOf`

    A malicious ERC-721 attempts to reenter during `ownerOf`. The call reverts with the OpenZeppelin reentrancy guard error, matching the existing counterfactual reentrancy pattern.

36. `testCounterfactualRegisterWithSigReentrancyGuardCoversERC1271`

    A malicious ERC-1271 owner attempts to reenter during `isValidSignature`. The call reverts with the OpenZeppelin reentrancy guard error.

37. `testCounterfactualRegisterWithSigDoesNotRequireWalletConsent`

    Use an `agentWallet` that would reject ERC-1271 or has no code. The registration still succeeds because wallet consent is not checked on the counterfactual path.

38. `testCounterfactualRegisterWithSigReturnHashMatchesPublicRegistrationHash`

    Return value equals `adapter.registrationHash(TokenStandard.ERC721, tokenContract, tokenId)`.

## Implementation Notes

Use OpenZeppelin:

```solidity
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
```

Do not import or call delegate.xyz from this method.

Do not write implementation as part of this spec task.
