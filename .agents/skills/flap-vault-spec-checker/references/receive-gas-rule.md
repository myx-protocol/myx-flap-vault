# Rule: `receive()` Gas Limit ≤ 1,000,000 Gas

## Background

The Flap Portal forwards BNB tax revenue to a vault by sending a plain BNB transfer. Solidity's `receive()` fallback is invoked on every such transfer. If `receive()` is unexpectedly expensive, the forwarding transaction can run out of gas, **permanently disabling tax collection** for the token.

## The Rule

> The `receive()` function **MUST** consume at most **1,000,000 gas** in all code paths, including worst-case inputs.

1,000,000 gas is a generous budget. A well-written `receive()` should use far less (typically < 50,000 gas). The limit exists to prevent catastrophic foot-guns — not to encourage using the full budget.

## Gas Cost Reference

| Operation | Approximate Gas |
|---|---|
| Empty `receive() {}` | ~2,100 |
| Single `SSTORE` (cold slot) | ~20,000 |
| Single `SSTORE` (warm slot) | ~2,900 |
| Single `SLOAD` (cold) | ~2,100 |
| External `call` (empty) | ~21,000 base |
| `emit Event(...)` per topic | ~375 |
| Loop iteration (simple add) | ~200–500 per iteration |

A `receive()` that does a handful of storage updates and emits an event is roughly 30,000–60,000 gas — well within budget.

## Non-Compliant Patterns

```solidity
// ❌ Distributes BNB inside receive() — unbounded external calls
receive() external payable {
    for (uint256 i = 0; i < recipients.length; i++) {
        recipients[i].transfer(msg.value / recipients.length);
    }
}

// ❌ Calls a complex DeFi protocol inside receive()
receive() external payable {
    swapRouter.swapExactBNBForTokens{value: msg.value}(...);
}

// ❌ Triggers an arbitrarily-complex callback chain
receive() external payable {
    IComplexProtocol(externalContract).depositAndRebalance(msg.value);
}
```

## Compliant Patterns

```solidity
// ✅ Accept and accumulate — nothing else
receive() external payable {}

// ✅ Track total received
receive() external payable {
    totalReceived += msg.value;
}

// ✅ Emit an event for off-chain indexing
receive() external payable {
    emit Received(msg.sender, msg.value);
}

// ✅ Update a per-epoch accumulator (bounded SSTORE)
receive() external payable {
    epochs[currentEpoch].accumulated += msg.value;
}
```

## Remediation

Move heavy distribution or swap logic into a separate function:

```solidity
// Accumulate in receive()
receive() external payable {
    pendingDistribution += msg.value;
}

// Execute distribution separately (keeper / guardian / public)
function distribute() external {
    uint256 amount = pendingDistribution;
    pendingDistribution = 0;
    for (uint256 i = 0; i < recipients.length; i++) {
        // ... distribute amount proportionally
    }
}
```

## Testing the Rule in Foundry

```solidity
function testReceiveGasUnder1M() public {
    uint256 gasBefore = gasleft();
    (bool ok,) = address(vault).call{value: 1 ether}("");
    uint256 gasUsed = gasBefore - gasleft();
    assertTrue(ok, "receive() reverted");
    assertLe(gasUsed, 1_000_000, "receive() exceeds 1M gas limit");
}
```

Run with:

```bash
forge test --match-test testReceiveGasUnder1M -vvv
```

