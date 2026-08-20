This is an open tranching model for general defi usecase built around https://github.com/centrifuge/tinlake.git (legacy code base from centrifuge v2, deprecated now but few pools 
are still active on mainnet). The sole purpose of Hooke (motivated from the architecture of MD and centrifuge's tinlake) is to immersify the 
the ongoing research on bringing out an ethereum application layer standard in defi native tranching and bootstrapping the build complexity for developers and 
community. 

With the extension looking almost similar to centrifuge's tinlake which was active till 2023 with complete live onchain activity till the time, there is specefic
custom research and development done in the systematic waterfall architecture - this will serve as the basis for this code base to evolve as a product or mere extension
from the open research provided at https://github.com/saintsama98/Hooke-tranching.git.

Note: The sole purpose of this code base is to provide more contract side context for the research & data availble at https://github.com/saintsama98/Hooke-tranching.git (Official
source for Hooke)

---

## Bootstrapping on this

This is a structural reference, not a product. It compiles, it is tested, and the
seams are real; it is not audited and it has never held money. The intent is that you
fork it, keep the parts that are load-bearing, and replace the parts that are policy.

### Reading order

1. `src/lender/interfaces.sol` - the whole architecture on one page. Four actors and
   the calls between them.
2. `test/lender/sacred.t.sol` - the invariants, fuzzed against the arithmetic alone.
   If you keep nothing else, keep these.
3. `test/lender/system.t.sol` - a pool being driven through complete epochs.
4. `script/deployer.sol` - nine contracts, who knows whom, and who may mutate whom.
5. `src/lender/ICascade.sol` - the interface this work is trying to generalise.

### What is load-bearing and what is yours to change

The **four-actor split** is the point. `tranche` owns orders and knows nothing about
seniority. `idle` owns cash and knows nothing at all. `assessor` owns valuation and
allocation and holds no money. `coordinator` orchestrates and neither values nor
holds. Valuation that cannot move money is why a bug here is a mispricing rather
than a theft.

The **invariants** in `ICascade` (I1 distribution order, I2 loss order, I3
conservation, I4 diversion) are what make this a waterfall rather than a pro-rata
pool. Breaking one changes the instrument, not the implementation.

Everything else is calibration and is meant to be replaced:

| Extension point | Where | Default |
|---|---|---|
| Valuation | `NavLike` | `test/mock/navfeed.sol`, a number somebody sets |
| Fill policy | `EpochCoordinator.scoreSolution`, `virtual` | redemptions before subscriptions, senior before junior |
| Risk band | `assessor.file` | set at deploy |
| Permissioning | `MemberlistLike` on the operator | none, permissionless |
| Tranche count | `assessor.trancher` | two |

### Two things this deliberately does not do

**It does not value anything.** `NavLike` is a seam with a one-line mock behind it.
Every tranched pool that has failed, on-chain or off, failed at valuation rather than
at distribution. The guarantees here are conditional on a correct NAV and the code
has no way to tell you the NAV is wrong.

**It does not divert cash flow on a coverage test.** I4 is written into `ICascade`
and upheld vacuously, because the surface does not yet expose loss allocation or a
coverage trigger. Tinlake enforces its ratio band by refusing to execute an epoch; a
CLO enforces it by re-routing the waterfall. Those are different mechanisms and only
the first is implemented. That gap is the next thing worth building.

### Deviations from Tinlake, and why

- **`Fixed27` is a file-level struct.** Tinlake reaches the type by inheriting
  `FixedPoint`, which works only because its seams are `contract`s with unimplemented
  functions, illegal under solc 0.8.
- **Seams live in one file.** Tinlake declares `*Like` inline per file, so `IdleLike`
  existed three times with three different member sets and nothing forced them to agree.
- **Senior state and ratio maths live in `sacred.sol`.** Tinlake carries a copy of
  `calcSeniorAssetValue` in both `assessor` and `coordinator`, kept in step by hand.
- **The off-chain solver is `virtual`, not transcribed.** The state machine and the
  constraint checks are exact. The weights that rank a submission are a policy choice,
  so they are an override rather than a prerequisite.
- **Error codes renumbered to Tinlake's.** The previous `ERR_MAX_RESERVE = -2`
  collided with Tinlake's `ERR_MAX_ORDER`.
- **Empty epochs key by `lastEpochExecuted + 1`.** Tinlake keys them by `currentEpoch`,
  which agrees with the execution path only while no epoch is ever skipped.

### Build

```
forge build
forge test
```
