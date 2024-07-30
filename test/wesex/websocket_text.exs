defmodule Wesex.WebsocketTest do
  alias Wesex.Websocket
  alias Wesex.Websocket.{Closed, Opening, Open, Closing}
  use ExUnit.Case

  defmodule TestPlug do
    alias Wesex.WebsocketTest.{
      OpenOk,
      Receive5Text,
      Receive5Binary,
      Echo,
      CloseOnMsg,
      ReceiveAndClose,
      Sleep
    }

    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/open_ok" do
      conn
      |> WebSockAdapter.upgrade(OpenOk, [], [])
      |> halt()
    end

    get "/open_delayed" do
      :ok = Process.sleep(100)

      conn
      |> WebSockAdapter.upgrade(OpenOk, [], [])
      |> halt()
    end

    get "/recv_5_text" do
      conn
      |> WebSockAdapter.upgrade(Receive5Text, [], [])
    end

    get "/recv_5_binary" do
      conn
      |> WebSockAdapter.upgrade(Receive5Binary, [], [])
    end

    get "/echo" do
      conn
      |> WebSockAdapter.upgrade(Echo, [], [])
    end

    get "/close_on_msg" do
      conn
      |> WebSockAdapter.upgrade(CloseOnMsg, [], [])
    end

    get "receive_n_close" do
      conn
      |> WebSockAdapter.upgrade(ReceiveAndClose, [], [])
    end

    get "sleep" do
      conn
      |> WebSockAdapter.upgrade(Sleep, [], [])
    end

    get "/none" do
      _ = conn
      exit(:normal)
    end
  end

  defmodule OpenOk do
    def init(_) do
      {:ok, []}
    end
  end

  defmodule Receive5Text do
    def init(s) do
      frames = [
        {:text, "q"},
        {:text, "w"},
        {:text, "e"},
        {:text, "r"},
        {:text, "t"}
      ]

      {:push, frames, s}
    end
  end

  defmodule Receive5Binary do
    def init(s) do
      frames = [
        {:binary, <<0>>},
        {:binary, <<1>>},
        {:binary, <<2>>},
        {:binary, <<3>>},
        {:binary, <<4>>}
      ]

      {:push, frames, s}
    end
  end

  defmodule Echo do
    def init(_) do
      {:ok, []}
    end

    def handle_in({data, opcode: :text}, s) do
      {:push, {:text, data}, s}
    end

    def handle_in({data, opcode: :binary}, s) do
      {:push, {:binary, data}, s}
    end
  end

  defmodule CloseOnMsg do
    def init(_) do
      {:ok, []}
    end

    def handle_in({<<code::size(16)>>, opcode: :binary}, s) do
      {:stop, :normal, code, s}
    end
  end

  defmodule ReceiveAndClose do
    def init(s) do
      {:stop, :normal, {1000, "reason"}, [{:text, "foo"}, {:binary, "\0bar"}], s}
    end
  end

  defmodule Sleep do
    def init(s) do
      Process.sleep(50)
      {:ok, s}
    end
  end

  defp port do
    (System.get_env("WESEX_TEST_PORT", "55443") |> String.to_integer()) + 1
  end

  setup_all do
    _test_server = start_link_supervised!(test_server())
    :ok
  end

  defp test_server do
    {
      Bandit,
      # max 100 bytes so we can test better
      plug: TestPlug,
      scheme: :http,
      port: port(),
      ip: :loopback,
      websocket_options: [max_frame_size: 100]
    }
  end

  defp url(path), do: "http://localhost:#{port()}#{path}" |> URI.new!()

  test "closed to opening" do
    state = Closed.new()
    assert {:ok, opening} = Websocket.open(state, url("/open_ok"), [])

    assert %Opening{
             con: _con,
             ws_ref: ws_ref,
             ws_opts: [],
             timer: timer,
             status_resp: nil,
             headers_resp: nil,
             done_resp: nil
           } = opening

    assert is_reference(ws_ref)
    def_timeout = Opening.default_timeout()
    assert_in_delta def_timeout, Process.read_timer(timer), 1_000
  end

  test "opening to open" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/open_ok"), [])
    ws_ref = opening.ws_ref

    {events, open} = recv_until_open(opening)
    assert [{:opening, ws_ref, :done}] == events

    assert %Open{
             con: _,
             ws: _,
             ws_ref: ^ws_ref,
             ponged: true,
             ping_timer: _ping_timer,
             ping_intv: 10_000
           } = open

    assert_receive {:ping_time, ^ws_ref}, 10
  end

  test "opening to open, error" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/none"), [])
    ws_ref = opening.ws_ref

    {events, closed} = recv_until_open(opening)
    assert [{:opening, ^ws_ref, :error, _reason}] = events
    assert %Closed{} == closed

    assert false == Process.read_timer(opening.timer)
    refute_receive {:ping_time, ^ws_ref}, 10
  end

  test "opening to open, timeout" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/open_delayed"), [], 0)
    ws_ref = opening.ws_ref

    {events, closed} = recv_until_open(opening)
    assert [{:opening, ^ws_ref, :error, _reason}] = events
    assert %Closed{} == closed

    assert false == Process.read_timer(opening.timer)
  end

  test "receive text" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/recv_5_text"), [])
    ws_ref = opening.ws_ref
    {[{:opening, ^ws_ref, :done}], open} = recv_until_open(opening)

    {events, state} = recv_until_event_count(open, 5)

    assert [
             {:dataframe, ws_ref, {:text, "q"}},
             {:dataframe, ws_ref, {:text, "w"}},
             {:dataframe, ws_ref, {:text, "e"}},
             {:dataframe, ws_ref, {:text, "r"}},
             {:dataframe, ws_ref, {:text, "t"}}
           ] === events

    assert is_struct(state, Open)
  end

  test "receive binary" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/recv_5_binary"), [])
    ws_ref = opening.ws_ref
    {[{:opening, ^ws_ref, :done}], open} = recv_until_open(opening)

    {events, state} = recv_until_event_count(open, 5)

    assert [
             {:dataframe, ws_ref, {:binary, <<0>>}},
             {:dataframe, ws_ref, {:binary, <<1>>}},
             {:dataframe, ws_ref, {:binary, <<2>>}},
             {:dataframe, ws_ref, {:binary, <<3>>}},
             {:dataframe, ws_ref, {:binary, <<4>>}}
           ] === events

    assert is_struct(state, Open)
  end

  test "send, receive text" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/echo"), [])
    ws_ref = opening.ws_ref
    {[{:opening, ^ws_ref, :done}], open} = recv_until_open(opening)

    assert {:ok, open} = Websocket.send({:text, "hello"}, open)
    assert is_struct(open, Open)

    {events, state} = recv_until_event_count(open, 1)

    assert [
             {:dataframe, ws_ref, {:text, "hello"}}
           ] === events

    assert is_struct(state, Open)
  end

  test "send, receive binary" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/echo"), [])
    ws_ref = opening.ws_ref
    {[{:opening, ^ws_ref, :done}], open} = recv_until_open(opening)

    assert {:ok, open} = Websocket.send({:binary, "hello"}, open)
    assert is_struct(open, Open)

    {events, state} = recv_until_event_count(open, 1)

    assert [
             {:dataframe, ws_ref, {:binary, "hello"}}
           ] === events

    assert is_struct(state, Open)
  end

  test "send, then remote close" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/close_on_msg"), [])
    ws_ref = opening.ws_ref
    {[{:opening, ^ws_ref, :done}], open} = recv_until_open(opening)

    {:ok, open} = Websocket.send({:binary, <<1000::size(16)>>}, open)

    {events, state} = recv_until_event_count(open, 1)

    assert [
             {:closed, ^ws_ref, :remote_initiated, %{code: 1000, reason: reason}}
           ] = events

    assert is_binary(reason) or reason == nil, inspect(reason)

    assert is_struct(state, Closed)
  end

  test "receive and remote close" do
    state = Closed.new()
    {:ok, opening} = Websocket.open(state, url("/receive_n_close"), [])
    ws_ref = opening.ws_ref
    {[{:opening, ^ws_ref, :done}], open} = recv_until_open(opening)

    {events, state} = recv_until_event_count(open, 3)

    assert [
             {:dataframe, ^ws_ref, {:text, "foo"}},
             {:dataframe, ^ws_ref, {:binary, "\0bar"}},
             {:closed, ^ws_ref, :remote_initiated, %{code: 1000, reason: "reason"}}
           ] = events

    assert is_struct(state, Closed)
  end

  test "local close" do
    state = Closed.new()
    {:ok, state} = Websocket.open(state, url("/open_ok"), [])
    ws_ref = state.ws_ref
    {[{:opening, ^ws_ref, :done}], state} = recv_until_open(state)

    state = Websocket.close(state, %{code: 1001})
    assert is_struct(state, Closing), inspect(state)

    {events, state} = recv_until_event_count(state, 1)

    assert [
             {:closed, ^ws_ref, :local_initiated, %{code: _}}
           ] = events

    assert is_struct(state, Closed)
  end

  test "ping during lifetime" do
    state = Closed.new()
    {:ok, state} = Websocket.open(state, url("/open_ok"), [])
    ws_ref = state.ws_ref
    {[{:opening, ^ws_ref, :done}], state} = recv_until_open(state)

    state = %Open{state | ping_intv: 10}
    {events, state} = recv_until_time(state, System.monotonic_time(:millisecond) + 50)
    assert [] == events
    state = Websocket.close(state, %{code: 1001})
    assert is_struct(state, Closing), inspect(state)

    {events, state} = recv_until_event_count(state, 1)

    assert [
             {:closed, ^ws_ref, :local_initiated, %{code: _}}
           ] = events

    assert is_struct(state, Closed)
  end

  test "ping timeout" do
    state = Closed.new()
    {:ok, state} = Websocket.open(state, url("/sleep"), [])
    ws_ref = state.ws_ref
    {[{:opening, ^ws_ref, :done}], state} = recv_until_open(state)

    state = %Open{state | ping_intv: 10}
    {events, state} = recv_until_event_count(state, 1)

    assert [
             {:closed, ^ws_ref, :error, :ping_timeout}
           ] = events

    assert is_struct(state, Closed)
  end

  defp recv_until_open(%Opening{} = state) do
    assert_receive msg, 100

    case Websocket.stream(msg, state) do
      {events, %Opening{} = state} ->
        {new_events, state} = recv_until_open(state)
        {events ++ new_events, state}

      {events, %Open{} = state} ->
        {events, state}

      {events, %Closed{} = state} ->
        {events, state}
    end
  end

  defp recv_until_event_count(state, n, wait_per_msg \\ 100)

  defp recv_until_event_count(state, 0, _) do
    {[], state}
  end

  defp recv_until_event_count(state, n, wait_per_msg) when n > 0 do
    assert_receive msg, wait_per_msg

    case Websocket.stream(msg, state) do
      {events, state} ->
        sub = length(events)
        {new_events, state} = recv_until_event_count(state, n - sub, wait_per_msg)
        {events ++ new_events, state}

        # {events, state} ->
        #   {events, state}
    end
  end

  defp recv_until_time(state, until) do
    now = System.monotonic_time(:millisecond)

    if now >= until - 10 do
      {[], state}
    else
      assert_receive msg, until - now

      case Websocket.stream(msg, state) do
        {events, state} ->
          {new_events, state} = recv_until_time(state, until)
          {events ++ new_events, state}
      end
    end
  end
end
