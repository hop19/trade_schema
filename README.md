# Design Choices Log

## Give up on DAE schema purity

#### Context

Give up on attempt for purity of DAE schema. Establish trades as standalone
entities rather than composite relations of DAE txs.

This gets around the limitation where if a trade points to two DAE tx
entries, there is no simple method to enforce that the txs must have the
same pair of src/dst account and strategy without non-trivial triggers.
I'm not comfortable to be using triggers yet, and this seemed to be too
simply of a problem to permit the use of such heavy lifting.

Settle on my very early schema of representing single-asset txs and
two-asset trades separately. Good thing is, as far as I can tell, this
is still a normalized schema.

Footnote, I still need to verify with textbooks on the theory behind
this, but I believe this is a limitation of first order predicate logic
which SQL is based on. There is simply no way of expressing
non-foreign-key constraints betweens relations n-steps apart (n > 1).


## Relax NOT NULL constraint of `strategy_id` on `trade`

#### Context

As an artifact of the exercise to remove the duplicate trades and
re-populate the table, added functions to fetch trades from REST API.
Existing xform helper from order-update to insertable trade is
refactored to accommodate the slightly different shape of trades from the
API.

The column exist for denormalisation purpose. Since it the value should always
be recoverable from the venue_order_id, having a NOT NULL constraint to enforce
the column to be present upon insert would have added more cost to inserting a
trade and without benefiting queries.

We would still need to populate the column for most of the accounting
views to work, so a recurring update can be used on the trade table to
populate the strategy column with the canonical pathway through
venue_order and ems_order.

This should improve performance on the streamed order-update -> trade
insert as well, now that we don't have to look up the strategy ID prior
to inserting.


## Optimize balance aggregation, aka reconciliation, with snapshots

#### Context

The time it takes to make a full historical aggregation (i.e. with `SELECT *
FROM bookkeep.strategy_balance_diff_since(0)`) to reconcile the balance to
scales linearly with the number of records in `bookkeep.tx` and `bookkeep.trade`
tables. This is obviously not desirable as the system grows. As an optimisation,
we take snapshots to finalize the aggregation of trades up to a point in time,
then compute on the fly reconciliations based off of the latest snapshot and
trades have been recorded since said snapshot.
