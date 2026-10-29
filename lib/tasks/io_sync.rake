namespace :io_sync do
  desc "Plan only: read everything, email the report, write nothing. SNAPSHOT=path.json reuses (or saves) a snapshot; REFRESH=1 re-reads HL and Zoom live"
  task plan: :environment do
    report = IoSync.reconcile(mode: :plan, snapshot: ENV["SNAPSHOT"].presence, refresh_remote: ENV["REFRESH"].present?)
    puts report.summary_line
    puts report.problems
  end

  desc "Read IO, HL and Zoom once and save everything to a JSON snapshot (contains personal data; delete when done)"
  task :snapshot, [ :path ] => :environment do |_, args|
    path = args[:path].presence || Rails.root.join("tmp", "io_sync-snapshot-#{Time.now.strftime('%Y%m%d-%H%M%S')}.json").to_s
    abort "#{path} already exists" if File.exist?(path)
    report = IoSync.reconcile(mode: :plan, snapshot: path)
    puts report.summary_line
    puts "Snapshot saved to #{path}"
  end

  desc "Show what IO, HL and Zoom hold for a name, email or id, from a saved snapshot: io_sync:find[snapshot.json,\"Taylor Brooks\"]"
  task :find, [ :path, :query ] => :environment do |_, args|
    abort "usage: rake io_sync:find[snapshot.json,query]" if args[:path].to_s.empty? || args[:query].to_s.empty?
    snapshot = IoSync::Snapshot.load_file(args[:path])
    snapshot.links = IoSync::Link.store.all.to_h { |l| [ l.io_id, l ] }
    results = snapshot.find(args[:query])
    puts "No matches for #{args[:query].inspect}" if results.empty?
    results.each do |r|
      io_id = r[:io]&.io_id || r[:link]&.io_id
      listed = io_id && snapshot.io_listed_ids.values.any? { |ids| ids.include?(io_id) }
      puts JSON.pretty_generate(
        io_id: io_id, listed_by_intelliflo: listed, service_status: r[:io]&.service_status,
        io: r[:io]&.to_h, link: r[:link]&.to_h, hl: r[:hl], zoom: r[:zoom]
      )
    end
  end

  desc "Apply the actions from a reviewed report JSON (re-plans first; unmatched actions are skipped). " \
       "SNAPSHOT=path.json takes Intelliflo from the snapshot; HL and Zoom are re-read live"
  task :apply, [ :report_path ] => :environment do |_, args|
    abort "usage: rake io_sync:apply[path/to/io_sync-<run>.json]" if args[:report_path].to_s.empty?
    approved = IoSync::Report.from_file(args[:report_path])
    report = IoSync.reconcile(mode: :apply, approved: approved, snapshot: ENV["SNAPSHOT"].presence)
    puts report.summary_line
    puts report.problems
  end

  desc "Re-plan and apply everything (unattended nightly mode)"
  task apply_all: :environment do
    report = IoSync.reconcile(mode: :apply)
    puts report.summary_line
    puts report.problems
  end

  namespace :links do
    desc "Import link rows from a CSV with columns io_id,io_type,hl_contact_id,zoom_external_contact_id"
    task :import, [ :path ] => :environment do |_, args|
      require "csv"
      abort "usage: rake io_sync:links:import[path.csv]" if args[:path].to_s.empty?
      store = IoSync::Link.store
      imported = 0
      skipped = []
      CSV.foreach(args[:path], headers: true) do |row|
        io_id = row["io_id"].to_i
        hl = row["hl_contact_id"].presence
        zoom = row["zoom_external_contact_id"].presence
        next if hl.nil? && zoom.nil?
        begin
          store.set(io_id, io_type: row["io_type"].to_s.downcase, hl_contact_id: hl, zoom_external_contact_id: zoom)
          imported += 1
        rescue ActiveRecord::RecordInvalid => e
          skipped << "#{io_id}: #{e.message}"
        end
      end
      puts "Imported #{imported} link rows. Skipped #{skipped.size}."
      puts skipped
    end
  end
end
