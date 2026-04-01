module RuboCop
  module Cop
    module Custom
      # Ensures models that `include ModelCachingExtension` also define
      # `cache_keys_to_clear` so that cached lookups are properly invalidated.
      #
      # Without an override, only the default :id and hashid keys are cleared,
      # which means any `redis_find_by(:vendor, ...)` or multi-condition lookup
      # will serve stale data until the 5-minute TTL expires.
      #
      # @example
      #   # bad
      #   class Device < ApplicationRecord
      #     include ModelCachingExtension
      #   end
      #
      #   # good
      #   class Device < ApplicationRecord
      #     include ModelCachingExtension
      #
      #     def cache_keys_to_clear
      #       keys = super
      #       keys << "#{self.class.cache_prefix}:find_by:vendor:#{vendor}:no_includes"
      #       keys
      #     end
      #   end
      class ModelCachingRequiresCacheKeys < Base
        MSG = '`include ModelCachingExtension` requires a `cache_keys_to_clear` ' \
              'method override to ensure all cached lookups are invalidated on save.'

        def on_send(node)
          return unless include_model_caching_extension?(node)

          @include_node = node
        end

        def on_def(node)
          @has_cache_keys_method = true if node.method_name == :cache_keys_to_clear
        end

        def on_investigation_end
          return unless @include_node
          return if @has_cache_keys_method

          add_offense(@include_node)
        end

        private

        def include_model_caching_extension?(node)
          node.method_name == :include &&
            node.arguments.size == 1 &&
            node.first_argument.const_type? &&
            node.first_argument.const_name == 'ModelCachingExtension'
        end
      end
    end
  end
end
