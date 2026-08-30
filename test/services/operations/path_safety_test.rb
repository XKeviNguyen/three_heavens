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
end
