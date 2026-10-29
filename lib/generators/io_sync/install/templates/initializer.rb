IoSync.configure(validate: false) do |c|   # validated when a run starts
  c.hl_location_id = "YOUR_HL_LOCATION_ID"
  c.hl_custom_field_ids = {
    courtesy_title: "HL_FIELD_ID",
    salutation: "HL_FIELD_ID",
    category: "HL_FIELD_ID",
    service_status: "HL_FIELD_ID",
    adviser: "HL_FIELD_ID",
    customer_crm: "HL_FIELD_ID"
  }
  c.hl_client_ref_field_id = nil   # optional HL field holding "<tenant>-<io id>"   # read only, for the orphaned-contacts report
  # Only records with one of these service statuses are created in HighLevel.
  # This list is also what keeps dependants, relatives and corporate records out.
  c.hl_service_status_allowlist = [
    "Staff", "Prospect", "New Financial Planning", "Financial Planning",
    "Investment", "Transactional", "Lead - Closed", "Lead - Initial"
  ]
  c.hl_type_map = IoSync::Configuration::DEFAULT_TYPE_MAP
  c.hl_type_fallback = :keep_current        # or "???" to reproduce the old app
  c.hl_default_source = "Wealthwide's CRM System"
  c.zoom_exclude_statuses = [ "Deceased" ]    # their Zoom contact is deleted
  c.zoom_include_leads = false
  c.mail_to = "ops@example.com"
  c.summary_mail_to = "office@example.com"   # plain-English summary; leave nil to skip
  c.mail_from = "noreply@example.com"
  c.time_zone = "Europe/London"
  c.io_concurrency = 4
  c.io_requests_per_second = 8
  c.credentials = -> { Rails.application.credentials.io_sync }
  # Kill switch. Keep false until plan reports have been reviewed.
  c.writes_enabled = false
end
