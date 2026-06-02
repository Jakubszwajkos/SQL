-- =============================================================================
-- QUERY: consultant_chat_stats
-- =============================================================================
--
-- Context
-- -------
-- Chat dialog data is fetched from an external API and stored as raw JSON
-- blobs in a generic items table (one row per dialog). Each row contains
-- a nested JSON object with dialog metadata: timestamps, status, and the
-- operator (consultant) who handled the conversation.
--
-- Purpose
-- -------
-- Aggregate per-consultant chat statistics:
--   - total dialogs handled
--   - open vs closed dialog counts
--   - average consultant first-response time (minutes)
--   - average total dialog duration for closed dialogs (minutes)
--
-- JSON structure (relevant fields)
-- ---------------------------------
--   $.operator.email       consultant identifier
--   $.operator.created_at  timestamp of consultant's first action in dialog
--   $.created_at           dialog creation timestamp
--   $.updated_at           dialog close/last-update timestamp
--   $.is_chat_opened       boolean: true = still open, false = closed
--
-- Timestamps are ISO 8601 strings with UTC offset: '2024-03-15T10:22:00+00:00'
-- STR_TO_DATE with '%Y-%m-%dT%H:%i:%s+00:00' parses them into DATETIME.
--
-- Metrics
-- -------
--   dialogs_total       Total number of dialogs assigned to the consultant.
--
--   dialogs_open        Dialogs still open (is_chat_opened = true).
--
--   dialogs_closed      Dialogs closed (is_chat_opened = false).
--
--   avg_response_time_min
--       Average time in minutes from dialog creation ($.created_at) to the
--       consultant's first action ($.operator.created_at).
--       Rows where $.operator is NULL are excluded via WHERE clause,
--       so all remaining rows have a valid operator timestamp.
--
--   avg_dialog_duration_min
--       Average total dialog duration in minutes, from creation to last
--       update ($.updated_at). Calculated only for closed dialogs -- open
--       dialogs are excluded via CASE WHEN so they do not skew the average.
--
-- Filters
-- -------
--   source_name = 'chatbots_dialogs'  -- limits to chat dialog records only
--   $.operator IS NOT NULL            -- excludes bot-only dialogs with no
--                                        human consultant assigned
--
-- Notes
-- -----
-- - ROUND(..., 1) gives one decimal place for readability.
-- - TIMESTAMPDIFF(SECOND, ...) / 60 converts seconds to minutes before
--   rounding, avoiding integer truncation.
-- - The commented-out GROUP BY on operator.username is kept for reference;
--   email is used as the grouping key since it is more stable.
-- =============================================================================

SELECT
    JSON_UNQUOTE(JSON_EXTRACT(item_json, '$.operator.email'))           AS email,
    COUNT(*)                                                             AS dialogs_total,
    SUM(JSON_EXTRACT(item_json, '$.is_chat_opened') = true)             AS dialogs_open,
    SUM(JSON_EXTRACT(item_json, '$.is_chat_opened') = false)            AS dialogs_closed,

    -- Time from dialog creation to consultant's first action (minutes)
    ROUND(AVG(
        TIMESTAMPDIFF(SECOND,
            STR_TO_DATE(
                JSON_UNQUOTE(JSON_EXTRACT(item_json, '$.created_at')),
                '%Y-%m-%dT%H:%i:%s+00:00'
            ),
            STR_TO_DATE(
                JSON_UNQUOTE(JSON_EXTRACT(item_json, '$.operator.created_at')),
                '%Y-%m-%dT%H:%i:%s+00:00'
            )
        )
    ) / 60, 1)                                                          AS avg_response_time_min,

    -- Total dialog duration (minutes), closed dialogs only
    ROUND(AVG(
        CASE WHEN JSON_EXTRACT(item_json, '$.is_chat_opened') = false THEN
            TIMESTAMPDIFF(SECOND,
                STR_TO_DATE(
                    JSON_UNQUOTE(JSON_EXTRACT(item_json, '$.created_at')),
                    '%Y-%m-%dT%H:%i:%s+00:00'
                ),
                STR_TO_DATE(
                    JSON_UNQUOTE(JSON_EXTRACT(item_json, '$.updated_at')),
                    '%Y-%m-%dT%H:%i:%s+00:00'
                )
            )
        END
    ) / 60, 1)                                                          AS avg_dialog_duration_min

FROM chat_items
WHERE source_name = 'chatbots_dialogs'
  AND JSON_EXTRACT(item_json, '$.operator') IS NOT NULL

GROUP BY
    -- JSON_UNQUOTE(JSON_EXTRACT(item_json, '$.operator.username')),
    JSON_UNQUOTE(JSON_EXTRACT(item_json, '$.operator.email'))

ORDER BY dialogs_total DESC;
