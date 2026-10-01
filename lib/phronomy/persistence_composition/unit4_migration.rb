# frozen_string_literal: true

require "digest"

module Phronomy
  module PersistenceComposition
    # Explicit offline conversion of a quiescent snapshot into an unpublished
    # destination. Runtime codecs never call this converter.
    # @api public
    class Unit4Migration
      def self.convert(snapshot, quiescent:)
        raise ArgumentError, "stop every writer before migration" unless quiescent == true
        new(snapshot).convert
      end

      def initialize(snapshot)
        @snapshot = Phronomy::CanonicalJSON.load(Phronomy::CanonicalJSON.dump(snapshot))
        unless @snapshot.fetch("format") == "phronomy.snapshot/1" && @snapshot.fetch("revision") == "r8-unit3"
          raise ArgumentError, "expected an r8-unit3 phronomy.snapshot/1 export"
        end
        @resources = @snapshot.fetch("resources")
        @roots = index("agent.roots")
        @executions = index("agent.executions")
        @routing = index("handoff.states")
        @blobs = index("content.blobs")
        @holds, @cancellations = {}, {}
      end

      def convert
        validate_source!
        @executions.each_value { |entry| migrate_execution(entry) }
        @routing.each_value { |entry| migrate_routing(entry) }
        @resources["agent.retentions"] = {"kind" => "records", "entries" => @holds.values.sort_by { |entry| entry.fetch("key") }}
        @resources["agent.cancellations"] = {"kind" => "records", "entries" => @cancellations.values.sort_by { |entry| entry.fetch("key") }}
        @resources.fetch("content.blobs")["entries"] = @blobs.values.sort_by { |entry| entry.fetch("key") }
        @snapshot["revision"] = "r8-unit4"
        @snapshot["migration"] = {"source" => "r8-unit3", "logical_revisions" => "preserved", "physical_revisions" => "preserved"}
        @snapshot["migration"]["resources_sha256"] = Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(@resources))
        @snapshot
      rescue KeyError, ArgumentError, Phronomy::Storage::SerializationError => error
        raise Phronomy::Persistence::SerializationError, "Unit 4 migration aborted: #{error.message}"
      end

      private

      def index(id)
        entries = @resources.fetch(id).fetch("entries")
        result = entries.to_h { |entry| [entry.fetch("key"), entry] }
        raise ArgumentError, "duplicate identity in #{id}" unless result.size == entries.size
        result
      end

      def validate_source!
        expected = StorageSchema.resources.map(&:id) - %w[agent.retentions agent.cancellations]
        raise ArgumentError, "source resource set differs from unit 3" unless @resources.keys.sort == expected.sort
        @blobs.each do |key, entry|
          bytes = [entry.fetch("hex")].pack("H*")
          unless entry.fetch("hex").match?(/\A(?:[0-9a-f]{2})*\z/) && "sha256:#{Digest::SHA256.hexdigest(bytes)}" == key
            raise ArgumentError, "content digest mismatch: #{key}"
          end
        end
        @blobs.each_value do |entry|
          bytes = [entry.fetch("hex")].pack("H*")
          next unless bytes.lstrip.start_with?("{", "[")
          begin
            value = Phronomy::CanonicalJSON.load(bytes)
          rescue Phronomy::Persistence::SerializationError, Phronomy::Storage::SerializationError, JSON::ParserError
            next # Arbitrary text blobs are allowed.
          end
          validate_references!(value)
        end
        @roots.each do |id, entry|
          root = Phronomy::Agent::Persistence::Codec.decode_agent_root(record(entry))
          unless root.agent_id == id && root.agent_revision == entry.fetch("revision")
            raise ArgumentError, "Agent root identity/revision mismatch: #{id}"
          end
        end
        validate_references!(@resources)
        validate_journal!
        @executions.each do |id, entry|
          envelope = entry.fetch("record")
          unless envelope.fetch("record_type") == "phronomy.agent_execution" && envelope.fetch("format_version") == "0.1"
            raise ArgumentError, "unsupported source execution format: #{id}"
          end
          body = envelope.fetch("payload")
          Phronomy::Agent::Persistence::Codec.validate_agent_execution_payload!(body)
          unless body.fetch("execution_id") == id && body.fetch("execution_revision") == entry.fetch("revision") && @roots.key?(body.fetch("agent_id"))
            raise ArgumentError, "execution identity/revision/owner mismatch: #{id}"
          end
          attributes = {"owner" => body.fetch("agent_id"), "active" => %w[preparing active suspended].include?(body.fetch("status"))}
          raise ArgumentError, "execution attributes mismatch: #{id}" unless entry.fetch("attributes") == attributes
          [body["result_ref"], body["error_ref"], *body.fetch("working_records").map { |item| item["content_ref"] }].compact.each { |ref| fetch_bytes(ref) }
        end
      end

      def validate_references!(value)
        case value
        when Hash
          value.each do |key, child|
            if key.end_with?("_ref") && child.is_a?(String)
              fetch_bytes(child)
            elsif key.end_with?("_refs") && child.is_a?(Array)
              child.each { |ref| fetch_bytes(ref) if ref.is_a?(String) }
            end
            validate_references!(child)
          end
        when Array then value.each { |child| validate_references!(child) }
        end
      end

      def validate_journal!
        source = @resources.fetch("agent.journal")
        groups = source.fetch("entries").group_by { |entry| entry.fetch("stream") }
        heads = source.fetch("heads")
        raise ArgumentError, "journal has unknown owner" unless ((groups.keys + heads.keys).uniq - @roots.keys).empty?
        @roots.each do |id, root|
          position = root.fetch("record").fetch("payload").fetch("journal_position")
          rows = groups.fetch(id, []).sort_by { |entry| entry.fetch("position") }
          unless heads.fetch(id, 0) == position && rows.map { |entry| entry.fetch("position") } == (1..position).to_a
            raise ArgumentError, "journal position mismatch: #{id}"
          end
          raise ArgumentError, "duplicate journal identity: #{id}" unless rows.map { |entry| entry.fetch("id") }.uniq.size == rows.size
          rows.each do |entry|
            value = Phronomy::Agent::Persistence::Codec.decode_journal_record(record(entry))
            unless value.agent_id == id && value.sequence == entry.fetch("position") && value.record_id == entry.fetch("id")
              raise ArgumentError, "journal entry identity mismatch: #{id}"
            end
            fetch_bytes(value.content_ref) if value.content_ref
          end
        end
      end

      def migrate_execution(entry)
        body = entry.fetch("record").fetch("payload")
        id, owner = body.values_at("execution_id", "agent_id")
        metadata = body.fetch("metadata")
        if (correlation = metadata.delete("coordination"))
          correlation.delete("handoff_revision") if correlation.fetch("kind") == "handoff"
          metadata["reservation"] = correlation
          if correlation.fetch("kind") == "handoff"
            main = correlation.fetch("main_agent_id")
            raise ArgumentError, "missing Handoff anchor for #{id}" unless @routing.key?(main)
            metadata["execution_extension"] = binding("phronomy.handoff")
            retain(owner, id, "handoff:#{main}")
          end
        end
        cancelled = metadata.delete("coordination_cancel_requested") == true
        if cancelled
          metadata["cancellation_requested"] = true
          @cancellations[id] = record_entry(id, 0, {"owner" => owner}, "phronomy.agent_cancellation", "0.1",
            {"agent_id" => owner, "execution_id" => id})
        end
        if (ref = metadata.delete("multi_agent_coordination_ref"))
          migrate_children(body, fetch_json(ref), cancelled)
        end
        if (target = metadata.delete("handoff_target_agent_id"))
          target_execution = metadata.delete("handoff_target_execution_id") || raise(ArgumentError, "missing transfer execution: #{id}")
          ref = metadata.delete("handoff_context_ref") || raise(ArgumentError, "missing transfer context: #{id}")
          raise ArgumentError, "transfer receipt on unfinished Source: #{id}" unless body.fetch("status") == "handed_off"
          Phronomy::Agent::TransferContext.from_h(fetch_json(ref))
          main = metadata.fetch("reservation").fetch("main_agent_id")
          metadata["transfer_receipt"] = {"target_agent_id" => target, "target_execution_id" => target_execution,
                                         "context_ref" => ref, "owner_key" => "handoff:#{main}"}
          retain(target, target_execution, "handoff:#{main}")
        end
        entry.fetch("record")["format_version"] = "0.2"
        Phronomy::Agent::Persistence::Codec.validate_agent_execution_payload!(body)
      end

      def migrate_children(body, snapshot, cancelled)
        id = body.fetch("execution_id")
        metadata = body.fetch("metadata")
        children = snapshot.fetch("children").map do |child|
          child_agent, child_execution = child.values_at("agent_id", "execution_id")
          existing = @executions[child_execution]&.fetch("record")&.fetch("payload")
          raise ArgumentError, "subagent owner mismatch: #{child_execution}" if existing && existing.fetch("agent_id") != child_agent
          retain(child_agent, child_execution, "subagent:#{id}") if @roots.key?(child_agent)
          unless existing || child.fetch("state") == "reserved"
            raise ArgumentError, "accepted child execution is missing: #{child_execution}"
          end
          if @roots.key?(child_agent)
            root = @roots.fetch(child_agent).fetch("record").fetch("payload")
            unless child.fetch("definition") == {"id" => root.fetch("agent_definition_id"), "version" => root.fetch("agent_definition_version")}
              raise ArgumentError, "child definition mismatch: #{child_agent}"
            end
          end
          raise ArgumentError, "unknown child error policy" unless %w[raise skip].include?(child.fetch("on_error"))
          knowledge = fetch_json(child.fetch("knowledge_ref"))
          knowledge.each { |item| Phronomy::Agent::KnowledgeItem.new(content: item.fetch("content"), metadata: item.fetch("metadata")) }
          calls = Array(metadata[Phronomy::Agent::ExecutionMetadata::TOOL_BATCH_METADATA_KEY])
          call = calls.find { |item| item.fetch("tool_invocation_id") == child.fetch("slot") }
          imported = call ? %w[completed failed cancelled rejected].include?(call.fetch("status")) : body.fetch("phase") != "dispatching_tools"
          {"slot" => child.fetch("slot"), "name" => child.fetch("name"), "definition" => child.fetch("definition"),
           "agent_id" => child_agent, "execution_id" => child_execution,
           "input" => fetch_bytes(child.fetch("input_ref")).force_encoding(Encoding::UTF_8),
           "durable_context" => child["durable_context_ref"] && fetch_json(child.fetch("durable_context_ref")),
           "knowledge" => knowledge, "on_error" => child.fetch("on_error"), "imported" => imported}
        end
        raise ArgumentError, "duplicate child slot: #{id}" unless children.map { |child| child.fetch("slot") }.uniq.size == children.size
        ref = put_json("children" => children, "cancel_requested" => cancelled)
        metadata["execution_extension"] = binding("phronomy.subagent", ref)
        retain(body.fetch("agent_id"), id, "subagent:#{id}") unless children.empty?
      end

      def migrate_routing(entry)
        envelope = entry.fetch("record")
        unless envelope.fetch("record_type") == "phronomy.handoff_state" && envelope.fetch("format_version") == "0.1"
          raise ArgumentError, "unsupported source Handoff routing format"
        end
        envelope["format_version"] = "0.2"
        state = Phronomy::MultiAgent::Persistence::Codec.decode_handoff_state(record(entry))
        unless entry.fetch("key") == state.main_agent_id && entry.fetch("revision") == state.handoff_revision
          raise ArgumentError, "Handoff routing identity/revision mismatch"
        end
        main = state.main_agent_id
        ids = [main, state.active_agent_id]
        @executions.each_value do |execution|
          body = execution.fetch("record").fetch("payload")
          next unless body.dig("metadata", "reservation", "main_agent_id") == main
          ids << body.fetch("agent_id")
          receipt = body.dig("metadata", "transfer_receipt")
          ids << receipt.fetch("target_agent_id") if receipt
        end
        ids = ids.uniq.sort
        ids.each { |id| retain(id, nil, "handoff:#{main}") }
        Phronomy::Agent::TransferContext.from_h(fetch_json(state.active_handoff_context_ref)) if state.active_handoff_context_ref
        body = entry.fetch("record").fetch("payload")
        body.fetch("metadata")["retained_agent_ids"] = ids
        Array(state.metadata["cancelled_execution_ids"]).each do |execution_id|
          cancelled = @executions[execution_id]&.fetch("record")&.fetch("payload")
          next unless cancelled # A cancelled reservation can precede acceptance.
          unless cancelled.dig("metadata", "reservation", "main_agent_id") == main
            raise ArgumentError, "Handoff cancellation points outside its conversation: #{execution_id}"
          end
          @cancellations[execution_id] = record_entry(execution_id, 0, {"owner" => cancelled.fetch("agent_id")},
            "phronomy.agent_cancellation", "0.1", {"agent_id" => cancelled.fetch("agent_id"), "execution_id" => execution_id})
        end
        if state.pending_source_execution_id
          source = @executions.fetch(state.pending_source_execution_id).fetch("record").fetch("payload")
          receipt = source.fetch("metadata").fetch("transfer_receipt")
          unless receipt.fetch("target_execution_id") == state.pending_target_execution_id && receipt.fetch("target_agent_id") == state.active_agent_id && receipt.fetch("context_ref") == state.active_handoff_context_ref
            raise ArgumentError, "Handoff pending identities/context do not match the Source receipt"
          end
          body.fetch("metadata")["source_agent_id"] = source.fetch("agent_id")
        end
      end

      def binding(key, ref = nil)
        {"binding_key" => key, "binding_version" => 1, "state_ref" => ref}
      end

      def retain(agent_id, execution_id, owner_key)
        raise ArgumentError, "retained Agent is missing: #{agent_id}" unless @roots.key?(agent_id)
        value = Phronomy::Agent::Retention.new(agent_id: agent_id, execution_id: execution_id, owner_key: owner_key)
        key = Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(value.to_h))
        @holds[key] = record_entry(key, 0, {"owner" => agent_id, "holder" => owner_key}, "phronomy.agent_retention", "0.1", value.to_h)
      end

      def record_entry(key, revision, attributes, type, version, payload)
        {"key" => key, "revision" => revision, "attributes" => attributes,
         "record" => {"record_type" => type, "format_version" => version, "payload" => payload}}
      end

      def record(entry) = Phronomy::Storage::DurableRecord.new(**entry.fetch("record").transform_keys(&:to_sym))
      def fetch_bytes(ref) = [@blobs.fetch(ref).fetch("hex")].pack("H*")
      def fetch_json(ref) = Phronomy::CanonicalJSON.load(fetch_bytes(ref))

      def put_json(value)
        bytes = Phronomy::CanonicalJSON.dump(value)
        key = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
        @blobs[key] ||= {"key" => key, "hex" => bytes.unpack1("H*"), "attributes" => {"canonicalization_version" => 1}}
        key
      end
    end
  end
end
