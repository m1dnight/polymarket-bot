defmodule PolyBotWeb.EventsLiveTest do
  use PolyBotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PolyBot.Contexts.Events
  alias PolyBot.Fixtures

  test "shows a grid cell per stored event", %{conn: conn} do
    event = Fixtures.event_fixture()

    {:ok, view, _html} = live(conn, ~p"/dashboard/events")

    assert has_element?(view, "#dashboard-tabs")
    assert has_element?(view, "#events-#{event.id}[title*='#{event.external_id}']")
  end

  test "shows an empty state when no events are stored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/events")

    assert has_element?(view, "#events-empty")
  end

  test "prepends events broadcast by the event store", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/events")

    %{new: [event]} = Events.store_events([%{external_id: "live-bcast", active: true}])

    assert has_element?(view, "#events-#{event.id}[title*='live-bcast']")
  end

  test "pushes a blink for price changes on visible events", %{conn: conn} do
    event = Fixtures.event_fixture()
    Fixtures.market_fixture(%{event_id: event.id, clob_token_ids: ["tok-blink", "tok-other"]})

    {:ok, view, _html} = live(conn, ~p"/dashboard/events")

    # a hit on a visible event's asset queues a blink; an unknown asset is
    # ignored. Flush directly instead of waiting out the coalescing window.
    send(view.pid, {:asset_price_changes, ["tok-blink", "tok-unknown"]})
    send(view.pid, :flush_blinks)

    assert_push_event(view, "blink", %{ids: ids})
    assert ids == ["events-#{event.id}"]
  end
end
