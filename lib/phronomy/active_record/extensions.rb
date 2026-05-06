# frozen_string_literal: true

# Convenience require for Rails context (loaded by Railtie when ActiveRecord is available).
# Ensures all Phronomy::ActiveRecord mixins are available to application models.
#
# Individual mixins (Checkpoint, Message, ActsAs) are also auto-loaded by Zeitwerk
# when referenced, so this file is only needed for eager-loading in a Rails app.
require_relative "checkpoint"
require_relative "message"
require_relative "acts_as"
