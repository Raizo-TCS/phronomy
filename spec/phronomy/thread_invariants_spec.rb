# frozen_string_literal: true

RSpec.describe "production thread confinement" do
  THREAD_NEW_ALLOWLIST = %w[
    lib/phronomy/engine/event_loop.rb
    lib/phronomy/engine/concurrency/offload_pool.rb
  ].freeze

  it "allows Thread.new only in EventLoop and OffloadPool" do
    lib_root = File.expand_path("../../lib", __dir__)
    project_root = File.expand_path("..", lib_root)
    violations = []

    Dir.glob("#{lib_root}/**/*.rb").each do |abs_path|
      rel_path = abs_path.sub("#{project_root}/", "")
      next if THREAD_NEW_ALLOWLIST.include?(rel_path)
      next if rel_path.start_with?("lib/phronomy/testing/")

      File.foreach(abs_path).each_with_index do |line, index|
        next if line.strip.start_with?("#")
        next unless line.include?("Thread.new")
        violations << "#{rel_path}:#{index + 1}: #{line.strip}"
      end
    end

    expect(violations).to be_empty,
      "Thread.new used outside EventLoop/OffloadPool:\n#{violations.join("\n")}"
  end

  it "contains no production Fiber execution path" do
    lib_root = File.expand_path("../../lib", __dir__)
    project_root = File.expand_path("..", lib_root)
    violations = []

    Dir.glob("#{lib_root}/**/*.rb").each do |abs_path|
      rel_path = abs_path.sub("#{project_root}/", "")
      next if rel_path.start_with?("lib/phronomy/testing/")

      File.foreach(abs_path).each_with_index do |line, index|
        next if line.strip.start_with?("#")
        violations << "#{rel_path}:#{index + 1}: #{line.strip}" if line.match?(/\bFiber(?:\.|::|\b)/)
      end
    end

    expect(violations).to be_empty,
      "Fiber used in production source:\n#{violations.join("\n")}"
  end

  it "contains no production Runtime#spawn or Task.spawn call" do
    lib_root = File.expand_path("../../lib", __dir__)
    project_root = File.expand_path("..", lib_root)
    patterns = [/Runtime(?:\.instance)?\.spawn/, /\bTask\.spawn/]
    violations = []

    Dir.glob("#{lib_root}/**/*.rb").each do |abs_path|
      rel_path = abs_path.sub("#{project_root}/", "")
      next if rel_path.start_with?("lib/phronomy/testing/")

      File.foreach(abs_path).each_with_index do |line, index|
        next if line.strip.start_with?("#")
        next unless patterns.any? { |pattern| line.match?(pattern) }
        violations << "#{rel_path}:#{index + 1}: #{line.strip}"
      end
    end

    expect(violations).to be_empty,
      "spawn API used in production source:\n#{violations.join("\n")}"
  end

  it "runs EventLoop on one dedicated OS thread" do
    runtime = Phronomy::Runtime.new
    event_loop = runtime.event_loop
    thread = event_loop.instance_variable_get(:@thread)

    expect(thread).to be_a(Thread)
    expect(thread.name).to eq("phronomy-event-loop")
    expect(thread).to be_alive
  ensure
    runtime&.shutdown(timeout: 2)
  end
end
