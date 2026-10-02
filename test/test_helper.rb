# frozen_string_literal: true
# Test bootstrap.
#
# Two flavours of test live here:
#
#   * in-process tests against the real lib (pure logic: schema building, similarity,
#     chunking, dispatch, prompt assembly). They read the real tree and never write
#     to it.
#   * sandboxed tests (Sandbox) that copy the tree into a tmpdir and drive it as a
#     child process. Anything that writes, commits, or installs lives here, so a test
#     can never damage the working copy.
#
# Nothing here needs a gem: minitest ships with Ruby as a default gem, and the two
# servers below are stdlib sockets. `rake test` runs everything.
require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "socket"
require "open3"

require "stringio"
require "rbconfig"

TEST_ROOT = File.expand_path("..", __dir__)

# ...and the Telegram poll offset, which the adapter reads *when it loads*: it has to point at
# the suite's own tmpdir before that require, or an in-process poller test writes the project's
# own data/telegram.offset. (Sandbox#child_env deletes it, so a sandboxed CLI uses its own.)
ENV["CLAW_TELEGRAM_OFFSET"] = File.join(Dir.mktmpdir("claw-offset-"), "telegram.offset")

require_relative "../lib/boot"
%w[notes registry harness telegram chat consolidate setup selfwrite selftest].each do |m|
  require_relative "../lib/#{m}"
end

# The usage log is the regression corpus consolidation replays. Tests must not
# pollute it.
ENV["CLAW_NO_USAGE"] = "1"

# ...and a test must never inherit this machine's configuration or credentials:
# boot.rb loads the real .env, so drop what it just loaded and forget the memo.
ENV_VARS = %w[CLAW_MODEL CLAW_BASE_URL CLAW_API_KEY CLAW_TELEGRAM_TOKEN
              CLAW_TELEGRAM_ALLOWED CLAW_TELEGRAM_OFFSET CLAW_SKIP_SETUP DEEPSEEK_API_KEY
              CLAW_RUBY CLAW_BROWSER CLAW_BROWSER_PROFILE CLAW_SHELL HERMES_HOME
              CLAW_POLICY].freeze
ENV_VARS.each { |k| ENV.delete(k) }
RubyClaw.override!   # all-nil: clears the memoised key, sets nothing

# ...and pinned, not just dropped: dotenv does `ENV[k] ||= v`, so the next
# RubyClaw.config call would have re-read the repo's real .env and handed an
# in-process test this machine's credentials. Sandbox#child_env deletes this again, so
# a sandboxed CLI still reads its own .env exactly the way production does.
ENV["CLAW_NO_DOTENV"] = "1"

# ...and the same for the crontab. A test that wants the write path uses a Sandbox with a
# stub `crontab` on PATH; child_env deletes this, so that path still works there.
ENV["CLAW_NO_CRONTAB"] = "1"

# ...and the autonomy policy, pinned to a file whose default is auto, so a test of tool
# *mechanics* is not also a test of the policy (see the fixture). The policy's own tests
# point CLAW_POLICY at the shipped policy.yml and assert the real enforcement.
ENV["CLAW_POLICY"] = File.join(__dir__, "support", "policy-permissive.yml")

Dir[File.join(__dir__, "support", "*.rb")].sort.each { |f| require f }

module ClawTest
  RUBY = ENV["CLAW_RUBY"] || RbConfig.ruby

  # The project's real runtime stores. A test must never write them -- leaks did, before this
  # check: a test that wrote the machine's crontab, a policy record that landed in
  # data/events.jsonl, and the Telegram poll offset the adapter persists. The snapshot is taken
  # before any test runs and checked again when the run ends (test_helper's after_run hook);
  # test/real_state_test.rb states the rule where it can be read. A test that needs these stores
  # runs in a Sandbox, whose ROOT is its own tmpdir, or points the store at a tmpdir itself.
  # (data/term, data/browser and data/screenshots are scratch working dirs, not records.)
  REAL_STORES = %w[data/work.json data/events.jsonl data/approvals.json data/artifacts.json
                   data/responsibilities.json data/pending-events.json
                   data/notifications.json data/heartbeat.json
                   data/telegram.offset].freeze

  def self.real_state_snapshot
    REAL_STORES.to_h do |rel|
      path = File.join(TEST_ROOT, rel)
      [rel, File.exist?(path) ? [File.size(path), File.mtime(path).to_f] : nil]
    end
  end

  REAL_STATE_BASELINE = real_state_snapshot.freeze

  # Raise if any real store changed since the baseline. Called when the run ends, so a leak
  # anywhere in the suite fails the run loudly instead of landing in the project's data/.
  def self.assert_real_state_untouched!(baseline = REAL_STATE_BASELINE)
    now = real_state_snapshot
    changed = REAL_STORES.select { |rel| baseline[rel] != now[rel] }
    return true if changed.empty?

    raise "REAL STATE LEAK: the suite wrote the project's own #{changed.join(', ')}. " \
          "A test must run in a ClawTest::Sandbox, never against the real tree."
  end

  # Is this program on PATH? Used to skip (not fail) tests that need an interpreter or
  # tool this machine may not have.
  def self.which(bin) = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, bin)) }

  # Capture stdout (and stderr) for code that insists on printing.
  def capture
    old_out, old_err = $stdout, $stderr
    out = StringIO.new
    err = StringIO.new
    $stdout = out
    $stderr = err
    yield
    [out.string, err.string]
  ensure
    $stdout = old_out
    $stderr = old_err
  end

  # Run a block with ENV variables set, restoring everything afterwards.
  def with_env(vars)
    old = ENV.to_h
    vars.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    ENV.replace(old)
    RubyClaw.override!   # forget the memo, change nothing
  end

  # A temporary copy of the tree that can be run, written to and committed in.
  class Sandbox
    attr_reader :dir

    def initialize(name = "claw")
      @dir = File.join(Dir.mktmpdir("clawtest-"), name)
      FileUtils.mkdir_p(@dir)
      %w[lib bin tools skills instance scripts].each do |d|
        src = File.join(TEST_ROOT, d)
        FileUtils.cp_r(src, @dir) if File.directory?(src)
      end
      %w[config.yml memory.md preferences.md rubyclaw policy.yml].each do |f|
        src = File.join(TEST_ROOT, f)
        FileUtils.cp(src, @dir) if File.file?(src)
      end
      FileUtils.mkdir_p(File.join(@dir, "log"))
    end

    def path(*parts) = File.join(@dir, *parts)
    def read(*parts) = File.read(path(*parts))
    def exist?(*parts) = File.exist?(path(*parts))
    def write(rel, body)
      FileUtils.mkdir_p(File.dirname(path(rel)))
      File.write(path(rel), body)
      body
    end

    def git_init!
      return if File.directory?(path(".git"))
      Open3.capture3("git", "init", "-q", chdir: @dir)
      # Repository-local identity: the harness commits its own growth, and a commit
      # must not depend on the machine having a global git user.
      Open3.capture3("git", "config", "user.email", "claw@test", chdir: @dir)
      Open3.capture3("git", "config", "user.name", "RubyClaw", chdir: @dir)
      Open3.capture3("git", "add", "-A", chdir: @dir)
      Open3.capture3("git", "commit", "-qm", "seed", chdir: @dir)
    end

    def git_log = Open3.capture3("git", "-C", @dir, "log", "--format=%s").first.split("\n")

    # Commit everything in the sandbox and return the new HEAD. Repository-local
    # identity, so a commit never depends on the machine having a global git user.
    def commit!(message)
      Open3.capture3("git", "-C", @dir, "add", "-A")
      Open3.capture3("git", "-C", @dir, "-c", "user.name=RubyClaw", "-c", "user.email=claw@test",
                     "commit", "-qm", message)
      Open3.capture3("git", "-C", @dir, "rev-parse", "HEAD").first.strip
    end

    # A child of the sandbox sees the sandbox as home and nothing of this machine's
    # configuration: no inherited key, no borrowed ~/.hermes/.env, no stray endpoint.
    def child_env(env)
      base = ENV_VARS.to_h { |k| [k, nil] }              # nil deletes it in the child
      base["CLAW_NO_DOTENV"] = nil                       # the child reads its own .env
      base["CLAW_NO_CRONTAB"] = nil                      # ...and may use its stub crontab
      base["HOME"] = @dir
      base["PATH"] = ENV["PATH"]
      base["CLAW_NO_USAGE"] = "1"
      # The suite's pinned autonomy policy travels to the child; a test that wants the
      # child to use its sandbox's own policy.yml passes CLAW_POLICY => nil to override.
      base["CLAW_POLICY"] = ENV["CLAW_POLICY"]
      base.merge(env)
    end

    # Run the CLI in the sandbox. Returns [stdout+stderr, Process::Status].
    # `timeout:` bounds a command that must return on its own -- a polling loop that
    # regresses would otherwise hang the whole suite instead of failing a test.
    def claw(*args, env: {}, stdin: nil, timeout: nil)
      cmd = [ClawTest::RUBY, path("bin", "claw"), *args].compact
      cmd = ["timeout", "-k", "5", timeout.to_i.to_s, *cmd] if timeout
      out, status = Open3.capture2e(child_env(env), *cmd, chdir: @dir, stdin_data: stdin.to_s)
      [out, status]
    end

    # Run arbitrary Ruby with lib/ on the load path, inside the sandbox.
    def ruby(code, env: {})
      out, status = Open3.capture2e(child_env(env), ClawTest::RUBY, "-I", path("lib"), "-e", code,
                                    chdir: @dir)
      [out, status]
    end

    # KEEP=1 leaves the sandbox on disk and says where, for when a test fails and the
    # state is the evidence.
    def cleanup
      if ENV["KEEP"].to_s == "1"
        warn "kept sandbox: #{@dir}"
      else
        FileUtils.rm_rf(File.dirname(@dir))
      end
    end
  end
end

# The check itself, at the end of the run: if any real store changed, this raises and the
# process exits non-zero, so a leak cannot pass quietly -- including one that happens after
# the real_state_test test has already run. See ClawTest.assert_real_state_untouched!.
Minitest.after_run { ClawTest.assert_real_state_untouched! }
