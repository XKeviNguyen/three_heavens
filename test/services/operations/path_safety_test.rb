require "test_helper"

class Operations::PathSafetyTest < ActiveSupport::TestCase
  test "uses path components rather than naive string prefixes for containment" do
    Dir.mktmpdir("three-heavens-root-") do |root|
      assert_raises(Operations::PathSafety::UnsafePath) do
        Operations::PathSafety.child!(root, "../#{File.basename(root)}-escape")
      end
      assert_equal Pathname.new(root).join("safe", "child"), Operations::PathSafety.child!(root, "safe/child")
    end
  end

  test "rejects relative dangerous and symlink roots" do
    assert_raises(Operations::PathSafety::UnsafePath) { Operations::PathSafety.prepare_root!("relative") }
    assert_raises(Operations::PathSafety::UnsafePath) { Operations::PathSafety.prepare_root!("/") }

    Dir.mktmpdir("three-heavens-root-") do |root|
      link = File.join(root, "linked")
      File.symlink("/tmp", link)
      assert_raises(Operations::PathSafety::UnsafePath) { Operations::PathSafety.prepare_root!(link) }
    end
  end

  test "rejects forbidden roots and their descendants by path component" do
    Dir.mktmpdir("three-heavens-path-safety-") do |root|
      live_storage = File.join(root, "storage")
      FileUtils.mkdir_p(live_storage)

      [ live_storage, File.join(live_storage, "backups"), File.join(live_storage, "restore", "nested") ].each do |path|
        assert_raises(Operations::PathSafety::UnsafePath) do
          Operations::PathSafety.prepare_root!(path, create: true, forbidden: [ live_storage ])
        end
      end

      sibling = File.join(root, "storage-backups")
      assert_equal Pathname.new(sibling), Operations::PathSafety.prepare_root!(sibling, create: true, forbidden: [ live_storage ])
    end

    [ Rails.root, Rails.root.join("tmp", "operations-path-safety") ].each do |path|
      assert_raises(Operations::PathSafety::UnsafePath) do
        Operations::PathSafety.prepare_root!(path, create: true, forbidden: [ Rails.root ])
      end
    end
  end
end
