# frozen_string_literal: true
# The durable, human-readable files the harness keeps about itself.
#
#   preferences.md   how the user wants it to work — tone, format, rules, things to
#                    avoid. Recorded whenever the user corrects it or states a
#                    preference, and honoured from the next request onward.
#   memory.md        facts it learned: about this machine, this project, the world.
#   skills/*.md      procedures it worked out and would hate to rediscover.
#   instance/skills/*.md   the ones the harness wrote itself (grows forever).
#
# All three are plain markdown, injected into every system prompt, edited by hand as
# easily as by the model, and safe to delete. Nothing here is a database.
# Skills ship in skills/ and are grown in instance/skills/; both are read, and an
# instance skill of the same name wins.
require "fileutils"

module RubyClaw
  PREFERENCES = File.join(ROOT, "preferences.md") unless defined?(PREFERENCES)

  module Notes
    # Per-file ceiling for injection, so one runaway file cannot eat the context.
    # Truncation is announced inside the prompt rather than silent.
    MAX_INJECT = 4_000

    HEADERS = {
      preference: <<~MD,
        # Preferences
        <!-- How this user wants RubyClaw to work: tone, length, format, standing rules.
             Written by the `remember` tool when the user corrects it or states a preference,
             and honoured from the next request onward. Edit by hand freely. -->
      MD
      memory: <<~MD
        # Memory
        <!-- Facts RubyClaw learned about this machine, this project, or the world.
             Written by the `remember` tool; injected into every system prompt. -->
      MD
    }.freeze

    FILES = { preference: PREFERENCES, memory: MEMORY }.freeze

    class << self
      def path(kind) = FILES.fetch(kind.to_sym) { raise Error, "unknown note kind: #{kind}" }

      def ensure!
        HEADERS.each do |kind, header|
          p = path(kind)
          next if File.exist?(p)
          FileUtils.mkdir_p(File.dirname(p))
          File.write(p, header)
        end
        FileUtils.mkdir_p(SKILLS_DIR)
        self
      end

      # Append one durable line, dated so the prompt shows how stale it is.
      def append(kind, text, at: Time.now)
        line = text.to_s.strip.gsub(/\s+/, " ")
        raise Error, "nothing to remember" if line.empty?
        ensure!
        File.open(path(kind), "a") { |f| f.puts "- #{at.strftime('%Y-%m-%d')} #{line}" }
        "#{kind}: #{line[0, 80]}"
      end

      def read(kind) = File.exist?(path(kind)) ? File.read(path(kind)).strip : ""

      # Every skill the prompt will inject, by name: the shipped set first, then this
      # instance's own, so an instance skill of the same name wins rather than being
      # shadowed. Returns an ordered { name => path } hash.
      def skill_files
        seen = {}
        [CORE_SKILLS_DIR, SKILLS_DIR].each do |dir|
          Dir[File.join(dir, "*.md")].sort.each { |f| seen[File.basename(f, ".md")] = f }
        end
        seen
      end

      def skills
        skill_files.map do |name, f|
          "\n### #{name}\n#{clip(File.read(f).strip)}\n"
        end.join
      end

      # The prompt block. Preferences come first and are labelled as overriding
      # defaults, because that is what they are.
      def inject
        prefs = read(:preference)
        mem = read(:memory)
        skl = skills
        out = +""
        unless prefs.empty?
          out << "\n## Preferences the user has stated\n" \
                 "These override your defaults and anything you think is more elegant. " \
                 "Follow them without being asked again.\n#{clip(prefs)}\n"
        end
        out << "\n## What you remember\n#{clip(mem)}\n" unless mem.empty?
        out << "\n## Skills you wrote\n#{skl}\n" unless skl.empty?
        out
      end

      def clip(text)
        text.length > MAX_INJECT ? "#{text[0, MAX_INJECT]}\n[... truncated; the file is longer]" : text
      end
    end
  end
end
