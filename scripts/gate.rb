#!/usr/bin/env ruby
# frozen_string_literal: true
#
# The gate: what runs before anything is pushed.
#
# It exports HEAD (not the working tree) to a throwaway directory and runs the whole
# suite there, so a release is verified as a stranger would receive it -- uncommitted
# work in the tree cannot leak into the verdict. One log per commit lives in the
# scratch directory: an earlier version of this wrote to a single fixed path, and a
# second run silently destroyed the evidence of the first.
#
# Usage: ruby scripts/gate.rb          (everything)
#        ruby scripts/gate.rb -v       (show the suite's own output too)

require "fileutils"
require "tmpdir"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
LOG_DIR = File.join(ENV["HOME"], ".hermes", "cache", "scratch")

def run(*cmd, chdir: ROOT)
  out = IO.popen(cmd, chdir: chdir, err: [:child, :out], &:read)
  [out, $?.exitstatus]
end

unless File.directory?(File.join(ROOT, ".git"))
  abort "not a checkout: #{ROOT}"
end

sha, = run("git", "rev-parse", "--short", "HEAD")
sha = sha.strip
dirty = !run("git", "status", "--porcelain").first.strip.empty?

dir = File.join(Dir.tmpdir, "rubyclaw-gate-#{sha}")
FileUtils.rm_rf(dir)
FileUtils.mkdir_p(dir)
archive, status = run("git", "archive", "HEAD")
abort "git archive failed (#{status})" unless status.zero?
IO.popen(["tar", "-x", "-C", dir], "w") { |io| io.write(archive) }

puts "HEAD      #{sha}#{dirty ? "  (working tree has uncommitted changes; the export does not include them)" : ""}"
puts "export    #{dir}"
puts "ruby      #{RbConfig.ruby}"
puts "running   test/all.rb"
puts

started = Time.now
out, status = run(RbConfig.ruby, "-Ilib", "-Itest", "test/all.rb", chdir: dir)
elapsed = (Time.now - started).round(1)

summary = out.lines.grep(/runs,.*assertions/).last || "(no summary line found)"
failures = out.lines.grep(/^\s*\d+\) (Failure|Error)/)
FileUtils.mkdir_p(LOG_DIR)
log = File.join(LOG_DIR, "gate-#{sha}.log")
File.write(log, out)

puts "elapsed   #{elapsed}s"
puts summary.strip
puts "exit      #{status}"
puts "log       #{log}"
unless failures.empty?
  puts
  puts "--- failures ---"
  puts failures.first(40).join
end
puts
puts(out) if ARGV.include?("-v")
FileUtils.rm_rf(dir)
exit(status.zero? ? 0 : 1)
