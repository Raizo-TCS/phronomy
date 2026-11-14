# frozen_string_literal: true

require "json"
require "phronomy"

module SharedStateCustomSharingExample
  class IssueBoard
    attr_reader :closed

    def initialize
      @records = []
      @closed = false
    end

    def record(content:, category:, status:, author:, cycle:)
      raise "Issue board is closed" if closed

      row = {id: @records.length + 1, content: content.dup.freeze,
             category: category.dup.freeze, status: status.dup.freeze,
             author: author.dup.freeze, cycle: cycle}.freeze
      @records << row
      row
    end

    def search(category: nil, status: nil)
      snapshot.select do |row|
        (category.nil? || row.fetch(:category) == category) &&
          (status.nil? || row.fetch(:status) == status)
      end
    end

    def snapshot
      raise "Issue board is closed" if closed

      @records.dup.freeze
    end

    def close
      @records.clear
      @closed = true
    end
  end

  class IssueSharing
    def open(input:, config:)
      board = IssueBoard.new
      yield Phronomy::MultiAgent::SharedState::Binding.new(
        store: board,
        tools: ->(member:, cycle:) { tool_definitions(board, member, cycle) }
      )
    ensure
      board&.close
    end

    private

    def tool_definitions(board, member, cycle)
      {
        record_tool(board, member.agent_definition.fetch(:id), cycle) => nil,
        search_tool(board) => nil
      }
    end

    def record_tool(board, author, cycle)
      Class.new(Phronomy::Tool::Base) do
        tool_name "record_issue"
        description "Record one issue with an explicit category and status."
        execution_mode :cooperative
        param :content, type: :string, desc: "The issue description."
        param :category, type: :string, enum: %w[security performance],
          desc: "The issue category."
        param :status, type: :string, enum: %w[open closed],
          desc: "The issue status."

        define_method(:execute) do |content:, category:, status:|
          board.record(content: content, category: category, status: status,
            author: author, cycle: cycle).to_json
        end
      end
    end

    def search_tool(board)
      Class.new(Phronomy::Tool::Base) do
        tool_name "search_issues"
        description "Read issues matching all supplied category and status filters."
        execution_mode :cooperative
        param :category, type: :string, required: false, enum: %w[security performance],
          desc: "Optional exact category filter."
        param :status, type: :string, required: false, enum: %w[open closed],
          desc: "Optional exact status filter."

        define_method(:execute) do |category: nil, status: nil|
          board.search(category: category, status: status).to_json
        end
      end
    end
  end

  class Researcher < Phronomy::Agent::Base
    agent_definition id: "shared-issue-researcher", version: 1
    model ENV.fetch("PHRONOMY_EXAMPLE_MODEL", "configured-model")
  end

  class ReviewTeam < Phronomy::MultiAgent::SharedState
    sharing IssueSharing.new, id: "shared-issues", version: 1
    member Researcher
    max_cycles 2
    coordination "Use search_issues to inspect relevant issues. " \
                 "Use record_issue to record each new issue with its category and status."
    aggregate { |board| board.snapshot }
  end

  module OfflineDemo
    def self.run
      opened_board = nil
      output = IssueSharing.new.open(input: "Review authentication", config: {}) do |binding|
        opened_board = binding.store
        definitions = binding.tool_definitions(member: Researcher, cycle: 1)
        tools = definitions.keys.to_h { |tool| [tool.tool_name, tool.new] }
        recorder = tools.fetch("record_issue")
        recorder.call({"content" => "Missing token validation", "category" => "security", "status" => "open"})
        recorder.call({"content" => "Slow cache lookup", "category" => "performance", "status" => "open"})
        recorder.call({"content" => "Session expiry corrected", "category" => "security", "status" => "closed"})

        matches = JSON.parse(tools.fetch("search_issues").call({"category" => "security", "status" => "open"}))
        unless matches.map { |row| row.fetch("content") } == ["Missing token validation"]
          raise "Search did not apply both filters"
        end
        all_records = binding.store.snapshot
        raise "Search changed the board" unless all_records.length == 3

        {matches: matches, total_records: all_records.length}
      end
      raise "Provider did not close the board" unless opened_board.closed

      puts JSON.pretty_generate(output.merge(provider_closed: true))
    end
  end
end

if $PROGRAM_NAME == __FILE__
  abort "Run with --offline, or require this file from a configured Phronomy application." unless ARGV == ["--offline"]

  SharedStateCustomSharingExample::OfflineDemo.run
end
