# frozen_string_literal: true
require_relative "test_helper"

# An instance is a growth of the project rather than a snapshot of it, so an update must take what
# upstream changed *without* overwriting what this instance made for itself. These are real git
# repositories on disk: an "upstream" that is a copy of this harness, and a clone of it that then
# writes its own tool -- which is exactly what a running instance does.
class UpdateTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("claw-update-")
    @up = File.join(@dir, "upstream")
    @work = File.join(@dir, "work")
    FileUtils.mkdir_p(@up)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # A clone of this harness, with its own history, is the most honest fixture there is: the update
  # logic runs against a tree shaped exactly like a real instance.
  def seed_upstream!
    %w[README.md lib bin tools skills instance test scripts Rakefile rubyclaw VERSION config.yml .rubocop.yml].each do |entry|
      src = File.join(TEST_ROOT, entry)
      next unless File.exist?(src)

      FileUtils.cp_r(src, File.join(@up, entry))
    end
    # A file that exists in the seed, so upstream deleting it later is a real deletion in the diff.
    write(@up, "docs/gone.md", "committed upstream, deleted later\n")
    git(@up, "init", "-q", "-b", "main")
    # Repository-local identity in both fixtures: a commit must never depend on the machine having
    # a global git user (the same reason the harness's own git calls pass -c user.name).
    git(@up, "config", "user.email", "claw@test")
    git(@up, "config", "user.name", "RubyClaw test")
    git(@up, "add", "-A")
    git(@up, "commit", "-qm", "upstream seed")
    git(@dir, "clone", "-q", @up, @work)
    git(@work, "config", "user.email", "claw@test")
    git(@work, "config", "user.name", "RubyClaw test")
  end

  def git(dir, *args)
    out, err, st = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err.strip}" unless st.success?

    out
  end

  def write(dir, rel, body)
    FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
    File.write(File.join(dir, rel), body)
  end

  def read(dir, rel) = File.read(File.join(dir, rel))

  def commit(dir, message)
    git(dir, "add", "-A")
    git(dir, "commit", "-qm", message)
  end

  # Runs the harness's own update code against the fixture, the way `claw update` does.
  def run_update(check: false, work: @work)
    env = { "CLAW_NO_DOTENV" => "1", "CLAW_NO_USAGE" => "1", "CLAW_UPSTREAM" => @up }
    script = <<~RB
      require "boot"; require "update"
      r = RubyClaw::Update.run(check: #{check})
      puts r
      exit(r.ok? ? 0 : 1)
    RB
    out, err, st = Open3.capture3(env, ClawTest::RUBY, "-I", File.join(work, "lib"), "-e", script,
                                  chdir: work)
    [out + err, st]
  end

  # The instance writes its own tool on top of the seed, then upstream moves ahead in four ways:
  # a file the instance never touched, a core file, a brand new file, and the very file the instance
  # rewrote for itself.
  def diverge!
    write(@work, "tools/mine.rb", "# the tool this instance wrote for itself\n")
    commit(@work, "my own tool")

    write(@up, "README.md", "upstream readme, changed\n")
    write(@up, "lib/engine.rb", "upstream engine v2\n")
    write(@up, "lib/new.rb", "brand new upstream file\n")
    write(@up, "tools/mine.rb", "upstream's idea of the same tool\n")
    write(@up, "docs/gone.md", "to be deleted by upstream\n")
    commit(@up, "upstream moves on")
    git(@up, "rm", "-q", "-f", "docs/gone.md")
    commit(@up, "upstream drops a file")
  end

  def test_takes_what_it_has_not_touched_and_keeps_what_it_has
    seed_upstream!
    diverge!
    out, st, = run_update
    assert st.success?, out
    assert_match(/applied 4/, out)
    assert_match(/kept 1 of my own/, out)
    assert_includes out, "tools/mine.rb"

    assert_equal "upstream readme, changed\n", read(@work, "README.md"), "an untouched file is taken"
    assert_equal "upstream engine v2\n", read(@work, "lib/engine.rb"), "so is an untouched core file"
    assert_equal "brand new upstream file\n", read(@work, "lib/new.rb"), "and a new one"
    assert_equal "# the tool this instance wrote for itself\n", read(@work, "tools/mine.rb"),
                 "the tool this instance wrote for itself must survive an update untouched"
    assert_match(/restart claw/, out, "a core change has to say it needs a restart")
    refute File.exist?(File.join(@work, "docs", "gone.md")), "a deletion upstream made is taken"
  end

  def test_the_skipped_file_is_a_conflict_not_an_accident
    seed_upstream!
    diverge!
    out, = run_update
    assert_match(/kept as it is, changed here: tools\/mine\.rb/, out)
    refute_equal "upstream's idea of the same tool\n", read(@work, "tools/mine.rb")
  end

  def test_a_second_run_has_nothing_to_do
    seed_upstream!
    diverge!
    run_update
    out, st, = run_update
    assert st.success?, out
    assert_match(/up to date with upstream/, out)
  end

  def test_check_changes_nothing
    seed_upstream!
    diverge!
    before = read(@work, "README.md")
    head = git(@work, "rev-parse", "HEAD").strip
    out, st, = run_update(check: true)
    assert st.success?, out
    assert_match(/would apply/, out)
    assert_equal before, read(@work, "README.md"), "--check must not write"
    assert_equal head, git(@work, "rev-parse", "HEAD").strip, "--check must not commit"
  end

  def test_uncommitted_work_blocks_the_update_instead_of_being_swept_into_it
    seed_upstream!
    diverge!
    write(@work, "lib/engine.rb", "half-finished edit by a human\n")
    out, st, = run_update
    assert st.success?, out
    assert_match(/uncommitted changes/, out)
    assert_equal "half-finished edit by a human\n", read(@work, "lib/engine.rb")
  end

  # Two shapes of "not a checkout". A tree with no git at all, and the shape an extracted release
  # archive actually takes: ./rubyclaw git-inits the tree so the harness can commit its own growth,
  # so a .git exists — but with no remote and no upstream history, an update there can never succeed.
  # Neither may try a fetch and report that failure as a network problem.
  def test_a_tree_that_is_not_a_git_checkout_says_so
    FileUtils.mkdir_p(@work)
    FileUtils.cp_r(File.join(TEST_ROOT, "lib"), File.join(@work, "lib"))   # the code, but no .git
    out, st, = run_update
    assert_missing_checkout(out, st, "a tree with no git")

    # Now the archive shape: a repository the launcher auto-initialised, with no remote.
    git(@work, "init", "-q", "-b", "main")
    git(@work, "config", "user.email", "claw@test")
    git(@work, "config", "user.name", "RubyClaw test")
    write(@work, "VERSION", "0.11\n")
    commit(@work, "RubyClaw: initial import")
    out, st, = run_update(check: true)
    assert_missing_checkout(out, st, "an extracted archive the launcher git-inits")

    refute File.exist?(File.join(@work, ".git", "refs", "claw", "upstream")),
           "a missing checkout must not fetch anything"
  end

  # The shape a real extracted archive actually ends up in the first time it is run. ./rubyclaw
  # git-inits the tree so the harness can commit its own growth, and the init — or the .git shipped
  # inside the archive — can leave a remote configured. So "has a remote" cannot be the test: what
  # is missing is durable, no upstream history (refs/remotes/*) and no sync point (refs/claw/base).
  # This is the case that occurs in the real world, and it must refuse just as honestly.
  def test_a_launcher_initialised_tree_with_a_remote_is_still_not_a_clone
    FileUtils.mkdir_p(@work)
    FileUtils.cp_r(File.join(TEST_ROOT, "lib"), File.join(@work, "lib"))
    git(@work, "init", "-q", "-b", "main")
    git(@work, "config", "user.email", "claw@test")
    git(@work, "config", "user.name", "RubyClaw test")
    write(@work, "VERSION", "0.11\n")
    commit(@work, "RubyClaw: initial import")
    # Exactly what the archive, or a launcher's init, can leave behind: a remote, but no history.
    git(@work, "remote", "add", "origin", "git@github.com:hatumai/RubyClaw.git")

    out, st, = run_update(check: true)
    assert_missing_checkout(out, st, "a launcher-initialised tree that has a remote")

    refute File.exist?(File.join(@work, ".git", "refs", "claw", "upstream")),
           "a missing clone must not fetch anything"
    refute Dir.exist?(File.join(@work, ".git", "refs", "remotes")),
           "and nothing may be fetched into it"
  end

  # Refuses, names what is missing and the one fix, and does not blame the network or claim to have
  # done anything — a stable word ("clone"), not the whole sentence, so the reason can be reworded.
  def assert_missing_checkout(out, st, what)
    refute st.success?, "#{what} must fail loudly"
    assert_match(/clone/, out, "#{what}: the reason has to name what is missing")
    assert_match(%r{git clone https://github\.com/hatumai/RubyClaw\.git}, out,
                 "#{what}: it must name the clone that would work")
    refute_match(/cannot fetch|check the network/, out,
                 "#{what}: a missing checkout is not a network problem")
    refute_match(/up to date|applied/, out, "#{what}: it must not claim anything was done")
  end

  # The guarantee for instance/ is structural, not a comparison: the local copy here is *identical*
  # to the last synced one, so a rule that only asks "has this path changed here?" would take
  # upstream's version without hesitating. The update must refuse the path before it looks.
  def test_nothing_inside_the_instance_directory_is_taken_even_when_it_looks_safe
    seed_upstream!
    write(@work, "instance/tools/mine.rb", "# the tool this instance kept for itself\n")
    commit(@work, "my growth, in the safe place")
    write(@up, "instance/tools/mine.rb", "# upstream has no business in here\n")
    write(@up, "lib/engine.rb", "upstream engine v3\n")
    commit(@up, "upstream moves on, and overreaches")

    out, st, = run_update
    assert st.success?, out
    assert_equal "# the tool this instance kept for itself\n", read(@work, "instance/tools/mine.rb"),
                 "an update must never write into instance/"
    assert_equal "upstream engine v3\n", read(@work, "lib/engine.rb"), "and must still take what is outside it"
    refute_match(/instance\//, out, "upstream paths under instance/ are not even offered as a change")
  end
end
