# frozen_string_literal: true

module Phronomy
  # Lightweight synchronous actor backed by a dedicated +Thread+ and a +Queue+.
  #
  # A caller submits work via {#call}, which blocks until the actor's thread
  # finishes executing the block and then returns the result (or re-raises any
  # exception that occurred inside the actor).
  #
  # === Reentrant safety
  #
  # If {#call} is invoked from within the actor's own thread (i.e. from inside
  # a block that is already executing on this actor), the block is executed
  # directly in the current thread instead of being pushed onto the queue.
  # This prevents deadlocks in deeply nested call paths without requiring
  # callers to track whether they are already "inside" the actor.
  #
  # === Usage
  #
  #   actor = Phronomy::Actor.new
  #   result = actor.call { expensive_operation() }   # blocks caller; runs on actor thread
  #   actor.stop                                       # graceful shutdown
  class Actor
    def initialize
      @queue = Queue.new
      @thread = Thread.new do
        loop do
          task = @queue.pop
          break if task == :stop
          task.call
        end
      end
    end

    # Run +block+ on the actor's thread and return its result.
    #
    # If the current thread is already the actor's thread (reentrant call),
    # the block is executed inline to prevent deadlocks.
    #
    # Any exception raised inside the block is captured and re-raised in the
    # calling thread.
    #
    # @yield block to execute on the actor's thread
    # @return the return value of the block
    def call(&block)
      return block.call if Thread.current == @thread

      done = Queue.new
      @queue.push(-> {
        begin
          done.push([true, block.call])
        rescue => e
          done.push([false, e])
        end
      })
      success, value = done.pop
      raise value unless success
      value
    end

    # Send a +:stop+ sentinel to gracefully terminate the actor's thread.
    # Pending tasks already in the queue will still be processed before
    # the thread exits.
    def stop
      @queue.push(:stop)
    end
  end
end
