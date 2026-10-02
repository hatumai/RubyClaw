# frozen_string_literal: true
require_relative "test_helper"

# The Ruby relocation is the trickiest code in the project: it rewrites a baked-in
# absolute prefix in place, inside ELF binaries, without patchelf. These tests build a
# synthetic tarball tree and assert the invariants the real thing depends on -- same
# file size (so every ELF offset stays valid), no stale prefix anywhere, and a
# NUL-separated list repacked so its terminator is still immediately after the run.
class RelocateTest < Minitest::Test
  include ClawTest

  OLD = "/opt/hostedtoolcache/Ruby/9.9.9/arm64"

  def setup
    # The relocators are Python and Perl; a machine without either cannot run these,
    # and a missing interpreter should be a skip rather than a red suite.
    skip "needs python3 or perl" unless ClawTest.which("python3") || ClawTest.which("perl")

    # Short on purpose: the relocator refuses a new prefix longer than the baked-in
    # one (37 bytes here), and TMPDIR on this machine is deep.
    @tmp = "/tmp/clawrel-#{Process.pid}-#{rand(1000)}"
    FileUtils.mkdir_p(@tmp)
    @new = File.join(@tmp, "ruby")
    @tree = File.join(@tmp, "tree")
    FileUtils.mkdir_p(File.join(@tree, "bin"))
    FileUtils.mkdir_p(File.join(@tree, "lib/ruby/9.9.0"))

    # an "ELF" whose payload looks like Ruby's: a RUNPATH string, then a
    # NUL-separated load-path list terminated by an empty entry, then slack.
    list = ["#{OLD}/lib/ruby/9.9.0", "#{OLD}/lib/ruby/9.9.0/arm64-linux"].join("\0") + "\0\0"
    body = "\x7fELF".b + ("\0" * 40) + "#{OLD}/lib".b + "\0".b + list.b + ("\0" * 60)
    File.binwrite(File.join(@tree, "bin/ruby"), body)
    @elf_size = body.bytesize

    File.write(File.join(@tree, "bin/gem"), "#!/#{OLD}/bin/ruby\nputs :hi\n")
    File.write(File.join(@tree, "lib/ruby/9.9.0/x.rb"), "PREFIX = '#{OLD}/lib'\n")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def relocate(script)
    cmd = script.end_with?(".py") ? ["python3", script, @new, @tree] : ["perl", script, @new, @tree]
    out, st = Open3.capture2e(*cmd)
    [out, st]
  end

  def assert_relocated(marker)
    elf = File.binread(File.join(@tree, "bin/ruby"))
    assert_equal @elf_size, elf.bytesize, "#{marker}: size must not change or every offset breaks"
    refute_includes elf, OLD, "#{marker}: no stale prefix left in the binary"

    # the list: entries now start with the new prefix, contiguous, empty entry last
    list_start = elf.index("#{@new}/lib/ruby/9.9.0\0")
    refute_nil list_start, "#{marker}: list should be rewritten"
    after = elf[list_start..]
    expect = ["#{@new}/lib/ruby/9.9.0", "#{@new}/lib/ruby/9.9.0/arm64-linux", "", ""].join("\0")
    assert_equal expect, after[0, expect.bytesize], "#{marker}: list must be repacked, terminator last"

    gem = File.read(File.join(@tree, "bin/gem"))
    assert_match(%r{^#!/#{Regexp.escape(@new)}/bin/ruby}, gem, "#{marker}: shebang")
    assert_match(/#{Regexp.escape(@new)}\/lib/, File.read(File.join(@tree, "lib/ruby/9.9.0/x.rb")),
                 "#{marker}: text files")
  end

  def test_python_relocator_rewrites_the_prefix_in_place
    out, st = relocate(File.join(TEST_ROOT, "scripts/relocate_ruby.py"))
    assert st.success?, out
    assert_match(/patched 1 binaries/, out)
    assert_relocated("python")
  end

  def test_perl_relocator_agrees_with_the_python_one
    out, st = relocate(File.join(TEST_ROOT, "scripts/relocate_ruby.pl"))
    assert st.success?, out
    assert_match(/patched 1 binaries/, out)
    assert_relocated("perl")
  end

  def test_a_too_long_prefix_is_refused_rather_than_truncating_paths
    long = File.join(@tmp, "a" * 60)
    out, st = Open3.capture2e("python3", File.join(TEST_ROOT, "scripts/relocate_ruby.py"), long, @tree)
    refute st.success?
    assert_match(/must be <= #{OLD.bytesize} bytes/, out)
  end

  def test_a_tree_with_no_baked_prefix_is_left_alone
    FileUtils.rm_rf(@tree)
    FileUtils.mkdir_p(File.join(@tree, "bin"))
    File.write(File.join(@tree, "bin/ruby"), "#!/usr/bin/env ruby\n")
    out, st = Open3.capture2e("python3", File.join(TEST_ROOT, "scripts/relocate_ruby.py"), @new, @tree)
    assert st.success?, out
    assert_match(/nothing to relocate/, out)
  end
end
