require "test_helper"
require_relative "../../../support/operations_test_helper"

class Operations::Restore::BundleVerifierTest < ActiveSupport::TestCase
  include OperationsTestHelper

  test "rejects malformed incomplete unsupported forged and missing bundles" do
    with_bundle do |bundle|
      bundle.join("COMPLETE").delete
      assert_invalid(bundle)
    end

    with_bundle do |bundle|
      bundle.join("manifest.json").write("{not-json")
      assert_invalid(bundle)
    end

    with_bundle do |bundle|
      rewrite_manifest(bundle) { |manifest| manifest["version"] = 999 }
      assert_invalid(bundle)
    end

    with_bundle do |bundle|
      File.open(bundle.join("primary.dump"), "ab") { |file| file.write("tampered") }
      assert_invalid(bundle)
    end

    with_bundle do |bundle|
      bundle.join("storage.tar.gz").delete
      assert_invalid(bundle)
    end
  end

  test "rejects secret-like or path-shaped manifest substitutions" do
    with_bundle do |bundle|
      rewrite_manifest(bundle) { |manifest| manifest["release"]["sha"] = "postgresql://user:password@host/db" }
      assert_invalid(bundle)
    end

    with_bundle do |bundle|
      rewrite_manifest(bundle) do |manifest|
        manifest["artifacts"]["../primary.dump"] = manifest["artifacts"].delete("primary.dump")
      end
      assert_invalid(bundle)
    end
  end

  test "rejects artifact symlink substitution" do
    with_bundle do |bundle|
      database = bundle.join("primary.dump")
      target = bundle.join("target.dump")
      database.rename(target)
      File.symlink(target, database)
      assert_invalid(bundle)
    end
  end

  test "rejects unexpected files so retention cannot remove unrelated data" do
    with_bundle do |bundle|
      bundle.join("unrelated-private-file").write("preserve")
      assert_invalid(bundle)
      assert bundle.join("unrelated-private-file").exist?
    end
  end

  private

  def with_bundle
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        result = create_test_bundle(root: root, storage_root: storage)
        yield result.path
      end
    end
  end

  def assert_invalid(bundle)
    assert_raises(Operations::Restore::BundleVerifier::InvalidBundle) do
      Operations::Restore::BundleVerifier.call(bundle)
    end
  end
end
