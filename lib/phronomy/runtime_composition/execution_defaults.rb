# frozen_string_literal: true

Phronomy::Execution.backend_provider = -> { Phronomy::ExecutionBinding }

Phronomy::ExecutionReceiver.install_binding(-> { Phronomy::ExecutionReceiverBinding })
