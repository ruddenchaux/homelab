# Ghostfolio

Self-hosted portfolio tracker deployed at `https://portfolio.ruddenchaux.xyz`.

## Deployment

- Helm umbrella chart: `kubernetes/platform/ghostfolio/`
- Namespace: `ghostfolio`
- Workloads: `ghostfolio` (API/UI), `ghostfolio-postgresql`, `ghostfolio-redis`
- Database: PostgreSQL on local-path-provisioner, DB name `ghostfolio-db`, user `ghostfolio`
- Auth: Authentik OIDC via ForwardAuth + native Ghostfolio login for admin

## Importing Degiro transactions

We use [`dickwolff/Export-To-Ghostfolio`](https://github.com/dickwolff/Export-To-Ghostfolio) to
convert Degiro's `Transactions.csv` into Ghostfolio's activity format.

### Always-on settings for `.env`

```env
DEGIRO_FORCE_V3=true        # better symbol resolution than the legacy converter
GHOSTFOLIO_VALIDATE=true    # validates the generated JSON against Ghostfolio before import
```

Without `GHOSTFOLIO_VALIDATE=true`, dickwolff happily pushes rows with undefined currencies
or missing numeric fields — which will break the dashboard silently (see "Dashboard crash"
below). Turn it on.

### Workflow

```bash
# 1. Export Transactions.csv from Degiro (Activity → Export)
# 2. Place it where dickwolff expects it (see its README for path)
npm start degiro

# Output: e2g-output/ghostfolio-degiro-v3-<timestamp>.json
# dickwolff auto-imports it when the validation step passes.
```

### What dickwolff doesn't handle cleanly

These ISINs routinely emit `No result found` warnings and must be handled manually (add in
Ghostfolio UI with `dataSource: MANUAL` + a fixed `unitPrice`):

- **Contingent Value Rights (CVRs)** — e.g. `US296CVR0124`, `CA296CVR0120`. Merger remnants,
  often untradeable and unpriced.
- **Delisted / merged-away tickers** — e.g. `US9047677045` (old Unilever NV after 2020
  unification).
- **Singapore Exchange tickers** — e.g. `SGXE35825913`, `SGXE77102635`. Yahoo doesn't
  index them and dickwolff mis-parses the currency as `SG` instead of `SGD`.
- **LSE-listed ETFs** — `GB00B*` ISINs. Yahoo needs the `.L` suffix and GBX-vs-GBP
  awareness; dickwolff often does neither.
- **Exotic derivative codes** — e.g. `ANX1125DMYXX`.
- **Dividend lines with no currency** — Degiro occasionally emits these for `NL0010661914`
  (Flow Traders) and a few others; dickwolff imports them with `currency: undefined`.

### Post-import cleanup (always required)

After every Degiro import, check for these patterns and clean them up in the Ghostfolio UI:

1. **FEE rows in GBP with absurd values (e.g. 3375)** — Degiro reports LSE fees in **GBX
   (pence)**. A 3375 GBP fee is really £33.75. Edit the value or delete.
2. **SELL rows with `unitPrice = 0`** — dickwolff misinterprets **in-kind transfers between
   brokers** as zero-price sales. Not a real transaction. Delete.
3. **BUY rows with `unitPrice = 0`** — same pattern but inbound transfers.

Useful SQL to find both:

```bash
ssh debian@10.30.0.10 'kubectl exec -n ghostfolio deploy/ghostfolio-postgresql -- \
  psql -U ghostfolio -d ghostfolio-db -c "
    SELECT o.type, sp.symbol, o.currency, o.quantity, o.\"unitPrice\", o.fee, o.date
    FROM \"Order\" o JOIN \"SymbolProfile\" sp ON sp.id = o.\"symbolProfileId\"
    WHERE o.\"unitPrice\" = 0 OR (o.currency = '\''GBP'\'' AND o.fee > 100)
    ORDER BY o.date;"'
```

## Dashboard crash — `[big.js] Invalid number`

**Symptom:** Every dashboard endpoint (`/api/v1/portfolio/performance`, `/holdings`,
`/investments`, `/details`) returns 500. UI shows spinners, empty charts, or "something went
wrong". Pod logs contain repeated:

```
ERROR [ExceptionsHandler] Error: [big.js] Invalid number
  at parse (/ghostfolio/apps/api/node_modules/big.js/big.js:144:13)
  at new Big (...)
  at Array.map (<anonymous>)
  at new PortfolioCalculator (...)
  at PortfolioCalculatorFactory.createCalculator (...)
```

And often interleaved:

```
ERROR [ExchangeRateDataService] No exchange rate has been found for <PAIR> at <date>
```

**Root cause:** Ghostfolio converts every non-base-currency activity to the user's base
currency when building a `PortfolioCalculator`. If it lacks an FX rate for a (pair, date)
the rate comes back `undefined` → `unitPrice * undefined = NaN` → `new Big(NaN)` throws.
Every dashboard endpoint funnels through the same constructor, so **one bad FX lookup
breaks the entire dashboard**, not just one widget.

**Verify:** which FX pairs does Ghostfolio actually have historical data for?

```bash
ssh debian@10.30.0.10 'kubectl exec -n ghostfolio deploy/ghostfolio-postgresql -- \
  psql -U ghostfolio -d ghostfolio-db -c "
    SELECT symbol, \"dataSource\", COUNT(*) AS rates,
           MIN(date)::date AS oldest, MAX(date)::date AS newest
    FROM \"MarketData\"
    WHERE symbol ~ '\''^[A-Z]{6}$'\''   -- currency-pair shape
    GROUP BY symbol, \"dataSource\"
    ORDER BY symbol;"'
```

Compare against the currencies actually present in your activities:

```bash
ssh debian@10.30.0.10 'kubectl exec -n ghostfolio deploy/ghostfolio-postgresql -- \
  psql -U ghostfolio -d ghostfolio-db -c "
    SELECT o.currency AS order_cur, sp.currency AS symbol_cur, COUNT(*)
    FROM \"Order\" o JOIN \"SymbolProfile\" sp ON sp.id = o.\"symbolProfileId\"
    GROUP BY o.currency, sp.currency ORDER BY COUNT(*) DESC;"'
```

If you hold anything outside EUR/USD and there's only `USDEUR` in `MarketData`, that's
your problem.

**Fix:**

1. Log into Ghostfolio as admin → *Admin Control Panel* → *Data Management* →
   **Gather All Market Data** (enqueues BullMQ jobs to backfill historical FX rates for
   every pair the portfolio needs).
2. Tail the logs until the job queue drains:
   ```bash
   ssh debian@10.30.0.10 'kubectl logs -n ghostfolio deploy/ghostfolio -f | grep -iE "gather|exchange"'
   ```
3. Reload the dashboard.

If the admin UI button is absent in your Ghostfolio version, trigger it via the API:

```bash
curl -X POST -H "Authorization: Bearer <admin-api-token>" \
  https://portfolio.ruddenchaux.xyz/api/v1/admin/gather/max
```

## In-kind transfers between brokers

When you move shares between brokers (not a sale), dickwolff's Degiro converter emits a
**SELL at `unitPrice = 0`** — which is both wrong data and a dashboard-breaker. Handle it
correctly in Ghostfolio:

1. **Delete the zero-price SELL** (it's not a real event).
2. **Re-parent the original BUY activities** for the affected symbol from Degiro to the
   destination broker's Ghostfolio account: *Activities* → edit each BUY → change
   *Account* dropdown. This preserves the original cost basis.

Result:
- Source account (Degiro) shows no remaining position — correct, you don't hold it there.
- Destination account shows the full position with the original cost basis — correct.
- No fake realized gain/loss.

**When importing the destination broker later**, watch for their version of the same
artifact: most brokers record the incoming transfer as a *"Deposit in kind"* or
*"Transfer in"* line, often valued at the market price on the transfer date. If that
becomes a BUY on import you'll get **double-counted shares and a wrong cost basis**.

Inspect the generated JSON before auto-import, and delete any transfer-in row for symbols
you already re-parented.

## Diagnostic cheat sheet

```bash
# Pod health
ssh debian@10.30.0.10 'kubectl get pods -n ghostfolio'

# API logs (filter to real errors, strip ANSI color codes)
ssh debian@10.30.0.10 'kubectl logs -n ghostfolio deploy/ghostfolio --tail=500 2>&1 \
  | sed "s/\x1b\[[0-9;]*m//g" | grep -iE "error|exception|invalid" | tail -40'

# Unique error signatures with counts
ssh debian@10.30.0.10 'kubectl logs -n ghostfolio deploy/ghostfolio --tail=5000 2>&1 \
  | sed "s/\x1b\[[0-9;]*m//g" | grep -oE "ERROR \[[A-Za-z]+\].*" | sort | uniq -c | sort -rn | head -20'

# Count rows and flag suspicious ones
ssh debian@10.30.0.10 'kubectl exec -n ghostfolio deploy/ghostfolio-postgresql -- \
  psql -U ghostfolio -d ghostfolio-db -c "
    SELECT
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE quantity = '\''NaN'\''::float8
                         OR \"unitPrice\" = '\''NaN'\''::float8
                         OR fee = '\''NaN'\''::float8) AS nan_rows,
      COUNT(*) FILTER (WHERE currency IS NULL OR currency = '\'''\'') AS bad_currency,
      COUNT(*) FILTER (WHERE \"unitPrice\" = 0) AS zero_price_rows
    FROM \"Order\";"'
```

## References in TROUBLESHOOTING.md

No Ghostfolio-specific entries yet. If a dashboard crash or import regression becomes a
recurring issue, copy the relevant section from here into `TROUBLESHOOTING.md` so it
surfaces alongside other cluster-wide issues.
