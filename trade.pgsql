CREATE SCHEMA IF NOT EXISTS registry;

CREATE TABLE IF NOT EXISTS registry.venue (
    name text PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS registry.asset (
    symbol            text PRIMARY KEY,
    created_at        timestamptz DEFAULT CURRENT_TIMESTAMP,
    description       text,
    santiment_slug    text,
    lunarcrush_symbol text,
    binance_symbol    text
);

CREATE TABLE IF NOT EXISTS registry.market (
    market_id  int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    base       text REFERENCES registry.asset(symbol) ON UPDATE CASCADE NOT NULL,
    quote      text REFERENCES registry.asset(symbol) ON UPDATE CASCADE NOT NULL,
    venue      text REFERENCES registry.venue(name) ON UPDATE CASCADE   NOT NULL,
    symbol     text,
    created_at timestamptz DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (venue, base, quote),
    UNIQUE (venue, symbol),
    CONSTRAINT pair CHECK (base != quote)
);

CREATE SCHEMA IF NOT EXISTS bookkeep;

---- Accounts ----

CREATE TABLE IF NOT EXISTS bookkeep.account (
    account_id  int GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    description text,
    created_at  timestamptz DEFAULT CURRENT_TIMESTAMP
);

-- Internal accounts, maps to Asset accounts in standard accounting mindset

CREATE TABLE IF NOT EXISTS bookkeep.strategy_account (
    strategy_id int REFERENCES bookkeep.account(account_id) PRIMARY KEY,
    name        text UNIQUE NOT NULL
);

CREATE TABLE IF NOT EXISTS bookkeep.internal_account (
    account_id int REFERENCES bookkeep.account PRIMARY KEY,
    alias      text
);

-- External accounts, maps to Liability accounts in standard accounting mindset
-- i.e. credit means we owe them something, debit means we paid them back
-- From their perspective, if they were running an in-house DAE ledger,
-- our account with them would be the exact balance in opposite
-- i.e. positive amounts are negative and vice versa

CREATE TABLE IF NOT EXISTS bookkeep.venue_account (
    account_id int REFERENCES bookkeep.account PRIMARY KEY,
    venue      text REFERENCES registry.venue(name) ON UPDATE CASCADE NOT NULL
);

CREATE TABLE IF NOT EXISTS bookkeep.external_account (
    account_id int REFERENCES bookkeep.account PRIMARY KEY,
    alias      text
);

---- Orders and Transactions ----

CREATE TABLE IF NOT EXISTS bookkeep.ems_order (
    strategy_id  int REFERENCES bookkeep.strategy_account NOT NULL,
    ems_order_id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    created_at   timestamptz DEFAULT CURRENT_TIMESTAMP,
    details      jsonb
);

CREATE TABLE IF NOT EXISTS bookkeep.venue_order (
    venue_account_id int REFERENCES bookkeep.venue_account NOT NULL,
    venue_order_id   text                         NOT NULL,
    ems_order_id     bigint REFERENCES bookkeep.ems_order  NOT NULL,
    created_at       timestamptz DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (venue_account_id, venue_order_id)
);

CREATE INDEX IF NOT EXISTS ems_order_strategy_idx ON bookkeep.ems_order(strategy_id);
CREATE INDEX IF NOT EXISTS venue_order_strategy_idx ON bookkeep.venue_order(ems_order_id);

CREATE TABLE IF NOT EXISTS bookkeep.tx (
    -- i.e. credit means transfer from, debit means transfer into
    -- https://en.wikipedia.org/wiki/Debits_and_credits
    credit   int REFERENCES bookkeep.account(account_id) ON DELETE RESTRICT NOT NULL,
    debit    int REFERENCES bookkeep.account(account_id) ON DELETE RESTRICT NOT NULL,
    asset    text REFERENCES registry.asset(symbol) ON UPDATE CASCADE       NOT NULL,
    amount   numeric                                               NOT NULL,
    datetime timestamptz                                           NOT NULL,
    via      int REFERENCES bookkeep.account(account_id) ON DELETE RESTRICT,
    tx_id    bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    CONSTRAINT distinct_account CHECK (debit != credit),
    CONSTRAINT positive_amount CHECK (amount > 0)
);

CREATE TABLE IF NOT EXISTS bookkeep.trade (
    strategy_id       int REFERENCES bookkeep.strategy_account,
    venue_account_id  int                                             NOT NULL,
    venue_order_id    text                                            NOT NULL,
    -- Naturally either price or quote_amount could have been generated.
    -- From accounting stand point it might have made more sense to instead
    -- store quote_amount and generate price since it more purely describe the
    -- movement of asset.
    --
    -- However most data sources (i.e. exchanges) will
    -- report trades with a price column rather than quote amount, and to avoid
    -- the round-trip overhead for multiplying and dividing we will generate
    -- the quote amount instead. From the database's users' point of view it is
    -- all the same anyway.
    price             numeric                                         NOT NULL,
    base_asset        TEXT REFERENCES registry.asset(symbol) ON UPDATE CASCADE NOT NULL,
    base_amount       numeric                                         NOT NULL,
    quote_asset       text REFERENCES registry.asset(symbol) ON UPDATE CASCADE NOT NULL,
    quote_amount      numeric GENERATED ALWAYS AS (price * -base_amount) STORED,
    is_buy            bool GENERATED ALWAYS AS (base_amount > 0) STORED,
    commission_asset  text REFERENCES registry.asset(symbol) ON UPDATE CASCADE,
    commission_amount numeric,
    datetime          timestamptz                                     NOT NULL,
    -- We are using JSONB here due to the diverse idiosyncratic of how uniquely
    -- does each exchange assign trade IDs. i.e. Bitfinex ensures uniqueness across
    -- all trades in your account, where as Binance ensures uniqueness only in the
    -- same market. Some other exchanges may even go further use UUIDs.
    -- Since some of these uniqueness can be based on tuples, it is better if we name
    -- these tuples as structured data using json, rather than just encoding to text.
    venue_trade_id    jsonb,
    FOREIGN KEY (venue_account_id, venue_order_id) REFERENCES bookkeep.venue_order,
    UNIQUE (venue_account_id, venue_trade_id),
    CONSTRAINT positive_price CHECK (price > 0),
    CONSTRAINT commission_exists CHECK (
            (commission_asset IS NULL AND commission_amount IS NULL) OR
            (commission_asset IS NOT NULL AND commission_amount IS NOT NULL)
        )
);

CREATE INDEX IF NOT EXISTS trade_order_idx ON bookkeep.trade(venue_account_id, venue_order_id);
CREATE INDEX IF NOT EXISTS trade_strategy_base_idx ON bookkeep.trade(strategy_id, base_asset);
CREATE INDEX IF NOT EXISTS trade_strategy_quote_idx ON bookkeep.trade(strategy_id, quote_asset);
CREATE INDEX IF NOT EXISTS trade_datetime_brin ON bookkeep.trade USING brin(datetime);

CREATE OR REPLACE PROCEDURE bookkeep.denormalise_trades()
AS $$
    UPDATE bookkeep.trade
    SET strategy_id = eo.strategy_id
    FROM bookkeep.ems_order AS eo INNER JOIN bookkeep.venue_order AS vo ON eo.ems_order_id = vo.ems_order_id
    WHERE (trade.strategy_id IS NULL)
      AND (vo.venue_order_id = trade.venue_order_id)
      AND (vo.venue_account_id = trade.venue_account_id)
$$ LANGUAGE SQL;

/****************************************/
/* Balance views */
/****************************************/

CREATE TYPE bookkeep.balance AS (
    account_id int,
    asset text,
    amount numeric
);

CREATE OR REPLACE FUNCTION bookkeep.tx_debit_till(till timestamptz)
RETURNS SETOF bookkeep.balance AS $$
    SELECT debit, asset, SUM(amount) AS amount
    FROM bookkeep.tx
    WHERE datetime <= till
    GROUP BY debit, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.tx_credit_till(till timestamptz)
RETURNS SETOF bookkeep.balance AS $$
    SELECT credit, asset, -SUM(amount) AS amount
    FROM bookkeep.tx
    WHERE datetime <= till
    GROUP BY credit, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.tx_debit_since(since timestamptz)
RETURNS SETOF bookkeep.balance AS $$
    SELECT debit, asset, SUM(amount) AS amount
    FROM bookkeep.tx
    WHERE since < datetime
    GROUP BY debit, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.tx_credit_since(since timestamptz)
RETURNS SETOF bookkeep.balance AS $$
    SELECT credit, asset, -SUM(amount) AS amount
    FROM bookkeep.tx
    WHERE since < datetime
    GROUP BY credit, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE TYPE bookkeep.trade_rec AS (
    strategy_id int,
    venue_account_id int,
    asset text,
    amount numeric
);

CREATE OR REPLACE FUNCTION bookkeep.trade_base_till(till timestamptz)
RETURNS SETOF bookkeep.trade_rec AS $$
    SELECT strategy_id, venue_account_id, base_asset, base_amount
    FROM bookkeep.trade
    WHERE datetime <= till
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.trade_quote_till(till timestamptz)
RETURNS SETOF bookkeep.trade_rec AS $$
    SELECT strategy_id, venue_account_id, quote_asset, quote_amount
    FROM bookkeep.trade
    WHERE datetime <= till
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.trade_base_since(since timestamptz)
RETURNS SETOF bookkeep.trade_rec AS $$
    SELECT strategy_id, venue_account_id, base_asset, base_amount
    FROM bookkeep.trade
    WHERE since < datetime
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.trade_quote_since(since timestamptz)
RETURNS SETOF bookkeep.trade_rec AS $$
    SELECT strategy_id, venue_account_id, quote_asset, quote_amount
    FROM bookkeep.trade
    WHERE since < datetime
$$ LANGUAGE sql STABLE STRICT;

---- Strategy balance ----

CREATE OR REPLACE FUNCTION bookkeep.strategy_balance_diff_till(till timestamptz)
RETURNS SETOF bookkeep.balance AS $$
    SELECT account_id,
           asset,
           SUM(amount) as amount
    FROM (
        SELECT * FROM bookkeep.tx_debit_till(till)
            UNION ALL
        SELECT * FROM bookkeep.tx_credit_till(till)
            UNION ALL
        SELECT strategy_id as account_id, asset, amount
        FROM bookkeep.trade_base_till(till)
            UNION ALL
        SELECT strategy_id as account_id, asset, amount
        FROM bookkeep.trade_quote_till(till)
    ) diffs
        JOIN bookkeep.strategy_account ON account_id = strategy_id
    GROUP BY account_id, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.strategy_balance_diff_since(since timestamptz)
RETURNS SETOF bookkeep.balance AS $$
    SELECT account_id,
           asset,
           SUM(amount) as amount
    FROM (
        SELECT * FROM bookkeep.tx_debit_since(since)
            UNION ALL
        SELECT * FROM bookkeep.tx_credit_since(since)
            UNION ALL
        SELECT strategy_id as account_id, asset, amount
        FROM bookkeep.trade_base_since(since)
            UNION ALL
        SELECT strategy_id as account_id, asset, amount
        FROM bookkeep.trade_quote_since(since)
    ) diffs
        JOIN bookkeep.strategy_account ON account_id = strategy_id
    GROUP BY account_id, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE TABLE IF NOT EXISTS bookkeep.strategy_balance_snapshot (
    strategy_id int REFERENCES bookkeep.strategy_account ON UPDATE CASCADE       NOT NULL,
    asset       text REFERENCES registry.asset(symbol) ON UPDATE CASCADE NOT NULL,
    amount      numeric                                                  NOT NULL,
    datetime    timestamptz                                              NOT NULL
);

CREATE OR REPLACE PROCEDURE bookkeep.take_strategy_balance_snapshot(till timestamptz)
AS $$
    INSERT INTO bookkeep.strategy_balance_snapshot
    SELECT *, till as datetime
    FROM bookkeep.strategy_balance_diff_till(till)
$$ LANGUAGE sql;

CREATE OR REPLACE VIEW bookkeep.strategy_balance AS
WITH
    last_snapshot AS (
        SELECT MAX(datetime) AS dt
        FROM bookkeep.strategy_balance_snapshot
    ),
    snap AS (
        SELECT strategy_id, asset, amount
        FROM bookkeep.strategy_balance_snapshot
        WHERE datetime = (SELECT dt FROM last_snapshot)
    ),
    diffs AS (
        SELECT account_id as strategy_id, asset, amount
        FROM bookkeep.strategy_balance_diff_since(
            COALESCE((SELECT dt FROM last_snapshot), 'epoch'::timestamptz)
        )
    ),
    bal AS (
        SELECT strategy_id, asset, SUM(amount) AS amount
        FROM (SELECT * FROM snap UNION ALL SELECT * FROM diffs) tb
        GROUP BY strategy_id, asset
        HAVING SUM(amount) != 0
    )
SELECT strategy_account.name as strategy, asset, amount, strategy_id
FROM bal JOIN bookkeep.strategy_account USING (strategy_id);

---- Venue balance ----

CREATE OR REPLACE FUNCTION bookkeep.venue_balance_diff_till(till timestamptz)
RETURNS SETOF bookkeep.balance AS $$
    SELECT account_id,
           asset,
           -SUM(amount) as amount
    FROM (
        SELECT * FROM bookkeep.tx_debit_till(till)
            UNION ALL
        SELECT * FROM bookkeep.tx_credit_till(till)
            UNION ALL
        SELECT venue_account_id as account_id, asset, -amount
        FROM bookkeep.trade_base_till(till)
            UNION ALL
        SELECT venue_account_id as account_id, asset, -amount
        FROM bookkeep.trade_quote_till(till)
    ) diffs
        JOIN bookkeep.venue_account USING (account_id)
    GROUP BY account_id, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.venue_balance_diff_since(since timestamptz)
RETURNS SETOF bookkeep.balance AS $$
    SELECT account_id,
           asset,
           -SUM(amount) as amount
    FROM (
        SELECT * FROM bookkeep.tx_debit_since(since)
            UNION ALL
        SELECT * FROM bookkeep.tx_credit_since(since)
            UNION ALL
        SELECT venue_account_id as account_id, asset, -amount
        FROM bookkeep.trade_base_since(since)
            UNION ALL
        SELECT venue_account_id as account_id, asset, -amount
        FROM bookkeep.trade_quote_since(since)
    ) diffs
        JOIN bookkeep.venue_account USING (account_id)
    GROUP BY account_id, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE TABLE IF NOT EXISTS bookkeep.venue_balance_snapshot (
    venue_account_id int REFERENCES bookkeep.venue_account ON UPDATE CASCADE  NOT NULL,
    asset            text REFERENCES registry.asset(symbol) ON UPDATE CASCADE NOT NULL,
    amount           numeric                                                  NOT NULL,
    datetime         timestamptz                                              NOT NULL
);

CREATE OR REPLACE PROCEDURE bookkeep.take_venue_balance_snapshot(till timestamptz)
AS $$
    INSERT INTO bookkeep.venue_balance_snapshot
    SELECT *, till as datetime
    FROM bookkeep.venue_balance_diff_till(till)
$$ LANGUAGE sql;

CREATE OR REPLACE VIEW bookkeep.venue_balance AS
WITH
    last_snapshot AS (
        SELECT MAX(datetime) AS dt
        FROM bookkeep.venue_balance_snapshot
    ),
    snap AS (
        SELECT venue_account_id, asset, amount
        FROM bookkeep.venue_balance_snapshot
        WHERE datetime = (SELECT dt FROM last_snapshot)
    ),
    diffs AS (
        SELECT account_id, asset, amount
        FROM bookkeep.venue_balance_diff_since(
            COALESCE((SELECT dt FROM last_snapshot), 'epoch'::timestamptz)
        )
    ),
    bal AS (
        SELECT venue_account_id, asset, SUM(amount) AS amount
        FROM (SELECT * FROM snap UNION ALL SELECT * FROM diffs) tb
        GROUP BY venue_account_id, asset
        HAVING SUM(amount) != 0
    )
SELECT venue_account.venue as venue, asset, amount, venue_account_id
FROM bal JOIN bookkeep.venue_account ON venue_account_id = account_id;

---- Strategy-Venue balance ----

CREATE OR REPLACE FUNCTION bookkeep.strategy_venue_balance_diff_till(till timestamptz)
RETURNS SETOF bookkeep.trade_rec AS $$
    WITH
        tx_strategy_venue AS (
            SELECT debit AS strategy_id, credit AS venue_account_id, asset, amount as amount
            FROM bookkeep.tx
            WHERE credit IN (SELECT account_id FROM bookkeep.venue_account)
              AND debit  IN (SELECT strategy_id FROM bookkeep.strategy)
              AND datetime <= till
        ),
        tx_venue_strategy AS (
            SELECT credit AS strategy_id, debit AS venue_account_id, asset, -amount as amount
            FROM bookkeep.tx
            WHERE credit IN (SELECT strategy_id FROM bookkeep.strategy)
              AND debit  IN (SELECT account_id FROM bookkeep.venue_account)
              AND datetime <= till
        )
    SELECT strategy_id,
           venue_account_id,
           asset,
           SUM(amount) AS amount
    FROM (
        SELECT * FROM tx_venue_strategy UNION ALL
        SELECT * FROM tx_strategy_venue UNION ALL
        SELECT * FROM bookkeep.trade_base_till(till) UNION ALL
        SELECT strategy_id, venue_account_id, asset, -amount FROM bookkeep.trade_quote_till(till)
    ) diffs (strategy_id, venue_account_id, asset, amount)
    GROUP BY strategy_id, venue_account_id, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE OR REPLACE FUNCTION bookkeep.strategy_venue_balance_diff_since(since timestamptz)
RETURNS SETOF bookkeep.trade_rec AS $$
    WITH
        tx_strategy_venue AS (
            SELECT debit AS strategy_id, credit AS venue_account_id, asset, amount as amount
            FROM bookkeep.tx
            WHERE credit IN (SELECT account_id FROM bookkeep.venue_account)
              AND debit  IN (SELECT strategy_id FROM bookkeep.strategy)
              AND since < datetime
        ),
        tx_venue_strategy AS (
            SELECT credit AS strategy_id, debit AS venue_account_id, asset, -amount as amount
            FROM bookkeep.tx
            WHERE credit IN (SELECT strategy_id FROM bookkeep.strategy)
              AND debit  IN (SELECT account_id FROM bookkeep.venue_account)
              AND since < datetime
        )
    SELECT strategy_id,
           venue_account_id,
           asset,
           SUM(amount) AS amount
    FROM (
        SELECT * FROM tx_venue_strategy UNION ALL
        SELECT * FROM tx_strategy_venue UNION ALL
        SELECT * FROM bookkeep.trade_base_since(since) UNION ALL
        SELECT strategy_id, venue_account_id, asset, -amount FROM bookkeep.trade_quote_since(since)
    ) diffs (strategy_id, venue_account_id, asset, amount)
    GROUP BY strategy_id, venue_account_id, asset
$$ LANGUAGE sql STABLE STRICT;

CREATE TABLE IF NOT EXISTS bookkeep.strategy_venue_balance_snapshot (
    strategy_id      int REFERENCES bookkeep.strategy_account ON UPDATE CASCADE                  NOT NULL,
    venue_account_id int REFERENCES bookkeep.venue_account(account_id) ON UPDATE CASCADE NOT NULL,
    asset            text REFERENCES registry.asset(symbol) ON UPDATE CASCADE            NOT NULL,
    amount           numeric                                                             NOT NULL,
    datetime         timestamptz                                                         NOT NULL
);

CREATE OR REPLACE PROCEDURE bookkeep.take_strategy_venue_balance_snapshot(till timestamptz)
AS $$
    INSERT INTO bookkeep.strategy_venue_balance_snapshot
    SELECT *, till as datetime
    FROM bookkeep.strategy_venue_balance_diff_till(till)
$$ LANGUAGE SQL;

CREATE OR REPLACE VIEW bookkeep.strategy_venue_balance AS
WITH
    last_snapshot AS (
        SELECT MAX(datetime) AS dt
        FROM bookkeep.strategy_venue_balance_snapshot
    ),
    snap AS (
        SELECT strategy_id, venue_account_id, asset, amount
        FROM bookkeep.strategy_venue_balance_snapshot
        WHERE datetime = (SELECT dt FROM last_snapshot)
    ),
    diffs AS (
        SELECT strategy_id, venue_account_id, asset, amount
        FROM bookkeep.strategy_venue_balance_diff_since(
            COALESCE((SELECT dt FROM last_snapshot), 'epoch'::timestamptz)
        )
    ),
    b AS (
        SELECT strategy_id, venue_account_id, asset, sum(amount) as amount
        FROM (SELECT * FROM snap UNION ALL SELECT * FROM diffs) tb
        GROUP BY strategy_id, venue_account_id, asset
        HAVING sum(amount) != 0
    )
SELECT b.strategy_id as strategy_id,
       b.venue_account_id as venue_account_id,
       sa.name as strategy,
       va.venue as venue,
       asset,
       amount
FROM b
    LEFT JOIN bookkeep.strategy_account sa ON sa.strategy_id = b.strategy_id
    LEFT JOIN bookkeep.venue_account va ON va.account_id = b.venue_account_id;