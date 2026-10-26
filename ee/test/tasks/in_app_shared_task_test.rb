require "test_helper"
require "rake"

class InAppSharedTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, "grovs-js"))
    @copy_dir = File.join(@root, "grovs-js/test/in-app-shared")
  end

  teardown { FileUtils.remove_entry(@root) }

  test "copy writes the files and a manifest, only into checkouts that exist" do
    assert_equal ["grovs-js"], InAppShared.copy(root: @root)
    assert_equal (InAppShared::FILES + ["manifest.json"]).sort, Dir.children(@copy_dir).sort
    assert_equal InAppShared.manifest(InAppShared::SOURCE), JSON.parse(File.read(File.join(@copy_dir, "manifest.json")))
    assert_not File.exist?(File.join(@root, "grovs-ios"))
  end

  test "a checkout is stale before the first copy and after a copied file changes" do
    assert_equal ["grovs-js"], InAppShared.stale(root: @root)
    InAppShared.copy(root: @root)
    assert_empty InAppShared.stale(root: @root)
    File.write(File.join(@copy_dir, "cases.json"), "{}")
    assert_equal ["grovs-js"], InAppShared.stale(root: @root)
  end

  test "a checkout is stale when its manifest is missing or wrong" do
    InAppShared.copy(root: @root)
    File.write(File.join(@copy_dir, "manifest.json"), "{}")
    assert_equal ["grovs-js"], InAppShared.stale(root: @root)
    File.delete(File.join(@copy_dir, "manifest.json"))
    assert_equal ["grovs-js"], InAppShared.stale(root: @root)
  end

  test "finding no checkout is an error, not a pass" do
    Dir.mktmpdir do |empty|
      assert_raises(InAppShared::NoCheckouts) { InAppShared.stale(root: empty) }
      assert_raises(InAppShared::NoCheckouts) { InAppShared.copy(root: empty) }
    end
  end

  test "copy refuses to overwrite a copy edited by hand unless forced" do
    InAppShared.copy(root: @root)
    File.write(File.join(@copy_dir, "README.md"), "my notes")
    assert_raises(InAppShared::EditedCopy) { InAppShared.copy(root: @root) }
    assert_equal "my notes", File.read(File.join(@copy_dir, "README.md"))
    assert_equal ["grovs-js"], InAppShared.copy(root: @root, force: true)
    assert_empty InAppShared.stale(root: @root)
  end

  test "the workspace can be set from the environment" do
    ENV["IN_APP_SHARED_WORKSPACE"] = @root
    assert_equal @root, InAppShared.workspace
  ensure
    ENV.delete("IN_APP_SHARED_WORKSPACE")
  end

  test "the source holds every shared file" do
    InAppShared::FILES.each { |name| assert File.file?(File.join(InAppShared::SOURCE, name)), name }
  end

  test "copy writes the grovs-js runtime files: a raw bridge.js and a generated reserved-events module" do
    InAppShared.copy(root: @root)
    bridge = File.join(@root, "grovs-js/src/inapp/bridge.js")
    reserved = File.join(@root, "grovs-js/src/inapp/reserved-events.generated.ts")
    assert_equal File.read(File.join(InAppShared::SOURCE, "bridge.js")), File.read(bridge)
    assert_includes File.read(reserved), "RESERVED_EVENT_NAMES"
  end

  test "copy writes the grovs-ios generated swift bridge with a raw string and a reserved events set" do
    FileUtils.mkdir_p(File.join(@root, "grovs-ios"))
    InAppShared.copy(root: @root)
    swift = File.read(File.join(@root, "grovs-ios/Sources/Grovs/model/inapp/InAppBridge.generated.swift"))
    assert_match(/static let script = #+"/, swift)
    assert_match(/static let reservedEvents: Set<String>/, swift)
  end

  test "check flags a stale grovs-js runtime copy" do
    InAppShared.copy(root: @root)
    assert_empty InAppShared.stale(root: @root)
    File.write(File.join(@root, "grovs-js/src/inapp/bridge.js"), "// stale")
    assert_equal ["grovs-js"], InAppShared.stale(root: @root)
  end

  test "copy gives a dashboard inside the workspace or beside it only cases.json" do
    workspace = File.join(@root, "workspace")
    %w[workspace/grovs-js grovs-web-app].each { |dir| FileUtils.mkdir_p(File.join(@root, dir)) }
    assert_equal %w[grovs-js grovs-web-app], InAppShared.copy(root: workspace)
    cases = File.join(@root, "grovs-web-app", InAppShared::DASHBOARD_CASES)
    assert FileUtils.identical?(cases, File.join(InAppShared::SOURCE, "cases.json"))
    assert_equal [cases], Dir.glob(File.join(@root, "grovs-web-app/**/*")).select { |f| File.file?(f) }
    assert_empty InAppShared.stale(root: workspace)
    File.write(cases, "{}")
    assert_equal ["grovs-web-app"], InAppShared.stale(root: workspace)
  end
end
