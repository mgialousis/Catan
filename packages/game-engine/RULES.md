# Pinned base rules

Rules identifier: **base-2020-v1**. Source: English *CATAN Game Rules & Almanac*, 2020, file revision `2020_200707`, 16 pages, downloaded from the [official base-game rulebook](https://www.catan.com/sites/default/files/2021-06/catan_base_rules_2020_200707.pdf) on 2026-09-09. This selects a fixed classic revision rather than following future editions automatically.

SHA-256: `3fed941bf202314ed462d4d0cdfb0384c97fe04166b48a7186833b3f6f4ac024`. The copyrighted PDF/artwork is not bundled with the app or repository. The [official rule index](https://www.catan.com/understand-catan/game-rules) and [base FAQ](https://www.catan.com/faq/basegame) provide supplementary references.

The inventory on page 2 confirms 19 terrain hexes, nine harbors, 95 resource cards, 25 development cards and each player's 15 roads, five settlements and four cities. Adopt combined trade/build and development-card play before rolling. Expansions are excluded.

Road Building (page 10) specifies two free legal roads; it does not explicitly specify arbitrary voluntary interruption. v1 takes the conservative interpretation: finish early when no legal placement/piece remains; no voluntary waiver of an otherwise placeable road. Timed-mode expiry waives remaining placements as the approved application policy. Preserve committed placements. Phase 3 tests must distinguish this policy from a quoted tabletop requirement.

Phase 3 implements the pure rules engine and verifies complete three- and four-player command sequences. Transport, database persistence and live clocks are separate later milestones.

## v1 implementation decisions

- Ports use coastal edge positions 0, 3, 6, 10, 13, 16, 20, 23 and 26 on the canonical 30-edge perimeter. The four generic and five resource-specific port types are shuffled. This is an original digital layout policy, not a reproduction of the physical frame’s printed positions.
- Starting order is a random rotation of seat order, persisted in canonical state; setup traverses it forward and backward. This retains seat adjacency.
- Number placement retries at most 64 times, then finds four independent fertile hexes for red tokens. Tests force the fallback at all 19 desert positions.
- Production resolves all demand for a resource together. A sole recipient may take remaining bank stock; competing recipients get none when stock cannot satisfy them together.
- Offers reserve no cards. Each proposer has at most one open offer; replacement cancels the old one. Acceptance rechecks both hands, phase and revision. Give/receive bundles must be nonempty and disjoint; cancel any matching resource quantities before proposing an equivalent net trade. Target insolvency can remain visible as a proposal but cannot be accepted; proposer insolvency expires it.
- Year of Plenty resolves a complete two-card choice atomically, including duplicate types. An unavailable choice consumes nothing. v1 does not permit a one-card partial choice; this is the digital choice policy and is not presented as an explicit tabletop clarification.
- Non-VP development cards require an earlier purchase turn; at most one may be played each turn, including before rolling. Newly bought VP cards count immediately. Knight/roads retain their pre-roll/action continuation.
- Victory is checked after every accepted command for the active player, including the player whose turn has just begun. Victory cancels pending effects immediately; only the winner's VP card IDs are revealed, while all final point totals are public.
- Clocks are explicit state only in Phase 3. `turnExpired` may permit Road Building waiver; only future trusted timer integration may set it. No client command sets the clock or supplies random outcomes.

## Engine boundaries

`createGame(input, { now, random })` returns version 0 with the generated board, deck and setup context. `applyCommand(state, actorPlayerId, command, context)` returns `{ state, effects, randomDraws, occurredAt }` or throws `RuleError`. The caller supplies the verified actor; clients cannot include it in a command. State inputs are never mutated. Entropy failures are infrastructure errors, not accepted moves.

`RandomSource` accepts bounded integer requests and UUID requests. The backend uses `node:crypto`; tests use seeded sources. `replayRandom` checks recorded request kinds/ranges and consumption. Server-only logs must retain draw labels/outcomes with commands and rules version. JSONB object-key order does not change replay results. The engine imports only the protocol's pure contracts entry point and performs no network, filesystem or database operations.

`assertBoard` checks topology and inventories at initialization; `assertInvariants` checks resources, pieces, development inventory, derived scores/awards and phase obligations before/after moves. Allowlisted projections copy only public fields or the requested owner's hand. Draw identities and steal/discard types remain restricted to the appropriate participants. See [verification and fixtures](../../docs/phase-3-verification.md).
