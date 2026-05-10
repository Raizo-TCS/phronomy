# frozen_string_literal: true

require_relative "encryptor/base"
require_relative "encryptor/active_support"

module Phronomy
  module StateStore
    # Namespace for state encryption adapters.
    #
    # Available adapters:
    # - {Phronomy::StateStore::Encryptor::Base}       — abstract interface
    # - {Phronomy::StateStore::Encryptor::ActiveSupport} — AES-256-GCM via ActiveSupport
    module Encryptor
    end
  end
end
