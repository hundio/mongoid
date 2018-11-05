# encoding: utf-8
require "mongoid/persistable/creatable"
require "mongoid/persistable/deletable"
require "mongoid/persistable/destroyable"
require "mongoid/persistable/incrementable"
require "mongoid/persistable/logical"
require "mongoid/persistable/poppable"
require "mongoid/persistable/pullable"
require "mongoid/persistable/pushable"
require "mongoid/persistable/renamable"
require "mongoid/persistable/savable"
require "mongoid/persistable/settable"
require "mongoid/persistable/updatable"
require "mongoid/persistable/upsertable"
require "mongoid/persistable/unsettable"

module Mongoid

  # Contains general behaviour for persistence operations.
  #
  # @since 2.0.0
  module Persistable
    extend ActiveSupport::Concern
    include Creatable
    include Deletable
    include Destroyable
    include Incrementable
    include Logical
    include Poppable
    include Positional
    include Pullable
    include Pushable
    include Renamable
    include Savable
    include Settable
    include Updatable
    include Upsertable
    include Unsettable

    # The atomic operations that deal with arrays or sets in the db.
    #
    # @since 4.0.0
    LIST_OPERATIONS = [ "$addToSet", "$push", "$pull", "$pullAll" ].freeze

    # Execute operations atomically (in a single database call) for everything
    # that would happen inside the block. This method supports nesting further
    # calls to atomically, which will behave according to the options described
    # below.
    #
    # An option join_context can be given which, when true, will merge the
    # operations declared by the given block with the atomically block wrapping
    # the current invocation, if one exists. If this block or any other block
    # sharing the same context raises before persisting, then all the operations
    # of that context will not be persisted, and will also be reset in-memory.
    #
    # When join_context is false, the given block of operations will be
    # persisted independently of other contexts. Failures in other contexts will
    # not affect this one, so long as this block was able to run and persist
    # changes.
    #
    # The default value of join_context is set by the global configuration
    # option join_contexts, whose own default is false.
    #
    # @example Execute the operations atomically.
    #   document.atomically do
    #     document.set(name: "Tool").inc(likes: 10)
    #   end
    #
    # @example Execute the operations atomically, only if the given selector matches document.
    #   document.atomically requiring: { "name" => { "$exists" => false } } do
    #     document.set(name: "Tool").inc(likes: 10)
    #   end
    #
    # @example Execute some inner operations atomically, but independently from the outer operations.
    #
    #   document.atomically do
    #     document.inc likes: 10
    #     document.atomically join_context: false do
    #       # The following is persisted to the database independently.
    #       document.unset :origin
    #     end
    #     document.atomically join_context: true do
    #       # The following is persisted along with the other outer operations.
    #       document.inc member_count: 3
    #     end
    #     document.set name: "Tool"
    #   end
    #
    # @param [ Hash ] options The options to pass to atomically.
    #
    # @option options [ true, false ] :join_context Join the context (i.e. merge
    #   declared atomic operations) of the atomically block wrapping this one,
    #   if one exists.
    #
    # @return [ true, false ] If the operation succeeded.
    #
    # @since 4.0.0
    def atomically(requiring: nil, join_context: nil)
      join_context = Mongoid.join_contexts if join_context.nil?
      call_depth = @atomic_depth ||= 0
      has_own_context = call_depth.zero? || !join_context
      @atomic_updates_to_execute_stack ||= []
      push_atomic_context if has_own_context
      requiring = @atomic_updates_to_execute_stack[-2][1] if requiring == :parent
      @atomic_update_selector_extension.replace (requiring || {}).merge(@atomic_update_selector_extension)
      given_atomic_selector = !@atomic_update_selector_extension.empty?

      if block_given?
        @atomic_depth += 1
        yield(self)
        @atomic_depth -= 1
      end

      if has_own_context
        result = persist_atomic_operations @atomic_context, @atomic_update_selector_extension
        result = result.n > 0
        result || !given_atomic_selector ? remove_atomic_context_changes : reset_atomic_context_changes!
      end

      if result.nil? || !given_atomic_selector
        true
      else
        result
      end
    rescue Exception => e
      reset_atomic_context_changes! if has_own_context
      raise e
    ensure
      pop_atomic_context if has_own_context

      if call_depth.zero?
        @atomic_depth = nil
        @atomic_updates_to_execute_stack = nil
      end
    end

    # Raise an error if validation failed.
    #
    # @example Raise the validation error.
    #   Person.fail_due_to_validation!(person)
    #
    # @param [ Document ] document The document to fail.
    #
    # @raise [ Errors::Validations ] The validation error.
    #
    # @since 4.0.0
    def fail_due_to_validation!
      raise Errors::Validations.new(self)
    end

    # Raise an error if a callback failed.
    #
    # @example Raise the callback error.
    #   Person.fail_due_to_callback!(person, :create!)
    #
    # @param [ Document ] document The document to fail.
    # @param [ Symbol ] method The method being called.
    #
    # @raise [ Errors::Callback ] The callback error.
    #
    # @since 4.0.0
    def fail_due_to_callback!(method)
      raise Errors::Callback.new(self.class, method)
    end

    private

    # Are we executing an atomically block on the current document?
    #
    # @api private
    #
    # @example Are we executing atomically?
    #   document.executing_atomically?
    #
    # @return [ true, false ] If we are current executing atomically.
    #
    # @since 4.0.0
    def executing_atomically?
      !@atomic_updates_to_execute_stack.nil?
    end

    # Post process the persistence operation.
    #
    # @api private
    #
    # @example Post process the persistence operation.
    #   document.post_process_persist(true)
    #
    # @param [ Object ] result The result of the operation.
    # @param [ Hash ] options The options.
    #
    # @return [ true ] true.
    #
    # @since 4.0.0
    def post_process_persist(result, options = {})
      post_persist unless result == false
      errors.clear unless performing_validations?(options)
      true
    end

    # Prepare an atomic persistence operation. Yields an empty hash to be sent
    # to the update.
    #
    # @api private
    #
    # @example Prepare the atomic operation.
    #   document.prepare_atomic_operation do |coll, selector, opts|
    #     ...
    #   end
    #
    # @return [ Object ] The result of the operation.
    #
    # @since 4.0.0
    def prepare_atomic_operation
      operations = yield({})
      persist_or_delay_atomic_operation(operations)
      self
    end

    # Process the atomic operations - this handles the common behaviour of
    # iterating through each op, getting the aliased field name, and removing
    # appropriate dirty changes.
    #
    # @api private
    #
    # @example Process the atomic operations.
    #   document.process_atomic_operations(pulls) do |field, value|
    #     ...
    #   end
    #
    # @param [ Hash ] operations The atomic operations.
    #
    # @return [ Hash ] The operations.
    #
    # @since 4.0.0
    def process_atomic_operations(operations)
      operations.each do |field, value|
        unless attribute_writable?(field)
          raise Errors::ReadonlyAttribute.new(field, value)
        end
        normalized = database_field_name(field)
        yield(normalized, value)
        remove_change(normalized) unless executing_atomically?
      end
    end

    # Remove the dirty changes for all fields changed in the current atomic
    # context.
    #
    # @api private
    #
    # @example Remove the current atomic context's dirty changes.
    #   document.remove_atomic_context_changes
    #
    # @since VERSION
    def remove_atomic_context_changes
      return unless executing_atomically?
      atomic_context_changed_fields.each { |f| remove_change f }
    end

    # Reset the attributes for all fields changed in the current atomic
    # context.
    #
    # @api private
    #
    # @example Reset the current atomic context's changed attributes.
    #   document.reset_atomic_context_changes!
    #
    # @since VERSION
    def reset_atomic_context_changes!
      return unless executing_atomically?
      atomic_context_changed_fields.each { |f| reset_attribute! f }
    end

    # Push a new atomic context onto the stack.
    #
    # @api private
    #
    # @example Push a new atomic context onto the stack.
    #   document.push_atomic_context
    #
    # @since VERSION
    def push_atomic_context
      return unless executing_atomically?
      @atomic_context = {}
      @atomic_update_selector_extension = {}
      @atomic_updates_to_execute_stack << [@atomic_context, @atomic_update_selector_extension]
    end

    # Pop an atomic context off the stack.
    #
    # @api private
    #
    # @example Pop an atomic context off the stack.
    #   document.pop_atomic_context
    #
    # @since VERSION
    def pop_atomic_context
      return unless executing_atomically?
      @atomic_updates_to_execute_stack.pop
      @atomic_context, @atomic_update_selector_extension = @atomic_updates_to_execute_stack.last
    end

    # Return the current atomic context's changed fields.
    #
    # @api private
    #
    # @example Return the current atomic context's changed fields.
    #   document.atomic_context_changed_fields
    #
    # @return [ Array ] The changed fields.
    #
    # @since VERSION
    def atomic_context_changed_fields
      @atomic_context.values.flat_map(&:keys)
    end

    # If we are in an atomically block, add the operations to the delayed group,
    # otherwise persist immediately.
    #
    # @api private
    #
    # @example Persist immediately or delay the operations.
    #   document.persist_or_delay_atomic_operation(ops)
    #
    # @param [ Hash ] operation The operation.
    #
    # @since 4.0.0
    def persist_or_delay_atomic_operation(operation)
      if executing_atomically?
        operation.each do |(name, hash)|
          @atomic_context[name] ||= {}
          @atomic_context[name].merge!(hash)
        end
      else
        persist_atomic_operations(operation)
      end
    end

    # Persist the atomic operations.
    #
    # @api private
    #
    # @example Persist the atomic operations.
    #   persist_atomic_operations(ops)
    #
    # @param [ Hash ] operations The atomic operations.
    #
    # @since 4.0.0
    def persist_atomic_operations(operations, selector_extension = {})
      if persisted? && operations
        selector = atomic_selector
        _root.collection.find(selector.merge(selector_extension)).update_one(positionally(selector, operations))
      end
    end
  end
end
