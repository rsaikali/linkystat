# Linkystat — Proposed Improvements

## Technical Optimizations

### 1. Python Collector (`src/linky2db.py`)

- **No connection pooling / reconnect logic for MySQL.** The main `LinkyData` class creates a single SQLAlchemy engine but doesn't handle stale connections gracefully. A `pool_pre_ping=True` on the engine would auto-reconnect silently after MySQL restarts or network blips.
- **Bare `except Exception` in the main loop** catches everything including `KeyboardInterrupt`. Consider catching `sqlalchemy.exc.OperationalError` specifically for DB errors and letting other exceptions propagate.
- **Serial read is blocking with no timeout tuning.** If the dongle hangs or disconnects mid-frame, the thread blocks forever. A `timeout` on the serial port + a watchdog mechanism would make the collector more resilient.
- **Data insertion is one row at a time.** Since TeleInfo frames arrive every ~1-2 seconds this is fine for throughput, but using `executemany` with small batches (e.g. 10 rows) would reduce MySQL round-trips.

### 2. Database (`files/mysql/init-script.sh`)

- **`clean_realtime` runs every 1 minute with `DELETE ... < NOW() - INTERVAL 2 DAY`.** On a Raspberry Pi, frequent deletes on InnoDB can cause I/O spikes. Consider running it every 10-15 minutes instead — 2 days of data at 1 row/second is only ~170K rows, very manageable.
- **`refresh_linky_cache` runs every 5 minutes** and rebuilds the entire daily/monthly/yearly cache from scratch. An incremental approach (only recalculating the current day/month/year) would be much lighter.
- **InnoDB buffer pool is 4GB** — this is likely larger than the total RAM on many Raspberry Pi models (Pi 4 has 1-8GB). If this is a Pi 4 with 4GB RAM, MySQL alone will cause swapping. Recommend tuning to ~50% of available RAM.
- **No index on `linky_realtime.temperature`** — if you ever query by temperature range, this would help. Low priority.

### 3. Docker / Infrastructure

- **Grafana health check uses `curl`** but the Grafana slim image may not include curl. Consider using `wget -q --spider` instead which is more reliably available.
- **MySQL `max_execution_time=10000`** (10 seconds) is fine but could cause issues with the full cache rebuild on large datasets. Monitor this as data grows.
- **No resource limits on containers.** On a Pi, adding `mem_limit` to MySQL and Grafana would prevent OOM kills.

### 4. Weather (`src/weather.py`)

- **10-minute TTL cache is good**, but if the OpenWeather API is unreachable, `get_current_temperature()` returns `None` and that `None` goes straight into the DB. Consider returning the last known good temperature instead of `None`.

---

## Feature Proposals (Grafana & Beyond)

### High-Value, Easy to Implement

1. **Cost Tracking Dashboard Panel** — Add a dedicated cumulative cost panel showing running monthly cost in euros with a projected end-of-month estimate (linear extrapolation from current consumption). SQL: `total_kwh * weighted_price + prorated_subscription`.

2. **Temperature vs. Consumption Correlation** — Scatter plot panel (X=avg daily temperature, Y=daily kWh) to visualize heating impact. Reveals the "base temperature" below which heating kicks in.

3. **Consumption Heatmap** — Grafana heatmap panel showing consumption by hour of day x day of week. Reveals usage patterns (morning routine, evening cooking, weekend habits). Query: `SELECT HOUR(time), DAYOFWEEK(time), AVG(PAPP) FROM linky_realtime GROUP BY 1, 2`.

4. **Peak vs Off-Peak Optimization Score** — Show what percentage of consumption happens during off-peak hours and calculate how much money the user saves (or could save) by shifting consumption. Display as a gauge with "You saved X euros this month by using off-peak hours."

5. **Anomaly Detection Alerts** — Visual "unusual consumption" indicator. Compare today's consumption to the same weekday average over the last 4 weeks. If >30% above average, highlight in red. Pure SQL with `DAYOFWEEK()` grouping.

6. **Standby Power Analysis** — Panel showing the minimum sustained power over the last 24h (e.g., `MIN(PAPP) over 30-min windows`). Represents true standby/always-on load. Show the annual cost of standby (`min_watts * 8760h * price / 1000`). "Your always-on devices cost you X euros/year."

7. **Year-over-Year Comparison** — Overlay panel showing this month vs same month last year as two lines on the same chart. Easy with existing `linky_period_cache` and `linky_daily_cache` tables.

### Medium Effort, High Impact

8. **Electricity Price API Integration** — Replace static `prix_hp`/`prix_hc` variables with dynamic pricing from the RTE Tempo/EJP API or the EDF API. Auto-detect red/white/blue Tempo days and calculate costs accurately. Store pricing history in a new table.

9. **Carbon Footprint Panel** — Use RTE's eco2mix API (free, public) to get the real-time carbon intensity of French electricity (gCO2/kWh). Multiply by consumption to show daily/monthly carbon footprint in kg CO2.

10. **Push Notifications** — Lightweight Python script or Grafana webhook that sends a daily summary via Telegram/email: yesterday's consumption, cost, comparison to average. Grafana image renderer plugin can attach a chart screenshot.

11. **Appliance Detection** — Track sudden power jumps (PAPP deltas > threshold between consecutive readings). Log as "events" in a new table. Over time, users can label them ("oven", "washing machine", "EV charger") and get a breakdown of consumption by appliance. Basic NILM (Non-Intrusive Load Monitoring).

12. **Solar/Battery Integration** — If the user adds solar panels, add a second data source for production (e.g., Enphase/SolarEdge API) and show net consumption, self-consumption rate, and grid injection.

---

## Quick Wins Summary

| Feature | Effort | Impact | Implementation |
|---|---|---|---|
| Cost projection panel | ~1h | High | SQL query + Grafana stat panel |
| Temp vs consumption scatter | ~1h | High | Grafana XY chart from daily_cache |
| Consumption heatmap | ~1h | Medium | Grafana heatmap from realtime |
| Standby annual cost | ~30min | High | MIN(PAPP) query + stat panel |
| Year-over-year overlay | ~2h | High | SQL with date offset on daily_cache |
| Peak/off-peak savings | ~1h | High | Ratio calculation + gauge panel |
| `pool_pre_ping=True` | ~5min | Medium | One-line code change |
| Reduce clean_realtime freq | ~5min | Low | Change `EVERY 1 MINUTE` to `EVERY 15 MINUTE` |
