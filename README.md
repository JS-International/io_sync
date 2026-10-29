# IoSync

One-way sync of Intelliflo Office (IO) person records into HighLevel contacts and Zoom Phone external contacts.
IO is the master and is never written. The only local state is the `io_sync_links` table.

Every run reads IO, HighLevel and Zoom in full, builds the desired state from IO, diffs it against the live
remote records and produces a **plan**. In plan mode (the default) the plan is emailed and nothing is written.
In apply mode the plan is executed, optionally restricted to the actions of a previously reviewed report.

## Install

```ruby
# Gemfile
gem "io_sync", git: "..."
```

```
bin/rails g io_sync:install
bin/rails db:migrate
bin/rails credentials:edit   # add the io_sync: section below
```

```yaml
io_sync:
  intelliflo: { tenant_id: "...", api_key: "...", client_id: "...", client_secret: "..." }
  high_level: { private_integration_token: "pit-..." }
  zoom: { account_id: "...", client_id: "...", client_secret: "..." }
```

## Running

| Command | Writes? | What it does |
|---|---|---|
| `bin/rails io_sync:plan` | no | Reads everything, emails the report with a JSON attachment. |
| `bin/rails io_sync:apply[io_sync-<run>.json]` | yes | Re-plans, applies only actions whose digest is in the reviewed JSON, reports the rest as unapproved. |
| `bin/rails io_sync:apply_all` | yes | Re-plans and applies everything. Unattended nightly mode. |
| `bin/rails io_sync:links:import[links.csv]` | local only | One-off import of link rows from the old app. |
| `bin/rails io_sync:snapshot[path.json]` | no | One full read, saved to a JSON snapshot. |
| `SNAPSHOT=path.json bin/rails io_sync:plan` | no | Plans against the snapshot if it exists (no API calls), otherwise reads live and saves it. Add `REFRESH=1` to re-read HL and Zoom live (about 16 calls). |
| `SNAPSHOT=path.json bin/rails io_sync:apply[report.json]` | yes | Applies the reviewed actions using the snapshot's Intelliflo data and live HL and Zoom. |
| `bin/rails io_sync:find[path.json,"Taylor Brooks"]` | no | Shows the IO record, link row, HL contact and Zoom contact matching a name, email or id. |

### Snapshots

A full plan run is one complete Intelliflo read, which the rate limit allows about once a day. To investigate
a report from the client ("these contacts don't match"), take one snapshot and explore it as often as needed:
`io_sync:find`, or `IoSync::Snapshot.load_file(path).find("brooks")` in a console. A record found in HL but
with `listed_by_intelliflo: false` is one Intelliflo no longer returns (archived, deleted or restricted).

The same snapshot can drive the day's sync, so the one Intelliflo read covers investigation and apply:

1. `bin/rails io_sync:snapshot[snap.json]` (the day's Intelliflo read).
2. `SNAPSHOT=snap.json bin/rails io_sync:plan` as often as needed (with `REFRESH=1` for the final review, so it
   matches the live HL and Zoom state apply will see); review the emailed report JSON, editing it
   down to the actions you approve if you like (e.g. only `"target": "hl"`).
3. `SNAPSHOT=snap.json bin/rails io_sync:apply[io_sync-<run>.json]`.

Apply uses only the snapshot's Intelliflo side and re-reads HighLevel and Zoom live, so writes are diffed
against their current state. It refuses a missing snapshot rather than reading Intelliflo again, and refuses one
older than `snapshot_max_age_hours` (24). Anything that changed in Intelliflo after the snapshot waits for the
next day's read.

Snapshots hold every client's personal data. They are written owner-read-only; delete them when done and never
commit them.

Apply mode refuses to run unless `IoSync.config.writes_enabled` is `true`, and even then every HTTP connection
is read-only unless built by the applier. Intelliflo has no write methods at all.

Scheduling with Solid Queue (`config/recurring.yml`):

```yaml
production:
  io_sync_nightly:
    class: IoSync::ReconcileJob
    args: ["plan"]            # switch to ["apply"] after sign-off
    queue: io_sync
    schedule: at 4am every day
```

With Sidekiq, schedule `IoSync::ReconcileJob.perform_later("plan")` from sidekiq-cron or similar.

## Bootstrapping links from the old app

```sql
\copy (SELECT c.io_id, lower(c.details->>'type') AS io_type, h.hl_id AS hl_contact_id,
              p.external_contact_id AS zoom_external_contact_id
       FROM io_clients c
       LEFT JOIN hl_contacts h ON h.io_client_id = c.id
       LEFT JOIN phone_contacts p ON p.intelliflo_id = c.io_id::text
       WHERE h.id IS NOT NULL OR p.id IS NOT NULL ORDER BY c.io_id) TO 'io_sync_links.csv' CSV HEADER
```

## Rules

See `lib/io_sync/io_record.rb`, `hl_mapper.rb`, `zoom_mapper.rb` and `planners/` for the field mappings,
the service-status allowlist, email-conflict handling, link housekeeping and the archived-client prune cap.
