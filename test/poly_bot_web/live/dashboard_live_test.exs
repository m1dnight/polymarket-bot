defmodule PolyBotWeb.DashboardLiveTest do
  use PolyBotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PolyBot.Fixtures

  test "renders the stat tiles", %{conn: conn} do
    Fixtures.event_fixture()

    {:ok, view, _html} = live(conn, ~p"/dashboard")

    assert has_element?(view, "#event-store-stats #stat-events", "1")
    assert has_element?(view, "#event-store-stats #stat-markets", "0")
    assert has_element?(view, "#websocket-stats #stat-connections")
    assert has_element?(view, "#websocket-stats #stat-avg-lifespan")
    assert has_element?(view, "#websocket-stats #stat-avg-assets")
    assert has_element?(view, "#websocket-stats #stat-pending-assets")
    assert has_element?(view, "#websocket-stats #stat-msg-rate")
    assert has_element?(view, "#lifespan-stats #stat-lifespan-connected")
    assert has_element?(view, "#lifespan-stats #stat-lifespan-disconnected")
  end

  test "shows placeholders for the averages when no connections are open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    render_async(view)

    assert has_element?(view, "#stat-connections", "0")
    assert has_element?(view, "#stat-avg-lifespan", "–")
    assert has_element?(view, "#stat-avg-assets", "–")
    assert has_element?(view, "#stat-pending-assets", "0")
    # the first tick only records the rate baseline.
    assert has_element?(view, "#stat-msg-rate", "–")
    assert has_element?(view, "#stat-lifespan-connected", "–")
    assert has_element?(view, "#stat-lifespan-disconnected", "–")
  end
end
