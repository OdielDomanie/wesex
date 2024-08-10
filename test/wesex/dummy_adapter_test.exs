defmodule Wesex.DummyAdapterTest do
  alias Wesex.Websocket
  alias Wesex.Websocket.{Closed, Opening, Open, Closing}
  alias Wesex.DummyAdapter
  use ExUnit.Case

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

  defp port do
    0
  end

  defp url(path), do: "http://localhost:#{port()}#{path}" |> URI.new!()

  test "closed to opening" do
    state = Closed.new(DummyAdapter)

    assert {:ok, opening} =
             Websocket.open(state, url("/open_ok"), con_opts: [websock_impl: OpenOk])

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
    state = Closed.new(DummyAdapter)
    {:ok, opening} = Websocket.open(state, url("/open_ok"), con_opts: [websock_impl: OpenOk])
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

  test "receive text" do
    state = Closed.new(DummyAdapter)

    {:ok, opening} =
      Websocket.open(state, url("/recv_5_text"), con_opts: [websock_impl: Receive5Text])

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
    state = Closed.new(DummyAdapter)

    {:ok, opening} =
      Websocket.open(state, url("/recv_5_binary"), con_opts: [websock_impl: Receive5Binary])

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
    state = Closed.new(DummyAdapter)
    {:ok, opening} = Websocket.open(state, url("/echo"), con_opts: [websock_impl: Echo])
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
    state = Closed.new(DummyAdapter)
    {:ok, opening} = Websocket.open(state, url("/echo"), con_opts: [websock_impl: Echo])
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
    state = Closed.new(DummyAdapter)

    {:ok, opening} =
      Websocket.open(state, url("/close_on_msg"), con_opts: [websock_impl: CloseOnMsg])

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
    state = Closed.new(DummyAdapter)

    {:ok, opening} =
      Websocket.open(state, url("/receive_n_close"), con_opts: [websock_impl: ReceiveAndClose])

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
    state = Closed.new(DummyAdapter)
    {:ok, state} = Websocket.open(state, url("/open_ok"), con_opts: [websock_impl: OpenOk])
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
    state = Closed.new(DummyAdapter)
    {:ok, state} = Websocket.open(state, url("/open_ok"), con_opts: [websock_impl: OpenOk])
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
