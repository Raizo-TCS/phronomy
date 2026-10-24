# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RubyLLM transport error ownership" do
  def transport_failure(type)
    cause = IOError.new("network failure")
    begin
      raise type.new("transport failed"), cause: cause
    rescue type => error
      error
    end
  end

  %i[complete stream embed].each do |operation|
    context operation.to_s do
      let(:chat) { double("chat", provider: double("Provider", protocols: {}), after_message: nil) }
      let(:request) { Phronomy::LLMAdapter::Request.new(message: "input") }

      before { allow(RubyLLM).to receive(:chat).and_return(chat) }

      define_method(:invoke_adapter) do |&callback|
        if operation == :embed
          Phronomy::Embeddings::RubyLLMEmbeddings.new.embed("input")
        else
          Phronomy::LLMAdapter::RubyLLM.new.public_send(operation, request, &callback || ->(_chunk) {})
        end
      end

      define_method(:expect_sdk_failure) do |error|
        if operation == :embed
          expect(RubyLLM).to receive(:embed).once.and_raise(error)
        else
          expect(chat).to receive(:ask).once.and_raise(error)
        end
      end

      [Faraday::TimeoutError, Faraday::ConnectionFailed].each do |source_type|
        it "maps #{source_type} to the owning TransportError and preserves both causes" do
          source = transport_failure(source_type)
          expect_sdk_failure(source)
          target = (operation == :embed) ? Phronomy::Embeddings::TransportError : Phronomy::LLMAdapter::TransportError
          expect { invoke_adapter }.to raise_error(target) { |error|
            expect(error.cause).to equal(source)
            expect(error.cause.cause).to equal(source.cause)
            expect(error.message).to eq(source.message)
          }
        end
      end

      {
        cancellation: -> { Phronomy::CancellationError.new("cancelled") },
        deadline: -> { Phronomy::ExecutionTimeoutError.new(outcomes: []) },
        unknown_sdk_error: -> { Faraday::Error.new("unknown") },
        tls_error: -> { Faraday::SSLError.new("certificate failure") },
        arbitrary_io: -> { IOError.new("application I/O") },
        programming_error: -> { NoMethodError.new("bug") }
      }.each do |name, factory|
        it "preserves #{name} identity without guessing a transport classification" do
          source = factory.call
          expect_sdk_failure(source)
          expect { invoke_adapter }.to raise_error { |error| expect(error).to equal(source) }
        end
      end

      next unless operation == :stream

      [Faraday::TimeoutError, Faraday::ConnectionFailed].each do |source_type|
        it "preserves an application's #{source_type} callback exception without wrapping or replay" do
          source = transport_failure(source_type)
          expect(chat).to receive(:ask).once { |_input, &sink| sink.call(Struct.new(:content).new("part")) }
          expect { invoke_adapter { raise source } }.to raise_error { |error| expect(error).to equal(source) }
        end

        it "reports #{source_type} after a delivered chunk without replay or success" do
          source = transport_failure(source_type)
          expect(chat).to receive(:ask).once do |_input, &sink|
            sink.call(Struct.new(:content).new("part"))
            raise source
          end
          chunks = []
          expect { invoke_adapter { |chunk| chunks << chunk.content } }
            .to raise_error(Phronomy::LLMAdapter::TransportError) { |error| expect(error.cause).to equal(source) }
          expect(chunks).to eq(["part"])
        end
      end
    end
  end
end
