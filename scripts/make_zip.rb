#!/usr/bin/env ruby
# frozen_string_literal: true

# Package RubyClaw as a zip, using nothing but the standard library.
#
#     ruby scripts/make_zip.rb [output.zip]     # defaults to ../RubyClaw<version>.zip
#     ruby scripts/make_zip.rb --list some.zip  # read a zip back and print its entries
#
# WHY THIS IS RUBY
#
#   The first version of this file was Python, and a Ruby project whose release
#   tooling is Python is not honest about itself. The only thing Python's zipfile
#   gave us was a zip writer, and Ruby's standard library already has the two
#   pieces one needs -- Zlib::Deflate with negative window bits writes a raw
#   deflate stream, and Zlib.crc32 writes the checksum. So this is a real zip
#   writer in about a hundred lines, with no gems, no shelling out to `zip`, and
#   no second language in the toolchain.
#
# WHAT SHIPS
#
#   Exactly the files tracked in the current commit, read from `git ls-files`.
#   That is a deliberate change from walking the working directory, which shipped
#   whatever happened to be lying around on the author's machine: a .git
#   directory with its reflogs, this instance's log/ files, and a config.yml
#   holding one machine's endpoint. The archive is the release, and the release
#   is the commit.
#
#   data/ and .env are not tracked, so they cannot ship. The tree is scanned for
#   key-shaped strings and the build aborts rather than shipping a secret.
#
# Exits non-zero on any problem, so it is safe to use in a release step.

require "zlib"
require "fileutils"

ROOT   = File.expand_path("..", __dir__)
NAME   = "RubyClaw"                       # top-level directory inside the zip
STORE  = false                            # deflate everything, as before

# Shapes that must never leave this machine. Deliberately narrow: a documentation
# `sk-...` placeholder must not trip it, a real key must.
SECRETS = [
  ["a provider key", /sk-[A-Za-z0-9]{24,}/],
  ["a Telegram token", /\b\d{8,10}:[A-Za-z0-9_-]{30,}\b/]
].freeze

def die(msg)
  warn "make_zip: #{msg}"
  exit 1
end

def version
  path = File.join(ROOT, "VERSION")
  File.exist?(path) ? File.read(path).strip : "0.0"
end

# The tracked files of this commit, or a directory listing if this is not a
# checkout (an extracted archive is not one; the launcher makes it a repo).
def source_files
  # No shell: an argv list cannot be mangled by whatever the path contains.
  if system("git", "-C", ROOT, "rev-parse", "--git-dir",
            out: File::NULL, err: File::NULL)
    out = IO.popen(["git", "-C", ROOT, "ls-files", "-z"], &:read)
    die("git ls-files failed") unless $?.success?
    list = out.split("\0").reject(&:empty?).sort
    stamp = IO.popen(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], &:read).strip
    # Modes come from git, not from the disk: a umask on the machine that builds
    # the release must not be able to change what the release contains. Only the
    # executable bit is tracked, and that is the only one this needs.
    modes = {}
    IO.popen(["git", "-C", ROOT, "ls-files", "-s", "-z"], &:read)
      .split("\0").reject(&:empty?).each do |line|
      meta, path = line.split("\t", 2)
      modes[path] = meta.split(" ", 2).first.to_i(8) if path
    end
    [list, stamp, modes]
  else
    list = Dir.chdir(ROOT) { Dir.glob("**/*", File::FNM_DOTMATCH) }
               .select { |p| File.file?(p) }
               .reject { |p| p.start_with?(".git/", "data/", ".staging/", "log/") }
               .reject { |p| %w[memory.md preferences.md config.yml].include?(p) }
               .sort
    [list, "(no checkout)", {}]
  end
end

def scan(path, rel)
  blob = File.binread(path)
  SECRETS.each do |label, pattern|
    blob.scan(pattern) { die("refusing to build: #{rel} looks like it contains #{label}") }
  end
end

def dos_time(time)
  [(time.hour << 11) | (time.min << 5) | (time.sec / 2),
   ((time.year - 1980) << 9) | (time.month << 5) | time.day]
end

# A raw deflate stream: negative window bits mean "no zlib header, no checksum",
# which is exactly what a zip entry holds.
def deflate(data)
  z = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS)
  out = z.deflate(data, Zlib::FINISH)
  z.close
  out
end

def pack(out, files, modes, stamp)
  local = +""
  central = +""
  offsets = []
  files.each do |rel|
    path = File.join(ROOT, rel)
    die("tracked file missing from the working tree: #{rel}") unless File.file?(path)
    scan(path, rel)
    data = File.binread(path)
    comp = deflate(data)
    crc  = Zlib.crc32(data)
    name = "#{NAME}#{version}/#{rel}".b
    mtime = File.mtime(path)
    time, date = dos_time(mtime)
    # git's 100644/100755 already carry the file-type bits a zip wants here.
    mode = modes[rel] || (File.stat(path).mode & 0xFFFF)
    offsets << local.bytesize

    local << [0x04034b50, 20, 0, 8, time, date, crc, comp.bytesize, data.bytesize,
              name.bytesize, 0].pack("VvvvvvVVVvv") << name << comp

    central << [0x02014b50, 0x0314, 20, 0, 8, time, date, crc, comp.bytesize,
                data.bytesize, name.bytesize, 0, 0, 0, 0, mode << 16,
                offsets.last].pack("VvvvvvvVVVvvvvvVV") << name
  end

  eocd = [0x06054b50, 0, 0, files.size, files.size, central.bytesize,
          local.bytesize, 0].pack("VvvvvVVv")
  begin
    File.binwrite(out, local + central + eocd)
  rescue SystemCallError => e
    die("cannot write #{out}: #{e.message}")
  end
  [files.size, stamp]
end

# Read the central directory back: the cheap way to prove the file we just wrote
# is a zip rather than merely a file with the right extension.
def list_zip(path)
  die("no such file: #{path}") unless File.file?(path)
  blob = File.binread(path)
  eocd = blob.rindex([0x06054b50].pack("V"))
  die("#{path} has no end-of-central-directory record: not a zip") unless eocd
  # after the 4-byte signature: disk, cd_disk, entries_here, entries_total,
  # cd_size, cd_offset, comment_len
  _disk, _cd_disk, _here, count, cd_size, cd_off, _clen =
    blob[eocd + 4, 18].unpack("vvvvVVv")
  entries = []
  pos = cd_off
  count.times do
    sig, _vm, _vn, _fl, _meth, _t, _d, _crc, _cs, _us, nlen, elen, clen, _dn,
      _ia, _ea, _lho = blob[pos, 46].unpack("VvvvvvvVVVvvvvvVV")
    die("bad central directory record at #{pos}") unless sig == 0x02014b50
    mode = _ea >> 16                          # high word holds the unix mode
    entries << [mode, blob[pos + 46, nlen].force_encoding("UTF-8")]
    pos += 46 + nlen + elen + clen
  end
  [entries, count, cd_size, cd_off]
end

# --- main -------------------------------------------------------------------

if ARGV.first == "--list"
  path = ARGV[1] or die("usage: make_zip.rb --list <file.zip>")
  entries, count, = list_zip(path)
  puts "#{path}: #{count} entries"
  # mode then name, name last: the executable bit is part of the promise, so the
  # reader reports it and the test asserts on it.
  entries.each { |mode, name| puts "  #{format("%o", mode)} #{name}" }
  exit 0
end

ver = version
out = ARGV[0] || File.join(File.dirname(ROOT), "#{NAME}#{ver}.zip")
begin
  FileUtils.mkdir_p(File.dirname(out))
rescue SystemCallError => e
  die("cannot write to #{File.dirname(out)}: #{e.message}")
end
files, stamp, modes = source_files
dirty = IO.popen(["git", "-C", ROOT, "status", "--porcelain"], &:read).to_s.strip
warn "make_zip: the working tree has uncommitted changes; the archive holds the " \
     "committed modes but reads file contents from disk — commit before releasing" unless dirty.empty?
die("nothing to pack") if files.empty?

n, = pack(out, files, modes, stamp)
# Prove it by reading it back before reporting success.
entries, count, = list_zip(out)
die("wrote #{out} but read back #{count} entries, expected #{n}") unless count == n
names = entries.map(&:last).sort
die("entry name mismatch") unless names == files.map { |f| "#{NAME}#{ver}/#{f}" }.sort

kb = File.size(out) / 1024.0
puts "#{out}: #{n} files, #{kb.round} KB, version #{ver}, from commit #{stamp}"
puts "ships exactly the tracked files; data/, .env and .git are not tracked and cannot ship"
