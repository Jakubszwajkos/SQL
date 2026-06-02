-- =============================================================================
-- VIEW: revenue_monthly_adjustment
-- =============================================================================
--
-- Problem
-- -------
-- The client's billing system operates on ISO weeks (YYYYWW format).
-- Revenue and cost data is therefore aggregated per ISO week, not per calendar
-- month. ISO weeks often straddle two months (e.g. a week starting Jan 30
-- spans January and February), so a naive GROUP BY month would assign the
-- entire week's figures to whichever month the settlement date falls in --
-- distorting monthly totals.
--
-- Solution: day-level proration
-- ------------------------------
-- Each ISO week is split into its 7 individual days using a recursive CTE
-- (days). Every week's cost and revenue figures are divided by 7,
-- producing a daily amount. Those daily amounts are then grouped by calendar
-- month, so weeks that span a month boundary contribute proportionally to
-- each month.
--
-- Example
--   Week 2025-W05 runs Mon 27 Jan - Sun 02 Feb.
--   5 days fall in January, 2 days in February.
--   A weekly car-rental cost of 700 is split:
--     January  -> 5 * (700/7) = 500
--     February -> 2 * (700/7) = 200
--
-- CTEs
-- ----
--   days           - Generates integers 0-6 representing day offsets within
--                    a week (recursive).
--
--   weekly_base    - Aggregates raw transaction records by ISO week.
--                    Only settlement weeks that have a confirmed reservation
--                    record are included (EXISTS filter).
--                    Cost categories (car rental, damage, fuel, fines,
--                    settlement commission) are summed with sign inversion
--                    so that all output columns represent expense amounts
--                    (positive = cost to the operator).
--
--   weekly_with_start - Converts the YYYYWW integer key into an actual
--                       DATE (Monday of that ISO week) using MySQL's
--                       %x %v %w strptime pattern.
--
-- Final SELECT
-- ------------
-- Joins weekly_with_start with the days offset table (cross join),
-- adds the day offset to week_start to get a concrete date per day,
-- formats that date as YYYY-MM, then sums the prorated daily amounts
-- grouped by month.
--
-- Output columns
-- --------------
--   month_num             YYYY-MM label for the calendar month
--   car_rental            Prorated vehicle rental costs
--   damage                Prorated damage charge costs
--   settlement_commission Commission charged by the settlement operator
--   fuel                  Prorated fuel costs
--   fines                 Prorated traffic fine / indication-fee costs
--
-- Notes
-- -----
-- - Data window starts from 2024-12-27 (first day of ISO week 2025-W01).
-- - The recursive CTE depth of 6 (0..6) matches exactly one ISO week.
-- - All monetary values are stored as net amounts in the source table.
-- =============================================================================

CREATE OR REPLACE VIEW revenue_monthly_adjustment AS

WITH RECURSIVE days AS (
    SELECT 0 AS d
    UNION ALL
    SELECT d + 1 FROM days WHERE d < 6
),

weekly_base AS (
    SELECT
        t.settlement_week,
        SUM(CASE WHEN t.type = 'car_rental'        THEN t.amount_net * -1 ELSE 0 END) AS car_rental,
        SUM(CASE WHEN t.type = 'damage'             THEN t.amount_net * -1 ELSE 0 END) AS damage,
        SUM(CASE WHEN t.type = 'commission'         THEN t.amount_net * -1 ELSE 0 END) AS settlement_commission,
        SUM(CASE WHEN t.type = 'fuel'               THEN t.amount_net * -1 ELSE 0 END) AS fuel,
        SUM(CASE WHEN t.type = 'fine'               THEN t.total_payment * -1 ELSE 0 END) AS fines
    FROM transactions t
    WHERE
        t.transaction_date >= '2024-12-27'
        AND t.type IN ('car_rental','damage','commission','fuel','fine')
        AND EXISTS (
            SELECT 1
            FROM reservations r
            WHERE r.driver_email    = t.driver_email
              AND r.settlement_week = t.settlement_week
        )
    GROUP BY t.settlement_week
),

weekly_with_start AS (
    SELECT
        wb.*,
        STR_TO_DATE(
            CONCAT(FLOOR(wb.settlement_week / 100), ' ',
                   LPAD(wb.settlement_week % 100, 2, '0'), ' 1'),
            '%x %v %w'
        ) AS week_start
    FROM weekly_base wb
)

SELECT
    DATE_FORMAT(wws.week_start + INTERVAL d.d DAY, '%Y-%m') AS month_num,
    SUM(wws.car_rental            / 7) AS car_rental,
    SUM(wws.damage                / 7) AS damage,
    SUM(wws.settlement_commission / 7) AS settlement_commission,
    SUM(wws.fuel                  / 7) AS fuel,
    SUM(wws.fines                 / 7) AS fines
FROM weekly_with_start wws
JOIN days d ON 1 = 1
GROUP BY DATE_FORMAT(wws.week_start + INTERVAL d.d DAY, '%Y-%m')
ORDER BY month_num;
