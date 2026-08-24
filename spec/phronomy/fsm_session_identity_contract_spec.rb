# frozen_string_literal: true

require "spec_helper"

RSpec.describe "CG-03b FSMSession incarnation identity and routing foundation" do
  let(:root) { File.expand_path("../..", __dir__) }

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
    sources = %w[
      lib/phronomy/agent/agent_invocation_session_builder.rb
      lib/phronomy/agent/tool_invocation_session_builder.rb
      lib/phronomy/multi_agent/fan_out_session_builder.rb
    ].map { |relative| File.read(File.join(root, relative)) }.join("\n")
    expect(sources).not_to match(/FSMSession\.new\(.*?\bid\s*:/m)
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
