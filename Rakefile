# frozen_string_literal: true
# rake test          everything
# rake test TEST=test/registry_test.rb    one file
# rake lint          the enforced gate: Lint + Security
# rake lint:metrics  the advisory size report (see REVIEW.md for the open list)
require "rake/testtask"

RUBOCOP = File.expand_path("~/.local/share/gem/ruby/3.4.0/bin/rubocop")

def rubocop(*only)
  unless File.executable?(RUBOCOP)
    warn "rubocop is not installed (gem install --user-install rubocop); skipping"
    return
  end
  sh RUBOCOP, "--no-color", "--only", only.join(","), "-f", "simple"
end

desc "the enforced gate: Lint and Security (must be clean)"
task :lint do
  rubocop("Lint", "Security")
end

desc "advisory size report: Metrics (the open items are listed in REVIEW.md)"
task :"lint:metrics" do
  rubocop("Metrics")
end

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

desc "the entry point's own smoke test (needs no ruby installed anywhere)"
task :smoke do
  sh "./rubyclaw --help >/dev/null && ./rubyclaw selftest"
end

task default: :test

