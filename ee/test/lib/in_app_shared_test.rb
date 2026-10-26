require "test_helper"
require "rake"
require "tmpdir"

class InAppSharedReservedEventsTest < ActiveSupport::TestCase
  setup { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  test "reserved_events.json names equal the union of the event name constants, sorted" do
    expected = (Grovs::Events::MESSAGE_EVENT_NAMES + Grovs::Events::SERVER_EVENT_NAMES + Grovs::Events::ALL).uniq.sort
    actual = JSON.parse(File.read(File.join(InAppShared::SOURCE, "reserved_events.json"))).fetch("names")
    assert_equal expected, actual
  end

  test "the swift raw string uses enough # signs to contain any content" do
    content = "line one\nvalue = \"\"\"a\"\"\"# and \"\"\"##b\nline three"
    wrapped = InAppShared.swift_raw_string(content)
    fence = wrapped[/\A(#+)"""\n/, 1]
    assert_operator fence.length, :>, 2
    assert_equal "#{content}\n", wrapped[(fence.length + 4)...-(fence.length + 3)]
  end

  # Every platform injects this verbatim inside its own wrapping <script> tag; either would end it early.
  test "bridge.js never contains a closing script tag or an HTML comment opener" do
    content = InAppShared.bridge_script
    assert_no_match(%r{</script}i, content)
    assert_no_match(/<!--/, content)
  end

  test "the kotlin raw string escapes every dollar and refuses what it cannot carry" do
    assert_equal %("""a${'$'}b${'$'}{c}"""), InAppShared.kotlin_raw_string('a$b${c}')
    assert_raises(ArgumentError) { InAppShared.kotlin_raw_string('x """ y') }
    assert_raises(ArgumentError) { InAppShared.kotlin_raw_string("a" * 60_001) }
  end

  test "the generated kotlin holds bridge.js byte for byte and every reserved name" do
    kotlin = InAppShared.android_bridge_kotlin
    body = kotlin[/val SCRIPT: String = """(.*?)"""\n/m, 1]
    assert_equal InAppShared.bridge_script, body.gsub("${'$'}", "$")
    assert_includes kotlin, "package io.grovs.inapp\n"
    InAppShared.reserved_event_names.each { |name| assert_includes kotlin, "        #{name.to_json},\n" }
  end

  test "copy finds the Android checkout under its own folder name" do
    Dir.mktmpdir do |root|
      android = File.join(root, "grovs-Android")
      FileUtils.mkdir_p(android)
      assert_equal ["grovs-android"], InAppShared.copy(root: root)
      fixtures = File.join(android, "Grovs/Grovs/src/test/resources/in-app-shared")
      InAppShared::FILES.each do |name|
        assert FileUtils.identical?(File.join(InAppShared::SOURCE, name), File.join(fixtures, name)), name
      end
      assert File.file?(File.join(fixtures, "manifest.json"))
      generated = File.join(android, "Grovs/Grovs/src/main/java/io/grovs/inapp/InAppBridge.generated.kt")
      assert_equal InAppShared.android_bridge_kotlin, File.read(generated)
      assert_empty InAppShared.stale(root: root)
    end
  end
end
