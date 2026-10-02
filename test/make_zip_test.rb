# frozen_string_literal: true
require_relative "test_helper"

# The release packer writes a zip by hand, out of Zlib alone — no gem, no `zip`
# binary, no second language in the toolchain. That is only respectable if the
# thing it produces is a real zip, so these tests pack the tree and then check
# the archive against the file list of the commit it claims to hold, read it
# back through the packer's own reader, and confirm the mode bits survived: a
# zip that drops them ships a ./rubyclaw that cannot be run.
class MakeZipTest < Minitest::Test
  include ClawTest

  PACKER = File.join(TEST_ROOT, "scripts", "make_zip.rb")

  def pack(out)
    Open3.capture3(RbConfig.ruby, PACKER, out)
  end

  def entries(out)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, PACKER, "--list", out)
    assert status.success?, "--list failed on #{out}: #{stderr}"
    stdout.lines.drop(1).map(&:strip).reject(&:empty?)
          .map { |line| line.split(" ", 2) }        # [mode, name]
  end

  # A checkout knows its file list; an exported release does not, because there is
  # no .git in it -- and the release gate runs this suite inside exactly that
  # export. So ask git when it is there, and fall back to the tree itself when it
  # is not. The packer has the same fallback, and this is the only test of it.
  def checkout?
    system("git", "-C", TEST_ROOT, "rev-parse", "--git-dir", out: File::NULL, err: File::NULL)
  end

  def tracked
    if checkout?
      out = `git -C #{TEST_ROOT} ls-files`
      assert $?.success?, "git ls-files failed in #{TEST_ROOT}"
      out.split("\n").reject(&:empty?).sort
    else
      Dir.chdir(TEST_ROOT) { Dir.glob("**/*", File::FNM_DOTMATCH) }
         .select { |p| File.file?(p) }
         .reject { |p| p.start_with?(".git/", "data/", ".staging/") }
         .sort
    end
  end

  def test_the_archive_holds_exactly_the_tracked_files_of_the_commit
    Dir.mktmpdir do |dir|
      out = File.join(dir, "packed.zip")
      _stdout, stderr, status = pack(out)
      assert status.success?, "packer failed: #{stderr}"
      assert File.file?(out), "no archive written to #{out}"
      assert_equal "PK\x03\x04".b, File.binread(out, 4), "not a zip: no local header"

      listed = entries(out).map { |_mode, name| name.split("/", 2).last }.sort
      if checkout?
        # A checkout has an authority to compare against: the commit itself.
        assert_equal tracked, listed
      else
        # An export has no commit to compare against, and this suite writes
        # runtime state into the very tree we are packing while we run, so the
        # test asserts what must be present and what must never be -- not the
        # tree's contents at this instant, which are a moving target.
        %w[rubyclaw lib/boot.rb test/all.rb README.md].each do |essential|
          assert_includes listed, essential, "#{essential} must ship"
        end
      end
      %w[memory.md preferences.md config.yml].each do |state|
        refute_includes listed, state, "instance state must not ship"
      end
      %w[.git/ data/ log/ .staging/].each do |dir|
        refute(listed.any? { |n| n.start_with?(dir) }, "#{dir} must not ship")
      end
    end
  end

  def test_the_executable_bit_survives_the_round_trip
    Dir.mktmpdir do |dir|
      out = File.join(dir, "packed.zip")
      _stdout, stderr, status = pack(out)
      assert status.success?, "packer failed: #{stderr}"
      modes = entries(out).to_h { |mode, name| [name.split("/", 2).last, mode.to_i(8)] }
      if checkout?
        # Modes come from git (100755/100644), not from the disk, so a umask on
        # the building machine cannot change the release.
        assert_equal 0o755, modes["rubyclaw"] & 0o777, "./rubyclaw must still be executable"
        assert_equal 0o644, modes["README.md"] & 0o777, "a plain file must not become executable"
      else
        # No git to ask, so assert only the property that matters.
        assert_equal 0o111, modes["rubyclaw"] & 0o111, "./rubyclaw must stay executable"
        assert_equal 0, modes["README.md"] & 0o111, "a plain file must not become executable"
      end
    end
  end

  def test_it_refuses_to_pack_a_tree_that_is_not_there
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, PACKER, "/nonexistent/dir/out.zip")
    refute status.success?, "writing into a missing directory should fail loudly"
    assert_match(/make_zip:/, stderr + stdout)
  end
end
