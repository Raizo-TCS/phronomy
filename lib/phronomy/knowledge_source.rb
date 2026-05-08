# frozen_string_literal: true

require_relative "knowledge_source/base"
require_relative "knowledge_source/static_knowledge"
require_relative "knowledge_source/rag_knowledge"
require_relative "knowledge_source/entity_knowledge"

module Phronomy
  # KnowledgeSource provides the interface for supplying context region 3 (Knowledge)
  # to the Context::Assembler.
  #
  # Each implementation returns an array of knowledge chunks via #fetch(query:).
  # Each chunk is a Hash with :content (String) and :type (Symbol) keys.
  # The Assembler wraps each chunk in an XML context tag before injecting it.
  module KnowledgeSource
  end
end
