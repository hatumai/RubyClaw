# frozen_string_literal: true
require_relative "test_helper"

# ./rubyclaw itself: the hand-over, the failures it can hit before Ruby exists, and
# the promise that those failures read like sentences.
class EntrypointTest < Minitest::Test
  include ClawTest

  ENTRY = File.join(TEST_ROOT, "rubyclaw")

  def sh(*args, env: {})
    Open3.capture2e(env, ENTRY, *args, chdir: TEST_ROOT)
  end

  def test_help_lists_the_entry_points
    out, st = sh("--help")
    assert st.success?, out
    assert_match(/RubyClaw entry point/, out)
    assert_match(/\.\/rubyclaw up/, out)
  end

  def test_it_hands_over_to_a_ruby_it_did_not_install
    out, st = sh("probe", env: { "CLAW_RUBY" => ClawTest::RUBY })
    assert st.success?, out
    assert_match(/BOOT_OK \d+ tools: sh, read_file/, out)
  end

  def test_it_passes_arguments_through
    out, st = sh("tools", env: { "CLAW_RUBY" => ClawTest::RUBY })
    assert st.success?, out
    assert_match(/sha256\s+\[self\]/, out)
  end

  def test_a_pointless_CLAW_RUBY_fails_with_a_sentence
    out, st = sh("probe", env: { "CLAW_RUBY" => "/bin/false" })
    refute st.success?
    assert_match(/CLAW_RUBY=\/bin\/false is not usable/, out)
    refute_match(/\tfrom /, out, "no backtrace")
  end

  def test_it_makes_the_tree_a_git_repository_if_it_arrived_without_one
    sb = ClawTest::Sandbox.new("entry")
    refute File.directory?(File.join(sb.dir, ".git"))
    out, st = Open3.capture2e({ "CLAW_RUBY" => ClawTest::RUBY }, File.join(sb.dir, "rubyclaw"),
                              "probe", chdir: sb.dir)
    assert st.success?, out
    assert File.directory?(File.join(sb.dir, ".git")), "the harness commits its own growth"
  ensure
    sb&.cleanup
  end

  # A platform with no prebuilt Ruby is a dead end that upstream created, not one the
  # script can fix -- so it must explain it, name the way round, and not waste a
  # download trying to serve a CPU nobody builds for. This used to say
  # "unsupported architecture: armv6l" and stop, which is where a Pi Zero landed.
  def test_an_architecture_with_no_prebuilt_ruby_says_what_to_do
    bindir = Dir.mktmpdir("clawbin-")
    File.write(File.join(bindir, "uname"), <<~SH)
      #!/bin/sh
      [ "${1:-}" = "-m" ] && echo armv6l || /usr/bin/uname "$@"
    SH
    # ...and an old system Ruby, to check the message names it rather than shrugging.
    File.write(File.join(bindir, "ruby"), "#!/bin/sh\necho 2.7.4\n")
    File.chmod(0o755, File.join(bindir, "uname"))
    File.chmod(0o755, File.join(bindir, "ruby"))
    home = Dir.mktmpdir("clawhome-")
    out, st = Open3.capture2e({ "PATH" => "#{bindir}:/usr/bin:/bin", "HOME" => home,
                                "CLAW_HOME" => File.join(home, ".rubyclaw") },
                              ENTRY, "probe", chdir: TEST_ROOT)
    refute st.success?
    assert_match(/no prebuilt Ruby for armv6l/, out)
    assert_match(/is Ruby 2\.7\.4, which is too old/, out)
    assert_match(/apt install ruby-full/, out, "a dead end must come with the way forward")
    assert_match(/CLAW_RUBY=/, out)
    refute_match(/downloading/, out, "no point fetching a build that does not exist")
    refute_match(/\tfrom /, out, "no backtrace")
  ensure
    FileUtils.rm_rf([bindir, home])
  end

  # No Ruby, and the download cannot work: it must say so rather than hang or lie.
  #
  # The architecture is faked as well as the tools, and the fake says Linux/x86-64 because that
  # is where a prebuilt Ruby exists at all. Without it this test passed or failed depending on
  # the machine it ran on: on a Pi Zero (armv6l) the architecture gate answers first -- correctly,
  # and there is nothing to download -- so the fallback path this test is about is unreachable
  # and all four assertions failed. A test about a failed download should not depend on which
  # chip is running it.
  def test_a_failed_install_explains_itself
    bindir = Dir.mktmpdir("clawbin-")
    File.write(File.join(bindir, "uname"), <<~SH)
      #!/bin/sh
      case "${1:-}" in
        -s) echo Linux ;;
        -m) echo x86_64 ;;
        *)  /usr/bin/uname "$@" ;;
      esac
    SH
    File.chmod(0o755, File.join(bindir, "uname"))
    File.write(File.join(bindir, "curl"), "#!/bin/sh\nexit 22\n")
    File.chmod(0o755, File.join(bindir, "curl"))
    # A too-old system Ruby, so the outcome does not depend on whether the machine
    # running this test happens to have a usable one (it did not on the Pi).
    File.write(File.join(bindir, "ruby"), "#!/bin/sh\necho 2.7.4\n")
    File.chmod(0o755, File.join(bindir, "ruby"))
    home = Dir.mktmpdir("clawhome-")
    out, st = Open3.capture2e({ "PATH" => "#{bindir}:/usr/bin:/bin", "HOME" => home,
                                "CLAW_HOME" => File.join(home, ".rubyclaw") },
                              ENTRY, "probe", chdir: TEST_ROOT)
    refute st.success?
    assert_match(/using Ruby \d/, out, "falls back to a pinned version when the API is unreachable")
    assert_match(/download failed/, out)
    assert_match(/could not install a working Ruby/, out)
    assert_match(/Install Ruby 3\.1\+/, out)
  ensure
    FileUtils.rm_rf([bindir, home])
  end
end
