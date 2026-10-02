require "rexml/document"
require "net/http"
require "uri"
require "time"

RubyClaw.tool(
  "feed_items",
  description: "Fetch an RSS or Atom feed and return the newest items as 'idx. published — title — link' lines.",
  params: {
    "url" => { "type" => "string", "description" => "Feed URL (RSS or Atom)" },
    "limit" => { "type" => "integer", "required" => false,
                 "description" => "Max items to return (default 10)" }
  }
) do |url:, limit: 10|
  limit = limit.to_i
  limit = 10 if limit <= 0

  # Not URI.open: open-uri honours file:// and |command, so a URL that came out of
  # fetched page content could read local files or run a command. http(s) only, and
  # the response is read through Net::HTTP like the `http` builtin.
  target = URI(url.to_s)
  unless %w[http https].include?(target.scheme)
    raise "feed_items only fetches http(s), got #{target.scheme.inspect}"
  end

  xml = Net::HTTP.start(target.host, target.port, use_ssl: target.scheme == "https",
                        open_timeout: 10, read_timeout: 20) do |h|
    req = Net::HTTP::Get.new(target)
    req["User-Agent"] = "rubyclaw-feed_items/1.0"
    res = h.request(req)
    raise "feed_items got #{res.code} from #{target.host}" unless res.code.to_i == 200

    res.body.to_s
  end

  doc = REXML::Document.new(xml)
  root = doc.root
  raise "no XML root in #{url}" unless root

  # Find item/entry nodes regardless of nesting (rss/channel/item, feed/entry, rdf).
  nodes = []
  root.each_recursive do |el|
    nodes << el if %w[item entry].include?(el.name.to_s.split(":").last)
  end
  nodes = [root] if nodes.empty? && %w[item entry].include?(root.name.to_s.split(":").last)

  # Child text of the first matching direct child element (namespace-tolerant).
  child_text = lambda do |el, names|
    el.elements.each do |c|
      local = c.name.to_s.split(":").last
      return c.text.to_s.strip if names.include?(local)
    end
    nil
  end

  items = nodes.first(500).map do |el|
    title = (child_text.call(el, %w[title]) || "(no title)").gsub(/\s+/, " ")

    published = child_text.call(el, %w[pubDate published updated date])
    published = nil if published && published.empty?
    published =
      if published
        begin
          Time.parse(published).utc.strftime("%Y-%m-%d %H:%M UTC")
        rescue ArgumentError
          published.gsub(/\s+/, " ")
        end
      else
        "unknown"
      end

    link = child_text.call(el, %w[link])
    if link.nil? || link.empty?
      el.elements.each do |c|
        next unless c.name.to_s.split(":").last == "link"
        href = c.attributes["href"]
        if href && !href.empty?
          link = href
          break
        end
      end
    end
    link = "(no link)" if link.nil? || link.empty?

    [published, title, link]
  end

  items = items.first(limit)
  raise "no items found in #{url}" if items.empty?

  items.each_with_index.map { |(p, t, l), i| "#{i + 1}. #{p} — #{t} — #{l}" }.join("\n")
end
