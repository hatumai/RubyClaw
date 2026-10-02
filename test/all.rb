# frozen_string_literal: true
# `ruby -Ilib -Itest test/all.rb` — the same suite as `rake test`, without rake.
Dir[File.join(__dir__, "*_test.rb")].sort.each { |f| require f }
