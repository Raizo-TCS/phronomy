# frozen_string_literal: true

require "spec_helper"
require "ripper"

RSpec.describe "CG-03b FSMSession incarnation identity and routing foundation" do
  let(:root) { File.expand_path("../..", __dir__) }

  def constant_path_name(node)
    return unless node.is_a?(Array)

    case node[0]
    when :var_ref
      token = node[1]
      (token[0] == :@const) ? token[1] : nil
    when :const_path_ref
      left = constant_path_name(node[1])
      right = node[2]
      return unless left && right&.first == :@const

      "#{left}::#{right[1]}"
    when :top_const_ref
      token = node[1]
      (token[0] == :@const) ? "::#{token[1]}" : nil
    end
  end

  def direct_keyword_names(arguments)
    return [] unless arguments.is_a?(Array)

    node = arguments
    node = node[1] if node[0] == :arg_paren
    return [] unless node.is_a?(Array) && node[0] == :args_add_block

    Array(node[1]).flat_map do |argument|
      next [] unless argument.is_a?(Array) && argument[0] == :bare_assoc_hash

      Array(argument[1]).filter_map do |association|
        next unless association.is_a?(Array) && association[0] == :assoc_new

        key = association[1]
        key[1].delete_suffix(":").to_sym if key&.first == :@label
      end
    end
  end

  def fsm_session_constructor_keyword_names(source)
    syntax = Ripper.sexp(source)
    raise "source is not valid Ruby" unless syntax

    names = []
    visit = lambda do |node|
      return unless node.is_a?(Array)

      if node[0] == :method_add_arg
        call = node[1]
        if call.is_a?(Array) &&
            call[0] == :call &&
            call[3]&.first == :@ident &&
            call[3][1] == "new" &&
            %w[FSMSession Phronomy::FSMSession].include?(
              constant_path_name(call[1])
            )
          names.concat(direct_keyword_names(node[2]))
        end
      end

      node.each do |child|
        visit.call(child) if child.is_a?(Array)
      end
    end

    visit.call(syntax)
    names
  end

  it "removes raw caller-supplied FSMSession id while retaining private reservation support" do
    keys = Phronomy::FSMSession.instance_method(:initialize).parameters.map(&:last)
    expect(keys).not_to include(:id, :graph_thread_id)
    expect(keys).to include(:context_metadata, :event_sink, :identity_reservation, :terminal_barrier)
  end

  it "keeps each reserved Runtime identity single-use" do
    reservation = Phronomy::FSMSession.reserve_identity
    expect(reservation.fsm_session_id).to match(/\A[0-9a-f-]{36}\z/)
    expect(reservation.send(:claim!)).to eq(reservation.fsm_session_id)
    expect { reservation.send(:claim!) }
      .to raise_error(Phronomy::Error, /already claimed/)
  end

  it "keeps AgentInvocation free of an independent routing identity" do
    methods = Phronomy::Agent::AgentInvocation.public_instance_methods(false)
    expect(methods).not_to include(:id, :session_id, :thread_id, :agent_invocation_id)
  end

  it "keeps ToolInvocation lifecycle identity but no parent/session route" do
    methods = Phronomy::Agent::ToolInvocation.public_instance_methods(false)
    expect(methods).to include(:id, :execution_id, :tool_call_id)
    expect(methods).not_to include(:parent_agent_invocation_id, :session_id)
  end

  it "does not inject Agent, Tool, or FanOut domain IDs into FSMSession constructors" do
    %w[
      lib/phronomy/agent/agent_invocation_session_builder.rb
      lib/phronomy/agent/tool_invocation_session_builder.rb
      lib/phronomy/multi_agent/fan_out_session_builder.rb
    ].each do |relative|
      source = File.read(File.join(root, relative))
      expect(fsm_session_constructor_keyword_names(source)).not_to include(:id)
    end
  end

  it "keeps Workflow admission ownership separate from concrete FSMSession routing" do
    runner = File.read(File.join(root, "lib/phronomy/workflow_runner.rb"))
    event_loop = File.read(File.join(root, "lib/phronomy/engine/event_loop.rb"))

    expect(runner).not_to include("Phronomy::FSMSession.reserve_identity")
    expect(runner).not_to include("owner_fsm_session_id")
    expect(runner).to include("owner_token: Object.new.freeze")
    expect(runner).to include("bind_workflow_session")
    expect(event_loop).to include("WorkflowAdmission = Data.define")
    expect(event_loop).to include(":owner_token, :fsm_session_id, :state")
    expect(event_loop).to include("current.owner_token.equal?(owner_token)")
    expect(runner).not_to include("graph_thread_id:")
  end

  it "uses fsm_session_id for terminal Runtime payloads" do
    source = File.read(File.join(root, "lib/phronomy/engine/fsm_session.rb"))
    expect(source).to include("payload: {fsm_session_id: @id, result: result}")
    expect(source).not_to include("payload: {session_id: @id")
  end

  it "uses session-local sinks instead of long-lived Tool parent routing fields" do
    tool = File.read(File.join(root, "lib/phronomy/agent/tool_invocation.rb"))
    builder = File.read(
      File.join(root, "lib/phronomy/agent/tool_invocation_session_builder.rb")
    )
    expect(tool).not_to include("parent_agent_invocation_id")
    expect(builder).to include("parent_event_sink")
    expect(builder).not_to include("parent_fsm_session_id")
  end

  it "never rebinds an old session sink to a new Runtime incarnation" do
    runtime = Phronomy::Runtime.new
    sink = Phronomy::FSMSession::EventSink.new(event_loop: runtime.event_loop)
    sink.bind!("old-fsm")

    expect(sink.post(:late_completion, nil)).to be(false)
    expect { sink.bind!("new-fsm") }
      .to raise_error(Phronomy::Error, /already bound/)
    expect(sink.fsm_session_id).to eq("old-fsm")
  ensure
    runtime&.shutdown(timeout: 2)
  end

  it "routes Provider completion before EventLoop applies semantic result state" do
    builder = File.read(
      File.join(root, "lib/phronomy/agent/agent_invocation_session_builder.rb")
    )
    invocation = File.read(
      File.join(root, "lib/phronomy/agent/agent_invocation.rb")
    )

    expect(builder).to include("post_session_event!(event_sink, event_type, result)")
    expect(builder).not_to include("record_llm_result")
    expect(invocation).to include("current_llm_result_authoritative?")
    expect(invocation).to include("result.llm_call_id")
    expect(invocation).not_to include("AgentExecutionActivation")
  end

  it "raises when posting to an unbound EventSink" do
    runtime = Phronomy::Runtime.new
    sink = Phronomy::FSMSession::EventSink.new(event_loop: runtime.event_loop)

    expect { sink.post(:event, nil) }
      .to raise_error(Phronomy::Error, /not bound/)
  ensure
    runtime&.shutdown(timeout: 2)
  end

  it "raises when claiming an already-claimed IdentityReservation" do
    reservation = Phronomy::FSMSession.reserve_identity

    reservation.send(:claim!)
    expect { reservation.send(:claim!) }
      .to raise_error(Phronomy::Error, /already claimed/)
  end
end
