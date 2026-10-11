import GRDB

/// Database schema, defined as an ordered list of migrations.
///
/// GRDB records which migrations have run in each database file and only runs
/// new ones. Never edit a migration after it has shipped: add a new one instead.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1: lectures and transcript segments") { db in
            try db.create(table: "lecture") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("status", .text).notNull()
                t.column("sourceFileName", .text)
            }

            try db.create(table: "transcriptSegment") { t in
                t.primaryKey("id", .text)
                t.column("lectureId", .text).notNull()
                    .references("lecture", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
            }
            // Serves "segments of lecture X in time order", the most common query.
            try db.create(index: "transcriptSegment_on_lectureId_startMs",
                          on: "transcriptSegment", columns: ["lectureId", "startMs"])
        }

        migrator.registerMigration("v2: lecture summaries") { db in
            // One summary per lecture; regenerating replaces it.
            try db.create(table: "summary") { t in
                t.primaryKey("lectureId", .text)
                    .references("lecture", onDelete: .cascade)
                t.column("overview", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "summaryPoint") { t in
                t.column("lectureId", .text).notNull()
                    .references("summary", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("startMs", .integer).notNull()
                t.column("text", .text).notNull()
                t.primaryKey(["lectureId", "position"])
            }
        }

        migrator.registerMigration("v3: transcript full-text search") { db in
            // External-content FTS5 index over transcriptSegment.text. GRDB adds
            // triggers that keep it in sync on insert/update/delete, and rebuilds
            // it from the rows that already exist.
            try db.create(virtualTable: "transcriptSegment_ft", using: FTS5()) { t in
                t.synchronize(withTable: "transcriptSegment")
                // Porter stemming: "eigenvalues" and "eigenvalue" match each other.
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("text")
            }
        }

        return migrator
    }
}
