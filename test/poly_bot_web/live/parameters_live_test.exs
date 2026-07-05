defmodule PolyBotWeb.ParametersLiveTest do
  use PolyBotWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the configured parameters per worker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/parameters")

    assert has_element?(view, "#event-fetcher-params #param-fetch-interval")
    assert has_element?(view, "#event-fetcher-params #param-fetch-limit", "100")
    assert has_element?(view, "#event-fetcher-params #param-fetch-active", "true")
    assert has_element?(view, "#event-fetcher-params #param-fetch-closed", "false")
    assert has_element?(view, "#event-fetcher-params #param-fetch-liquidity", "10000")
    assert has_element?(view, "#websocket-params #param-ws-conn-cap", "100")
    assert has_element?(view, "#websocket-params #param-ws-retry-base", "1s")
    assert has_element?(view, "#websocket-params #param-ws-retry-max", "30s")
    assert has_element?(view, "#market-data-params #param-md-sweep")
    assert has_element?(view, "#market-data-params #param-md-staleness", "30s")
    assert has_element?(view, "#dashboard-params #param-dash-refresh", "5s")
    assert has_element?(view, "#dashboard-params #param-dash-blink", "300ms")
  end
end
