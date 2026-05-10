# frozen_string_literal: true

module Phronomy
  module StateStore
    module Encryptor
      # Abstract base class for state encryption adapters.
      #
      # Subclass and implement {#encrypt} and {#decrypt} to integrate any
      # symmetric encryption scheme. Pass an instance to
      # {Phronomy::StateStore::ActiveRecord} via the +encryptor:+ argument.
      #
      # @example
      #   class MyEncryptor < Phronomy::StateStore::Encryptor::Base
      #     def encrypt(plaintext) = Base64.strict_encode64(plaintext.reverse)
      #     def decrypt(ciphertext) = Base64.strict_decode64(ciphertext).reverse
      #   end
      class Base
        # Encrypts a plaintext string.
        # @param plaintext [String] the JSON string produced by the state store
        # @return [String] the encrypted ciphertext
        def encrypt(plaintext)
          raise NotImplementedError, "#{self.class}#encrypt is not implemented"
        end

        # Decrypts a ciphertext string.
        # @param ciphertext [String] previously produced by {#encrypt}
        # @return [String] the original plaintext
        def decrypt(ciphertext)
          raise NotImplementedError, "#{self.class}#decrypt is not implemented"
        end
      end
    end
  end
end
