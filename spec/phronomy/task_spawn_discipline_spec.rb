# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Task.spawn discipline guard (Issue #340)
#
# Framework components outside lib/phronomy/runtime/ must NOT call
# Phronomy::Task.spawn directly. All spawning should go through
# Runtime.instance.spawn so that the configured scheduler backend
# (cooperative, thread, fiber) is always honoured.
#
# Permitted direct Task.spawn usage:
#   - lib/phronomy/runtime/**  (scheduler implementations)
#   - lib/phronomy/task.rb     (Task class itself)
#   - Comments / docstrings inside any file
# ---------------------------------------------------------------------------

RSpec.describe "Task.spawn discipline (Issue #340)" do
  TASK_SPAWN_PATTERN = /(?:Phronomy::)?Task\.spawn/

  LIB_ROOT = File.expand_path("../../lib/phronomy", __dir__)
  EXEMPT_PATHS = [
    File.join(LIB_ROOT, "runtime"),
    File.join(LIB_ROOT, "task.rb")
  ].freeze

  # Collect all .rb files under lib/phronomy/ that are not exempt.
  SUBJECT_FILES = Dir.glob(File.join(LIB_ROOT, "**", "*.rb")).reject do |path|
    EXEMPT_PATHS.any? { |exempt| path.start_with?(exempt) }
  end.sort.freeze

  it "has framework source files to check" do
    expect(SUBJECT_FILES).not_to be_empty
  end

  SUBJECT_FILES.each do |path|
    it "does not call Task.spawn directly in #{path.sub(LIB_ROOT + "/", "")}" do
      # Strip comment-only lines before matching so doc examples are ignored.
      code_lines = File.readlines(path).reject { |l| l.strip.start_with?("#") }.join
      violations = code_lines.scan(/(?:Phronomy::)?Task\.spawn/).uniq
      expect(violations).to be_empty,
        "#{path} calls Task.spawn directly (found: #{violations.inspect}). " \
        "Use Runtime.instance.spawn instead (Issue #340)."
    end
  end
end
