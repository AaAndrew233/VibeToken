import Foundation
import GRDB

enum DatabaseMigratorFactory {
    static func make() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { database in
            try database.create(table: "usage_sources") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull()
                table.column("display_name", .text).notNull()
                table.column("status", .text).notNull()
                table.column("accuracy", .text).notNull()
                table.column("last_scan_at", .datetime)
                table.column("last_error_code", .text)
            }

            try database.create(table: "conversations") { table in
                table.column("id", .text).primaryKey()
                table.column("source_id", .text)
                    .notNull()
                    .references("usage_sources", onDelete: .cascade)
                table.column("external_session_hash", .text).notNull()
                table.column("model_id", .text)
                table.column("project_label", .text)
                table.column("started_at", .datetime)
                table.column("last_event_at", .datetime)
                table.uniqueKey(["source_id", "external_session_hash"])
            }

            try database.create(table: "usage_events") { table in
                table.column("idempotency_key", .text).primaryKey()
                table.column("conversation_id", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                table.column("occurred_at", .datetime).notNull()
                table.column("input_tokens", .integer).notNull().defaults(to: 0)
                table.column("cached_input_tokens", .integer).notNull().defaults(to: 0)
                table.column("cache_write_tokens", .integer).notNull().defaults(to: 0)
                table.column("output_tokens", .integer).notNull().defaults(to: 0)
                table.column("reasoning_tokens", .integer).notNull().defaults(to: 0)
                table.column("total_tokens", .integer).notNull().defaults(to: 0)
                table.column("accuracy", .text).notNull()
                table.column("raw_schema_version", .text)
            }
            try database.create(
                index: "usage_events_conversation_time",
                on: "usage_events",
                columns: ["conversation_id", "occurred_at"]
            )

            try database.create(table: "ingest_checkpoints") { table in
                table.column("source_id", .text).notNull()
                table.column("file_identity", .text).notNull()
                table.column("canonical_path_hash", .text).notNull()
                table.column("byte_offset", .integer).notNull().defaults(to: 0)
                table.column("tail_guard_hash", .text)
                table.column("last_complete_line_at", .datetime)
                table.primaryKey(["source_id", "file_identity"])
            }

            try database.create(table: "price_rules") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("provider", .text).notNull()
                table.column("model_pattern", .text).notNull()
                table.column("effective_from", .datetime).notNull()
                table.column("effective_to", .datetime)
                table.column("input_price_micros", .integer).notNull()
                table.column("cached_input_price_micros", .integer).notNull()
                table.column("cache_write_price_micros", .integer).notNull()
                table.column("output_price_micros", .integer).notNull()
                table.column("currency", .text).notNull()
                table.column("source_url", .text).notNull()
            }
        }

        migrator.registerMigration("v2_usage_event_models_and_checkpoints") { database in
            try database.alter(table: "usage_events") { table in
                table.add(column: "model_id", .text)
            }
            try database.create(
                index: "usage_events_time_model",
                on: "usage_events",
                columns: ["occurred_at", "model_id"]
            )
            try database.alter(table: "ingest_checkpoints") { table in
                table.add(column: "current_model", .text)
                table.add(column: "has_cumulative", .boolean).notNull().defaults(to: false)
                table.add(column: "last_input_tokens", .integer).notNull().defaults(to: 0)
                table.add(column: "last_cached_input_tokens", .integer).notNull().defaults(to: 0)
                table.add(column: "last_cache_write_tokens", .integer).notNull().defaults(to: 0)
                table.add(column: "last_output_tokens", .integer).notNull().defaults(to: 0)
                table.add(column: "last_reasoning_tokens", .integer).notNull().defaults(to: 0)
                table.add(column: "last_total_tokens", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v3_codex_replay_deduplication") { database in
            try database.alter(table: "conversations") { table in
                table.add(column: "canonical_session_hash", .text)
                table.add(column: "parent_session_hash", .text)
                table.add(column: "forked_from_session_hash", .text)
                table.add(column: "session_created_at", .datetime)
                table.add(column: "is_subagent", .boolean).notNull().defaults(to: false)
                table.add(column: "replay_token_count", .integer).notNull().defaults(to: 0)
            }
            try database.create(
                index: "conversations_canonical_session_hash",
                on: "conversations",
                columns: ["canonical_session_hash"]
            )
            try database.create(
                index: "conversations_parent_session_hash",
                on: "conversations",
                columns: ["parent_session_hash", "forked_from_session_hash"]
            )

            try database.alter(table: "usage_events") { table in
                table.add(column: "raw_token_ordinal", .integer)
                table.add(column: "replay_fingerprint", .text)
            }
            try database.create(
                index: "usage_events_conversation_raw_ordinal",
                on: "usage_events",
                columns: ["conversation_id", "raw_token_ordinal"]
            )

            try database.create(table: "codex_raw_token_records") { table in
                table.column("conversation_id", .text)
                    .notNull()
                    .references("conversations", onDelete: .cascade)
                table.column("raw_token_ordinal", .integer).notNull()
                table.column("replay_fingerprint", .text).notNull()
                table.column("occurred_at", .datetime)
                table.primaryKey(["conversation_id", "raw_token_ordinal"])
            }
            try database.create(
                index: "codex_raw_token_records_fingerprint",
                on: "codex_raw_token_records",
                columns: ["conversation_id", "replay_fingerprint"]
            )

            try database.alter(table: "ingest_checkpoints") { table in
                table.add(column: "raw_token_count", .integer).notNull().defaults(to: 0)
                table.add(column: "last_raw_cumulative_total", .integer)
            }
        }

        return migrator
    }
}
