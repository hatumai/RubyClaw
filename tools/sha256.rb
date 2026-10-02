require "digest"
RubyClaw.tool "sha256",
  description: "SHA-256 hex digest of a string, or of a file's bytes. Stdlib only, no shelling out.",
  params: { "value" => { type: "string", description: "text to hash, or a path when from_file is true" },
            "from_file" => { type: "boolean", required: false,
                             description: "treat value as a file path" } } do |a|
  # Expanded against ROOT, like read_file/write_file/grep do — not against the
  # process's working directory, which made the same path mean two different files.
  data = a["from_file"] ? File.binread(File.expand_path(a["value"], ROOT)) : a["value"].to_s
  Digest::SHA256.hexdigest(data)
end
