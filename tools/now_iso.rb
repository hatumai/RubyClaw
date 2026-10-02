RubyClaw.tool("now_iso", description: "Current local time in ISO-8601 (e.g. 2026-09-30T14:03:21-06:00) for a given numeric UTC offset in hours, stdlib only.", params: { tz_offset_hours: { type: "number", description: "UTC offset in hours, e.g. 0 for UTC, -6 for US Central" } }) do |args|
  offset = args["tz_offset_hours"].to_f
  seconds = (offset * 3600).round
  sign = seconds < 0 ? "-" : "+"
  abs = seconds.abs
  offset_s = format("%s%02d:%02d", sign, abs / 3600, (abs % 3600) / 60)
  t = Time.now.getlocal(offset_s)
  { offset: offset_s, iso8601: t.strftime("%Y-%m-%dT%H:%M:%S") + offset_s, unix: t.to_i }.to_json
end