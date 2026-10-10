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

        return migrator
    }
}
