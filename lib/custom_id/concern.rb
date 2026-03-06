# frozen_string_literal: true

require "active_support/concern"
require "active_support/core_ext/securerandom"

module CustomId
  # ActiveSupport::Concern that provides the +cid+ class macro for generating
  # prefixed, collision-resistant custom string IDs for ActiveRecord models.
  #
  # @example Minimal usage – generate a custom primary key
  #   class User < ApplicationRecord
  #     include CustomId::Concern   # not needed when using the Rails initializer
  #     cid "usr"
  #   end
  #
  #   User.create!(name: "Alice").id  # => "usr_7xKmN2pQ..."
  #
  # @example Embedding shared characters from a related model's ID
  #   class Document < ApplicationRecord
  #     belongs_to :workspace
  #     cid "doc", size: 24, related: { workspace: 6 }
  #   end
  #
  #   # If workspace.id == "wsp_ABCDEF...", document.id starts with "doc_ABCDEF..."
  #
  # @example Using a non-primary-key column
  #   class Article < ApplicationRecord
  #     cid "art", name: :slug, size: 12
  #   end
  #
  #   Article.create!(title: "Hello").slug  # => "art_aBcDeFgHiJkL"
  module Concern
    extend ActiveSupport::Concern

    class_methods do
      # Registers a +before_create+ callback that generates a prefixed Base58 ID.
      #
      # The generated value has the form:
      #   "#{prefix}_#{shared_chars}#{random_chars}"
      #
      # where +shared_chars+ (optional) are copied from a related model's ID and
      # +random_chars+ fills the remaining +size+ characters with Base58 noise.
      #
      # @param prefix  [String, Symbol]            Prefix to prepend (e.g. "usr", :doc).
      # @param size    [Integer]                   Length of the generated portion after the
      #                                            underscore separator (default: 16).
      # @param related [Hash{Symbol => Integer}]   A single-entry hash of
      #                                            { association_name => chars_to_borrow }.
      #                                            The gem borrows the first +chars+
      #                                            characters from the related model's ID.
      # @param name    [Symbol]                    Attribute to assign the ID to (default: :id).
      def cid(prefix, size: 16, related: {}, name: :id)
        id_prefix = prefix.to_s

        before_create do
          next unless send(name).nil?

          shared = resolve_shared_chars(related)
          loop do
            generated = build_id(id_prefix, shared, size)
            send(:"#{name}=", generated)
            break unless self.class.exists?(name => generated)
          end
        end
      end
    end

    # ---------------------------------------------------------------------------
    # Instance helpers (called from the before_create block)
    # ---------------------------------------------------------------------------

    private

    # Returns the shared-character prefix borrowed from the related model's ID,
    # or an empty string when +related+ is blank or the association is unset.
    def resolve_shared_chars(related)
      return "" unless related.present?

      association_name, borrow_count = related.first
      ref_id = related_model_id(association_name)
      ref_id ? ref_id.split("_", 2).last.first(borrow_count) : ""
    end

    # Reads the foreign-key value for +association_name+.
    def related_model_id(association_name)
      reflection  = self.class.reflections[association_name.to_s]
      foreign_key = reflection&.foreign_key.to_s
      read_attribute(foreign_key) if foreign_key.present?
    end

    # Generates a single candidate ID from prefix, shared chars, and random noise.
    def build_id(id_prefix, shared, size)
      rand_size = size - shared.length
      if rand_size < 1
        raise ArgumentError,
              "size (#{size}) must be greater than the number of " \
              "shared characters (#{shared.length})"
      end

      "#{id_prefix}_#{shared}#{SecureRandom.base58(rand_size)}"
    end
  end
end
