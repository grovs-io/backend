# frozen_string_literal: true

require "test_helper"

class RefreshPurchaseClickhouseRowJobTest < ActiveSupport::TestCase
  fixtures :instances, :projects, :devices, :visitors, :purchase_events

  test "delegates to the processing job, which is the sync entry point" do
    event = purchase_events(:buy_event)
    job = Minitest::Mock.new
    job.expect(:perform, nil, [event.id])
    ProcessPurchaseEventJob.stub(:new, job) do
      RefreshPurchaseClickhouseRowJob.new.perform(event.id)
    end
    job.verify
  end

  test "leaves an unprocessed purchase to its own first processing" do
    event = purchase_events(:unprocessed_buy)
    called = false
    fake = lambda do
      called = true
      Minitest::Mock.new
    end
    ProcessPurchaseEventJob.stub(:new, fake) do
      RefreshPurchaseClickhouseRowJob.new.perform(event.id)
    end
    assert_not called
    assert_not event.reload.processed?
  end

  test "does nothing when the purchase is gone" do
    called = false
    fake = lambda do
      called = true
      Minitest::Mock.new
    end
    ProcessPurchaseEventJob.stub(:new, fake) do
      RefreshPurchaseClickhouseRowJob.new.perform(-1)
    end
    assert_not called
  end
end
