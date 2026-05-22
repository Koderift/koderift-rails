require 'spec_helper'

RSpec.describe Koderift::Rails::LogrageConfig do
  describe '.format_backtrace' do
    it 'returns nil when exception is nil' do
      expect(described_class.format_backtrace(nil)).to be_nil
    end

    it 'returns nil when exception has no backtrace' do
      exc = StandardError.new('boom')
      # backtrace is nil until the exception is raised
      expect(described_class.format_backtrace(exc)).to be_nil
    end

    it 'returns a newline-joined string of frames' do
      exc = begin
        raise RuntimeError, 'test'
      rescue => e
        e
      end
      result = described_class.format_backtrace(exc)
      expect(result).to be_a(String)
      expect(result).to include('lograge_config_spec.rb')
    end

    it 'caps output at MAX_FRAMES lines' do
      exc = begin
        raise RuntimeError, 'test'
      rescue => e
        e
      end
      # Inject a very long fake backtrace
      exc.set_backtrace(Array.new(200) { |i| "fake/path/file_#{i}.rb:#{i}:in `method'" })
      result = described_class.format_backtrace(exc)
      expect(result.split("\n").size).to be <= Koderift::Rails::LogrageConfig::MAX_FRAMES
    end

    it 'prioritises app frames over gem frames in the tail' do
      exc = begin
        raise RuntimeError, 'test'
      rescue => e
        e
      end
      frames = Array.new(5) { |i| "gems/rack-#{i}.rb:1" } +
               Array.new(5) { |i| "/app/controllers/foo_#{i}.rb:1" } +
               Array.new(100) { |i| "gems/activesupport-#{i}.rb:1" }
      exc.set_backtrace(frames)
      result = described_class.format_backtrace(exc)
      lines = result.split("\n")
      # App frames should appear before the gem flood
      app_indices = lines.each_index.select { |i| lines[i].include?('/app/') }
      expect(app_indices).not_to be_empty
    end
  end
end
