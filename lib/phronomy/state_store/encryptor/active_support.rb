# frozen_string_literal: true

module Phronomy
  module StateStore
    module Encryptor
      # Encryptor backed by ActiveSupport::MessageEncryptor.
      #
      # Requires the +activesupport+ gem to be available in the host application.
      # Does NOT require rails — any Ruby project that depends on activesupport can
      # use this adapter.
      #
      # @example
      #   encryptor = Phronomy::StateStore::Encryptor::ActiveSupport.new(
      #     secret_key_base: ENV.fetch("SECRET_KEY_BASE")
      #   )
      #   store = Phronomy::StateStore::ActiveRecord.new(
      #     model_class: PhronomyState,
      #     encryptor: encryptor
      #   )
      class ActiveSupport < Base
        # @param secret_key_base [String] secret used to derive the encryption key.
        #   Must be at least 30 random bytes (use +SecureRandom.hex(64)+ to generate).
        # @param cipher [String] OpenSSL cipher name (default: "aes-256-gcm").
        # @raise [LoadError] when activesupport is not available.
        def initialize(secret_key_base:, cipher: "aes-256-gcm")
          require "active_support/message_encryptor"
          key = ::ActiveSupport::KeyGenerator.new(secret_key_base)
            .generate_key("phronomy state store", 32)
          @encryptor = ::ActiveSupport::MessageEncryptor.new(key, cipher: cipher)
        end

        # Encrypts the plaintext using AES-256-GCM.
        # @param plaintext [String]
        # @return [String] Base64-encoded authenticated ciphertext
        def encrypt(plaintext)
          @encryptor.encrypt_and_sign(plaintext)
        end

        # Decrypts and verifies the ciphertext.
        # @param ciphertext [String]
        # @return [String] the original plaintext
        # @raise [ActiveSupport::MessageEncryptor::InvalidMessage] on tampered data
        def decrypt(ciphertext)
          @encryptor.decrypt_and_verify(ciphertext)
        end
      end
    end
  end
end
