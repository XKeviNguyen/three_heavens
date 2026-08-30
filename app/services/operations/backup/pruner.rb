require "fileutils"
require "set"

module Operations
  module Backup
    class Pruner
      class InvalidPolicy < StandardError; end

      Result = Data.define(:recognized_count, :selected_count, :deleted_count, :dry_run)

      def self.call(root:, dry_run: true, keep_last: nil, older_than_days: nil, **options)
        new(
          root: root,
          dry_run: dry_run,
          keep_last: keep_last,
          older_than_days: older_than_days,
          **options
        ).call
      end

      def initialize(root:, dry_run:, keep_last:, older_than_days:,
                     verifier: Operations::Restore::BundleVerifier, clock: -> { Time.current })
        @root_value = root
        @dry_run = dry_run == true
        @keep_last = keep_last.nil? ? nil : Integer(keep_last)
        @older_than_days = older_than_days.nil? ? nil : Integer(older_than_days)
        @verifier = verifier
        @clock = clock
      rescue ArgumentError, TypeError
        raise InvalidPolicy, "retention values must be integers"
      end

      def call
        validate_policy!
        root = Operations::PathSafety.prepare_root!(root_value)
        bundles = valid_bundles(root).sort_by { |entry| entry.fetch(:created_at) }.reverse
        protected_paths = keep_last ? bundles.first(keep_last).pluck(:path).to_set : Set.new
        cutoff = older_than_days && clock.call - older_than_days.days
        selected = bundles.select do |entry|
          next false if protected_paths.include?(entry.fetch(:path))

          cutoff.nil? || entry.fetch(:created_at) < cutoff
        end
        selected.each { |entry| FileUtils.remove_entry_secure(entry.fetch(:path)) } unless dry_run
        Result.new(
          recognized_count: bundles.size,
          selected_count: selected.size,
          deleted_count: dry_run ? 0 : selected.size,
          dry_run: dry_run
        )
      rescue Operations::PathSafety::UnsafePath => error
        raise InvalidPolicy, error.message
      end

      private

      attr_reader :clock, :dry_run, :keep_last, :older_than_days, :root_value, :verifier

      def validate_policy!
        raise InvalidPolicy, "at least one retention policy is required" if keep_last.nil? && older_than_days.nil?
        raise InvalidPolicy, "keep-last must be non-negative" if keep_last && keep_last.negative?
        raise InvalidPolicy, "older-than-days must be positive" if older_than_days && !older_than_days.positive?
        raise InvalidPolicy, "keep-last is unreasonably large" if keep_last && keep_last > 1_000_000
        raise InvalidPolicy, "older-than-days is unreasonably large" if older_than_days && older_than_days > 365_000
      end

      def valid_bundles(root)
        root.children.filter_map do |candidate|
          next unless candidate.basename.to_s.match?(/\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{24}\z/)
          next unless candidate.directory? && !candidate.symlink?

          verified = verifier.call(candidate)
          {
            path: verified.path,
            created_at: Time.iso8601(verified.manifest.fetch("created_at"))
          }
        rescue Operations::Restore::BundleVerifier::InvalidBundle
          nil
        end
      end
    end
  end
end
